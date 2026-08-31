import Foundation

// Turns a plan into a finished drive: mounts the sources, merges and splits the
// install images, then copies everything across.
//
// The boot chain is never rebuilt. Every signed binary - bootmgfw.efi, boot.wim,
// setup - is copied byte for byte from the base ISO, so firmware sees the same
// Microsoft signatures it would on single-version media and Secure Boot needs no
// shim and no enrolled key. Only install.wim is rewritten, and setup reads that
// as data long after the firmware has handed over.
@MainActor
final class MediaBuilder {
    private let diskManager = DiskManager.shared
    private let isoHandler = ISOHandler.shared
    private let wimLibService = WimLibService.shared

    private let onUpdate: (ProcessState) -> Void

    private var state = ProcessState() {
        didSet { onUpdate(state) }
    }

    // Points on the overall progress bar where each stage hands over to the next.
    private enum Milestone {
        static let formatStarted: Double = 2
        static let formatted: Double = 5
        static let mergeEnd: Double = 65
        static let splitShare: Double = 15
        static let copied: Double = 99
    }

    // Rescales a stage's own 0-100 progress into its slice of the overall bar.
    static func overallProgress(_ stageProgress: Double, from start: Double, to end: Double) -> Double {
        start + stageProgress / 100 * (end - start)
    }

    init(onUpdate: @escaping (ProcessState) -> Void) {
        self.onUpdate = onUpdate
    }

    func build(
        _ plan: InstallMediaPlan,
        onto drive: Drive,
        bypassRequirements: Bool,
        bypassOnlineAccount: Bool
    ) async throws {
        // Check before erasing rather than filling the drive and failing
        // partway through the copy.
        guard drive.size >= plan.estimatedDriveBytes else {
            throw DiskError.insufficientSpace(required: plan.estimatedDriveBytes, available: drive.size)
        }

        try Self.ensureScratchSpace(plan.estimatedTemporaryBytes)

        // Every ISO is mounted before the drive is touched. One that was moved
        // or unplugged since it was picked then fails with the drive intact,
        // which matters more the more ISOs a run depends on.
        state = ProcessState(stage: .analyzing)
        var mounts: [URL: String] = [:]
        for source in plan.sources {
            mounts[source.url] = try await isoHandler.mountISO(source.url)
        }

        guard let baseMount = mounts[plan.base.url] else {
            throw ISOError.mountFailed
        }

        state = ProcessState(stage: .formatting, progress: Milestone.formatStarted)
        try await diskManager.formatDrive(drive)

        try Task.checkCancellation()
        state.progress = Milestone.formatted

        guard let usbPath = await diskManager.getMountPoint(drive.device) else {
            throw DiskError.mountPointNotFound
        }

        let prepared = try await prepareInstallSources(plan, mounts: mounts)

        state.stage = .copying
        state.currentFile = ""

        try await isoHandler.copyFilesToUSB(
            from: baseMount,
            to: usbPath,
            excluding: prepared.excluded,
            installSources: prepared.directory
        ) { [weak self] progress, fileName in
            guard let self else { return }

            self.state.progress = Self.overallProgress(
                progress,
                from: prepared.progress,
                to: Milestone.copied
            )
            self.state.currentFile = fileName
        }

        if bypassRequirements || bypassOnlineAccount {
            try await isoHandler.createAutounattend(
                at: usbPath,
                architecture: plan.architecture,
                bypassRequirements: bypassRequirements,
                bypassOnlineAccount: bypassOnlineAccount
            )
        }

        state = ProcessState(stage: .done, progress: 100)
    }

    // What goes into sources/ on the drive, which paths the base ISO must not
    // contribute, and where the progress bar stands afterwards.
    private typealias PreparedSources = (directory: URL?, excluded: Set<String>, progress: Double)

