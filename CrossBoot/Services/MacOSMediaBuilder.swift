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
    // What the run actually does decides it. Writing the drive is tens of
    // minutes of a USB stick with no cache left to hide behind, and a download
    // is tens of minutes of network; expanding a package is a few minutes of
    // this Mac's own disk, and the erase is seconds. A run with nothing to
    // download must not spend a third of the bar not downloading anything.
    struct Bar: Equatable {
        // Where the download ends, where expanding the installer ends, and
        // where the erase ends and the drive starts being written.
        let downloaded: Double
        let prepared: Double
        let erased: Double

        // Before any of it: the drive has been checked and nothing else.
        static let checked: Double = 2
        static let finished: Double = 100

        // Downloaded from Apple, then expanded, then written.
        static let downloading = Bar(downloaded: 35, prepared: 45, erased: 50)
        // A package already on this Mac: nothing to download, still to expand.
        static let expanding = Bar(downloaded: checked, prepared: 25, erased: 30)
        // An installer application already on this Mac: the write is the run.
        static let writing = Bar(downloaded: checked, prepared: checked, erased: 8)
        // softwareupdate fetches inside the privileged step and says nothing
        // while it does, so that stretch can only be a place on the bar rather
        // than a movement along it.
        static let fetching = Bar(downloaded: checked, prepared: 40, erased: 45)

        static func forRun(with origin: MacOSInstaller.Origin) -> Bar {
            switch origin {
            case .catalog: return .downloading
            case .package: return .expanding
            case .application: return .writing
            case .softwareUpdate: return .fetching
            }
        }
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
        state.progress = Bar.checked

        // What the privileged step will be asked to do is decided before the
        // password is asked for, so the prompt can come first and the download
        // can run while the step waits for it.
        let preparation = try await prepare(plan.installer)

        state = ProcessState(stage: .authorizing, progress: Bar.checked)

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
                try await self.fetch(download, for: plan.installer, on: preparation.bar)
            }

            try Task.checkCancellation()

            // The drive was last checked before a download that can run for an
            // hour, and the erase is the step that cannot be taken back.
            try await self.diskManager.verifyStillPresent(drive)
        } onOutput: { [weak self] output in
            self?.report(output, copying: plan.installer.sizeBytes, on: preparation.bar)
        }

        state = ProcessState(stage: .done, progress: Bar.finished)
    }

    // The package Apple publishes, and where this run puts it.
    private struct Download {
        let url: URL
        let destination: URL
    }

    // What the privileged step has to do, what has to be downloaded before it
    // can do it, and the bar that shape of run draws.
    private typealias Prepared = (step: PrivilegedRunner.Preparation, download: Download?, bar: Bar)

    private func prepare(_ installer: MacOSInstaller) async throws -> Prepared {
        switch installer.origin {
        case .catalog(_, let packageURL):
            let directory = try await scratch.makeTemporaryDirectory()
            let destination = directory.appendingPathComponent("InstallAssistant.pkg")

            return (
                .package(destination),
                Download(url: packageURL, destination: destination),
                Bar.forRun(with: installer.origin)
            )

        case .package(let url):
            return (.package(url), nil, Bar.forRun(with: installer.origin))

        case .softwareUpdate:
            return (.fetch(version: installer.version.description), nil, Bar.forRun(with: installer.origin))

        case .application:
            return (.application, nil, Bar.forRun(with: installer.origin))
        }
    }

    private func fetch(_ download: Download, for installer: MacOSInstaller, on bar: Bar) async throws {
        state = ProcessState(stage: .downloading, progress: Bar.checked)

        try await downloader.download(
            from: download.url,
            expecting: installer.sizeBytes,
            to: download.destination
        ) { [weak self] progress in
            guard let self else { return }

            self.state.progress = MediaBuilder.overallProgress(
                progress.percent,
                from: Bar.checked,
                to: bar.downloaded
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
    private func report(_ output: String, copying expectedBytes: Int64, on bar: Bar) {
        guard let report = CreateInstallMediaOutput.read(output, expecting: expectedBytes) else { return }

        let reached: Double

        switch report.phase {
        case .preparing:
            state.stage = .preparingInstaller
            reached = bar.downloaded
        case .erasing:
            state.stage = .formatting
            reached = bar.prepared
        case .writing:
            state.stage = .writingInstaller
            reached = MediaBuilder.overallProgress(
                report.fraction * 100,
                from: bar.erased,
                to: Bar.finished
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
