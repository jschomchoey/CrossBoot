import Foundation
import AppKit
import UniformTypeIdentifiers

@MainActor
class CrossBootViewModel: ObservableObject {
    // MARK: - Published Properties
    @Published var mediaKind: MediaKind = .windows
    @Published var drives: [Drive] = []
    @Published var selectedDrive: Drive?
    @Published var isoFiles: [ISOFile] = []

    // macOS mode. The list merges what Apple's catalog publishes, what
    // softwareupdate offers this Mac, and anything the user pointed at.
    @Published var macOSVersions: [MacOSInstaller] = []
    @Published var selectedVersion: MacOSInstaller?
    @Published var isLoadingVersions = false
    // The catalog carries releases this Mac cannot build; they are hidden until
    // asked for so the list is not mostly entries that would be refused.
    @Published var showsUnusableVersions = false
    // Preparing an installer leaves 12-18 GB in /Applications. Keeping it is the
    // default because deleting what the user may want back is the worse mistake.
    @Published var removesPreparedInstaller = false
    @Published var bypassRequirements = false
    @Published var bypassOnlineAccount = false
    @Published var processState = ProcessState()
    @Published var isScanning = false
    @Published var isAnalyzing = false

    // Bad input and scan failures keep the user on the setup form; only a run
    // that actually started can finish in a failed state. They are kept apart
    // because a scan runs on its own: the disk monitor rescans whenever any
    // disk appears - an ISO being mounted counts - and clearing one message
    // there used to wipe the refusal the user was still reading.
    @Published var sourceError: String?
    @Published var driveError: String?

    // What the user just did outranks what the monitor found on its own.
    var inputError: String? { sourceError ?? driveError }

    // MARK: - Services
    private let diskManager = DiskManager.shared
    let isoHandler = ISOHandler.shared
    private let wimLibService = WimLibService.shared
    let powerAssertion = PowerAssertionManager.shared

    // MARK: - Task Management
    var currentTask: Task<Void, Never>?

    // The catalog is fetched once per launch; it is a 7 MB list plus one small
    // file per product, and it does not change while the app is open.
    var loadedVersions = false
    // Installers the user pointed at, kept across a refresh of the found list.
    var addedInstallers: [MacOSInstaller] = []
    // What Apple's catalog, softwareupdate and /Applications last reported, kept
    // so adding an installer by hand does not mean asking any of them again.
    var offeredInstallers: [MacOSInstaller] = []

    // Analysis runs one batch at a time, in the order the batches arrived.
    private var analysisTask: Task<Void, Never>?
    private var pendingBatches = 0

    // MARK: - Initialization

    init() {
        Task {
            await diskManager.startMonitoring { [weak self] in
                Task { @MainActor in
                    guard self?.processState.isProcessing == false else { return }
                    await self?.scanDrives()
                }
            }
        }
    }

    // MARK: - Drive Operations

    func scanDrives() async {
        isScanning = true
        defer { isScanning = false }

        do {
            drives = try await diskManager.listRemovableDrives()
            driveError = nil
        } catch {
            // Without this the UI just says "No USB Drive Found" and hides why.
            drives = []
            Log.disk.error("Failed to list drives: \(error.localizedDescription, privacy: .public)")
            // No alert: this also runs from the disk monitor, with nobody
            // waiting on an answer.
            driveError = "Could not list drives: \(error.localizedDescription)"
        }

        // Match on the whole drive, not just its identifier: identifiers are
        // reused across replugs, so a stale value can describe a different disk.
        if let selected = selectedDrive {
            selectedDrive = drives.first { $0 == selected } ?? drives.first
        } else {
            selectedDrive = drives.first
        }
    }

    // MARK: - ISO Operations

    func selectISOs() {
        let panel = NSOpenPanel()
        if let isoType = UTType(filenameExtension: "iso") {
            panel.allowedContentTypes = [isoType]
        }
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Select one or more Windows ISO files"

        if panel.runModal() == .OK {
            addISOs(panel.urls)
        }
    }

    func addISOs(_ urls: [URL]) {
        guard !processState.isProcessing else { return }

        // A second drop can land while the first is still being read. Running
        // both at once let each one check the list before the other appended to
        // it - listing the same ISO twice - and let the first to finish report
        // that analysis was over while the other was still mounting. Batches
        // are queued instead, and the flag stays up until the last one is done.
        pendingBatches += 1
        isAnalyzing = true

        let previous = analysisTask
        analysisTask = Task { [weak self] in
            await previous?.value
            let refusals = await self?.analyze(urls) ?? []

            guard let self else { return }
            // Reported once the batch is out of the way, so the alert does not
            // stand over a list still saying it is reading.
            self.pendingBatches -= 1
            self.isAnalyzing = self.pendingBatches > 0
            self.refuse(refusals, title: "Could not add")
        }
    }

    func removeISO(_ iso: ISOFile) {
        guard !processState.isProcessing else { return }

        isoFiles.removeAll { $0.id == iso.id }
        sourceError = nil
    }