    private func prepareInstallSources(
        _ plan: InstallMediaPlan,
        mounts: [URL: String]
    ) async throws -> PreparedSources {
        switch plan.mode {
        case .single(let iso):
            // One ISO is copied as it is; only an image too big for FAT32
            // needs splitting first.
            guard let image = iso.installImage,
                  image.sizeBytes > WimLibService.fat32FileLimit,
                  let mount = mounts[iso.url] else {
                return (nil, [], Milestone.formatted)
            }

            let wimPath = (mount as NSString).appendingPathComponent(image.relativePath)
            let splitEnd = Milestone.formatted + Milestone.splitShare
            let parts = try await splitInstallImage(at: wimPath, from: Milestone.formatted, to: splitEnd)

            return (parts, [image.relativePath.lowercased()], splitEnd)

        case .merged(let base, let groups, let compression):
            var excluded: Set<String> = []
            if let image = base.installImage {
                excluded.insert(image.relativePath.lowercased())
            }
            // ei.cfg pins setup to a single edition and hides the picker, which
            // is the whole point of merged media.
            excluded.insert("sources/ei.cfg")

            state.stage = .merging

            let workDirectory = try await isoHandler.makeTemporaryDirectory()
            let merged = workDirectory.appendingPathComponent("install.wim")

            try await mergeImages(groups, compression: compression, mounts: mounts, into: merged)

            guard Self.fileSize(at: merged) > WimLibService.fat32FileLimit else {
                return (workDirectory, excluded, Milestone.mergeEnd)
            }

            let splitEnd = Milestone.mergeEnd + Milestone.splitShare
            let parts = try await splitInstallImage(at: merged.path, from: Milestone.mergeEnd, to: splitEnd)

            // The merged image was only an input to the split; dropping it now
            // frees its space before the copy starts.
            await isoHandler.removeItem(at: merged)

            return (parts, excluded, splitEnd)
        }
    }

    private func mergeImages(
        _ groups: [InstallMediaPlan.SourceGroup],
        compression: WimLibService.Compression,
        mounts: [URL: String],
        into destination: URL
    ) async throws {
        let weights = groups.flatMap(\.images).map { max($0.totalBytes, 1) }
        let totalWeight = max(weights.reduce(0, +), 1)
        var completedWeight: Int64 = 0

        for group in groups {
            guard let mount = mounts[group.source.url], let image = group.source.installImage else {
                throw MediaPlanError.noInstallImage(group.source.name)
            }

            let wimPath = (mount as NSString).appendingPathComponent(image.relativePath)

            for planned in group.images {
                try Task.checkCancellation()

                let weight = max(planned.totalBytes, 1)
                let alreadyDone = completedWeight

                try await wimLibService.export(
                    image: planned.index,
                    from: wimPath,
                    to: destination,
                    named: planned.name,
                    compression: compression
                ) { [weak self] percent in
                    guard let self else { return }

                    let done = Double(alreadyDone) + Double(weight) * Double(percent) / 100
                    self.state.progress = Self.overallProgress(
                        done / Double(totalWeight) * 100,
                        from: Milestone.formatted,
                        to: Milestone.mergeEnd
                    )
                    self.state.currentFile = planned.name
                }

                completedWeight += weight
            }
        }
    }

    private func splitInstallImage(at wimPath: String, from start: Double, to end: Double) async throws -> URL {
        let parts = try await isoHandler.makeTemporaryDirectory()

        state.stage = .splitting
        state.currentFile = ""

        try await wimLibService.splitWIM(wimPath, into: parts) { [weak self] percent in
            self?.state.progress = Self.overallProgress(Double(percent), from: start, to: end)
        }

        return parts
    }


    // Merging rewrites install.wim on the user's own disk before anything
    // reaches the drive, and that scratch copy is the run's real space cost.
    private static func ensureScratchSpace(_ required: Int64) throws {
        guard required > 0 else { return }

        let temporary = FileManager.default.temporaryDirectory
        let values = try temporary.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])

        guard let available = values.volumeAvailableCapacityForImportantUsage, available < required else { return }

        throw DiskError.insufficientScratchSpace(required: required, available: Int64(available))
    }

    private static func fileSize(at url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attributes?[.size] as? Int64 ?? 0
    }

}
