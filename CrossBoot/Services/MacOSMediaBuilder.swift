import Foundation

// Turns a macOS plan into a finished drive: obtains the installer, then lets
// Apple's createinstallmedia lay the drive out.
//
// Nothing here rewrites the media. createinstallmedia produces exactly what
// Apple's own instructions produce, so the drive carries Apple's boot files and
// its signatures - the same reason the Windows side copies Microsoft's boot
// chain instead of rebuilding it.
@MainActor
final class MacOSMediaBuilder {
    private let diskManager = DiskManager.shared
    // The download is tracked as run scratch so an abort releases it with
    // everything else; an abandoned InstallAssistant package is 12-18 GB.
    private let scratch = ISOHandler.shared
    private let downloader = InstallerDownloader.shared
    private let privileged = PrivilegedRunner.shared

    private let onUpdate: (ProcessState) -> Void

    private var state = ProcessState() {
        didSet { onUpdate(state) }
    }

    // Where each part of a run sits on the bar.
    //
    // Writing the drive is most of the wall clock - 15 GB onto a USB stick, with
    // no cache left to hide behind - and everything before it happens on this
    // Mac's own disk. So the write owns the whole second half, whether or not
    // there was a download before it.
    private enum Milestone {
        static let checked: Double = 2
        static let downloaded: Double = 45
        static let prepared: Double = 55
        static let erased: Double = 60
        static let finished: Double = 100
    }

    init(onUpdate: @escaping (ProcessState) -> Void) {
        self.onUpdate = onUpdate
    }

    func build(
        _ plan: MacOSMediaPlan,
        onto drive: Drive,
        removingInstaller: Bool,
        password: String
    ) async throws {
        // Checked before anything is downloaded or erased.
        guard drive.size >= plan.estimatedDriveBytes else {
            throw DiskError.insufficientSpace(required: plan.estimatedDriveBytes, available: drive.size)
        }

        try MediaBuilder.ensureScratchSpace(plan.estimatedTemporaryBytes)

        state = ProcessState(stage: .analyzing, progress: 0)
        try await diskManager.verifyStillPresent(drive)
        state.progress = Milestone.checked

        // What the privileged step will be asked to do is decided before the
        // password is asked for, so the prompt can come first and the download
        // can run while the step waits for it.
        let preparation = try await prepare(plan.installer)

        state = ProcessState(stage: .authorizing, progress: Milestone.checked)

        let request = PrivilegedRunner.Request(
            preparation: preparation.step,
            applicationURL: plan.installer.applicationURL,
            device: drive.device,
            driveSizeBytes: drive.size,
            // createinstallmedia is given a path under /Volumes, so the name has
            // to be one nothing else can already be mounted under - otherwise the
            // erased drive mounts as "CrossBoot 1" and the path points elsewhere.
            volumeName: Self.volumeName(),
            removesPreparedInstaller: removingInstaller
        )

        try await privileged.createInstallMedia(request, password: password) { [weak self] in
            guard let self else { return }

            // The installer is obtained before the drive is touched. A download
            // that fails, or a package Apple's own byte count disagrees with,
            // then leaves the drive exactly as it was.
            if let download = preparation.download {
                try await self.fetch(download, for: plan.installer)
            }

            try Task.checkCancellation()

            // The drive was last checked before a download that can run for an
            // hour, and the erase is the step that cannot be taken back.
            try await self.diskManager.verifyStillPresent(drive)
        } onOutput: { [weak self] output in
            self?.report(output, copying: plan.installer.sizeBytes)
        }

        state = ProcessState(stage: .done, progress: Milestone.finished)
    }

    // The package Apple publishes, and where this run puts it.
    private struct Download {
        let url: URL
        let destination: URL
    }

    // What the privileged step has to do, and what has to be downloaded before
    // it can do it.
    private typealias Prepared = (step: PrivilegedRunner.Preparation, download: Download?)

    private func prepare(_ installer: MacOSInstaller) async throws -> Prepared {
        switch installer.origin {
        case .catalog(_, let packageURL):
            let directory = try await scratch.makeTemporaryDirectory()
            let destination = directory.appendingPathComponent("InstallAssistant.pkg")

            return (.package(destination), Download(url: packageURL, destination: destination))

        case .package(let url):
            return (.package(url), nil)

        case .softwareUpdate:
            return (.fetch(version: installer.version.description), nil)

        case .application:
            return (.application, nil)
        }
    }

    private func fetch(_ download: Download, for installer: MacOSInstaller) async throws {
        state = ProcessState(stage: .downloading, progress: Milestone.checked)

        try await downloader.download(
            from: download.url,
            expecting: installer.sizeBytes,
            to: download.destination
        ) { [weak self] progress in
            guard let self else { return }

            self.state.progress = MediaBuilder.overallProgress(
                progress.percent,
                from: Milestone.checked,
                to: Milestone.downloaded
            )
            // An 18 GB download that only moves a bar looks stalled, so the
            // status line carries the rate it is actually running at.
            self.state.currentFile = [installer.title, progress.rate]
                .compactMap { $0 }
                .joined(separator: " · ")
        }
    }

    // The privileged step reports by writing to its log; this maps what it has
    // written so far onto the stage and the bar.
    private func report(_ output: String, copying expectedBytes: Int64) {
        guard let report = CreateInstallMediaOutput.read(output, expecting: expectedBytes) else { return }

        let reached: Double

        switch report.phase {
        case .preparing:
            state.stage = .preparingInstaller
            reached = Milestone.downloaded
        case .erasing:
            state.stage = .formatting
            reached = Milestone.prepared
        case .writing:
            state.stage = .writingInstaller
            reached = MediaBuilder.overallProgress(
                report.fraction * 100,
                from: Milestone.erased,
                to: Milestone.finished
            )
        case .finished, .stopped:
            return
        }

        state.currentFile = ""

        // A stage can re-report a figure below one already shown - a drive that
        // reports less used than it did, a log re-read - and the bar must not go
        // back.
        state.progress = max(state.progress, reached)
    }

    // Unique per run, so /Volumes/<name> cannot collide with a volume that is
    // already mounted - including one an earlier run left behind.
    private static func volumeName() -> String {
        "CrossBoot-" + UUID().uuidString.prefix(8)
    }
}