    // Each ISO is mounted and inspected as it is added, so a combination Windows
    // Setup could not handle is refused here rather than after the drive is
    // erased. It also gives the list something to say about each file.
    private func analyze(_ urls: [URL]) async -> [String] {
        // A file that was refused has to still be reported once the rest of the
        // batch has been read: reporting as we go let one good ISO clear the
        // message from the one dropped beside it.
        var refusals: [String] = []

        for url in urls {
            guard url.pathExtension.lowercased() == "iso" else {
                refusals.append("\(url.lastPathComponent) is not an ISO file")
                continue
            }

            guard !isoFiles.contains(where: { $0.url == url }) else { continue }

            do {
                let iso = try await isoHandler.analyze(url)

                if let conflict = architectureConflict(with: iso) {
                    refusals.append(conflict)
                    continue
                }

                isoFiles.append(iso)
                // The newest Windows goes first: it supplies the boot files, and
                // the setup menu lists the images in this order.
                isoFiles.sort { $0.newestBuild > $1.newestBuild }

                processState = ProcessState()
            } catch {
                Log.process.error("Failed to analyze ISO: \(error.localizedDescription, privacy: .public)")
                refusals.append("Could not read \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        return refusals
    }

    private func architectureConflict(with iso: ISOFile) -> String? {
        guard let added = iso.architecture,
              let existing = isoFiles.compactMap(\.architecture).first,
              added != existing else {
            return nil
        }

        return "\(iso.name) is \(added.name) but the other ISOs are \(existing.name). It was not added."
    }

    // MARK: - Main Process

    func createBootableUSB() {
        // The run reports for itself from here; nothing it was started despite
        // may keep the status line.
        sourceError = nil
        driveError = nil

        currentTask = Task {
            switch mediaKind {
            case .windows: await performWindowsRun()
            case .macOS: await performMacOSRun()
            }
            currentTask = nil
        }
    }

    // Each mode reports its own refusals, and the one left over from the other
    // mode is about to describe sources this mode does not have.
    func select(_ kind: MediaKind) {
        guard !processState.isProcessing, kind != mediaKind else { return }

        mediaKind = kind
        sourceError = nil
        processState = ProcessState()
    }

    func abortProcess() {
        guard let task = currentTask else { return }

        processState.stage = .aborting
        task.cancel()

        Task {
            // Wait for the run to unwind and release its resources; setting the
            // state before that lets a late progress callback overwrite it.
            await task.value
            processState = ProcessState(stage: .aborted, progress: 0)
        }
    }

    private func performWindowsRun() async {
        guard let drive = selectedDrive else {
            processState = .failed("No USB drive selected")
            return
        }

        let plan: InstallMediaPlan
        do {
            plan = try InstallMediaPlan.make(from: isoFiles)
        } catch {
            // Nothing has been touched yet, so this is still a setup problem.
            refuse([error.localizedDescription], title: "Could not start")
            return
        }

        // Create power assertion to prevent system sleep during USB creation
        do {
            try await powerAssertion.createAssertion(reason: "Creating Windows bootable USB")
        } catch {
            // Not fatal; the run continues without sleep protection.
            Log.process.error("Failed to create power assertion: \(error.localizedDescription, privacy: .public)")
        }

        let builder = MediaBuilder { [weak self] state in
            self?.processState = state
        }

        do {
            try await builder.build(
                plan,
                onto: drive,
                bypassRequirements: bypassRequirements,
                bypassOnlineAccount: bypassOnlineAccount
            )

            showAlert(title: "Success", message: Self.successMessage(for: plan), style: .informational)
        } catch is CancellationError {
            // abortProcess owns the aborted state once this run has unwound.
            await releaseResources()
            return
        } catch {
            await releaseResources()

            processState = .failed(error.localizedDescription)
            showAlert(title: "Could not finish", message: error.localizedDescription, style: .critical)
            return
        }

        await releaseResources()
    }

    // Every exit path from a run releases what the run acquired; `defer` cannot
    // await, and deferring a detached Task made the ordering unpredictable.
    func releaseResources() async {
        await isoHandler.cleanup()
        await powerAssertion.releaseAssertion()
    }

    // MARK: - Helpers

    // What the run would do with the ISOs picked so far, so the list can name
    // the base and the section can quote a size before the drive is erased.
    // make() only sorts and de-duplicates a handful of ISOs.
    var plan: InstallMediaPlan? {
        try? InstallMediaPlan.make(from: isoFiles)
    }

    var canStart: Bool {
        guard selectedDrive != nil, !processState.isProcessing else { return false }

        switch mediaKind {
        case .windows: return !isoFiles.isEmpty && !isAnalyzing
        // A version this Mac cannot build is still pickable, so the plan - not
        // the selection - is what says a run can start. Otherwise the button
        // asks to erase the drive and then refuses.
        case .macOS: return macOSPlan != nil && !isLoadingVersions
        }
    }

    private static func successMessage(for plan: InstallMediaPlan) -> String {
        guard case .merged(_, let groups, _) = plan.mode else {
            return "The drive is ready. You can eject it and boot from it."
        }

        let count = groups.flatMap(\.images).count
        return "The drive is ready with \(count) Windows editions. You can eject it and boot from it."
    }

    // A refusal the user's own action ran into: a drop, the open panel, the
    // button. The status line alone was missed, so it is also said once in an
    // alert - the line at the bottom of the window is not where anyone looks.
    // No reasons means the last refusal no longer stands.
    func refuse(_ reasons: [String], title: String) {
        guard !reasons.isEmpty else {
            sourceError = nil
            return
        }

        // The status line has two lines for all of them; the alert has room to
        // give each its own.
        sourceError = reasons.joined(separator: " · ")
        showAlert(title: title, message: reasons.joined(separator: "\n"), style: .warning)
    }

    func showAlert(title: String, message: String, style: NSAlert.Style) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Show confirmation dialog
    func confirmErase() -> Bool {
        guard let drive = selectedDrive else { return false }

        let alert = NSAlert()
        alert.messageText = "Erase Everything?"
        alert.informativeText = """
        All data on "\(drive.name)" (\(drive.device), \(drive.sizeFormatted)) will be permanently deleted.
        """
        alert.alertStyle = .warning

        let erase = alert.addButton(withTitle: "Erase")
        let cancel = alert.addButton(withTitle: "Cancel")

        // Return must not erase a drive by accident.
        erase.keyEquivalent = ""
        cancel.keyEquivalent = "\r"

        return alert.runModal() == .alertFirstButtonReturn
    }
}
