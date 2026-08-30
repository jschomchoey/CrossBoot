import Foundation
import AppKit

@MainActor
class CrossBootViewModel: ObservableObject {
    // MARK: - Published Properties
    @Published var drives: [Drive] = []
    @Published var selectedDrive: Drive?
    @Published var isoFile: ISOFile?
    @Published var bypassRequirements = false
    @Published var bypassOnlineAccount = false
    @Published var processState = ProcessState()
    @Published var isScanning = false
    
    // MARK: - Services
    private let diskManager = DiskManager.shared
    private let isoHandler = ISOHandler.shared
    private let wimLibService = WimLibService.shared
    private let powerAssertion = PowerAssertionManager.shared
    
    // MARK: - Task Management
    private var currentTask: Task<Void, Never>?

    // Points on the overall progress bar where each stage hands over to the next.
    private enum Milestone {
        static let formatStarted: Double = 2
        static let formatted: Double = 5
        static let split: Double = 15
        static let copied: Double = 99
    }

    // Rescales a stage's own 0-100 progress into its slice of the overall bar.
    private static func overallProgress(_ stageProgress: Double, from start: Double, to end: Double) -> Double {
        start + stageProgress / 100 * (end - start)
    }
    
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
        drives = await diskManager.listRemovableDrives()
        
        // Match on the whole drive, not just its identifier: identifiers are
        // reused across replugs, so a stale value can describe a different disk.
        if let selected = selectedDrive {
            selectedDrive = drives.first { $0 == selected } ?? drives.first
        } else {
            selectedDrive = drives.first
        }
        
        isScanning = false
    }
    
    // MARK: - ISO Operations
    
    func selectISO() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "iso")!]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Select a Windows ISO file"
        
        if panel.runModal() == .OK, let url = panel.url {
            handleISOSelection(url)
        }
    }
    
    func handleISODrop(_ urls: [URL]) {
        guard let url = urls.first,
              url.pathExtension.lowercased() == "iso" else {
            return
        }
        handleISOSelection(url)
    }
    
    private func handleISOSelection(_ url: URL) {
        do {
            isoFile = try ISOFile(url: url)
        } catch {
            processState.stage = .error("Failed to read ISO: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Main Process
    
    func createBootableUSB() {
        currentTask = Task {
            await performCreateBootableUSB()
            currentTask = nil
        }
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

            showAlert(
                title: "Aborted",
                message: "The process stopped before finishing, so the drive is not bootable. Run it again to complete the drive.",
                style: .warning
            )
        }
    }
    
    private func performCreateBootableUSB() async {
        guard let drive = selectedDrive else {
            processState.stage = .error("No USB drive selected")
            return
        }
        
        guard let iso = isoFile else {
            processState.stage = .error("No ISO file selected")
            return
        }
        
        var splitTempDir: URL?

        // Create power assertion to prevent system sleep during USB creation
        do {
            try await powerAssertion.createAssertion(reason: "Creating Windows bootable USB")
        } catch {
            // Not fatal; the run continues without sleep protection.
            Log.process.error("Failed to create power assertion: \(error.localizedDescription, privacy: .public)")
        }

        do {
            // Check before erasing rather than filling the drive and failing
            // partway through the copy.
            guard drive.size >= iso.sizeBytes else {
                throw DiskError.insufficientSpace(required: iso.sizeBytes, available: drive.size)
            }

            processState = ProcessState(stage: .formatting, progress: Milestone.formatStarted)
            try await diskManager.formatDrive(drive)

            try Task.checkCancellation()
            processState.progress = Milestone.formatted

            guard let usbPath = await diskManager.getMountPoint(drive.device) else {
                throw DiskError.mountPointNotFound
            }

            processState.stage = .analyzing
            let mountPoint = try await isoHandler.mountISO(iso.url)
            let (needsSplit, wimPath) = await isoHandler.checkWIMSize(mountPoint)

            try Task.checkCancellation()

            if needsSplit, let wim = wimPath {
                processState.stage = .splitting

                let tempDir = try await wimLibService.splitWIM(wim) { [weak self] percent in
                    Task { @MainActor in
                        self?.processState.progress = Self.overallProgress(
                            Double(percent),
                            from: Milestone.formatted,
                            to: Milestone.split
                        )
                    }
                }

                splitTempDir = tempDir
                await isoHandler.setTempDirectory(tempDir)
            }

            processState.stage = .copying

            // Copying picks up wherever the previous stage left off.
            let copyStart = splitTempDir == nil ? Milestone.formatted : Milestone.split

            try await isoHandler.copyFilesToUSB(
                from: mountPoint,
                to: usbPath,
                splitTempDir: splitTempDir,
                skipInstallWim: splitTempDir != nil
            ) { [weak self] progress, fileName in
                guard let self = self else { return }

                self.processState.progress = Self.overallProgress(
                    progress,
                    from: copyStart,
                    to: Milestone.copied
                )
                self.processState.currentFile = fileName
            }

            if bypassRequirements || bypassOnlineAccount {
                try await isoHandler.createAutounattend(
                    at: usbPath,
                    bypassRequirements: bypassRequirements,
                    bypassOnlineAccount: bypassOnlineAccount
                )
            }
            
            processState = ProcessState(stage: .done, progress: 100)
            
            showAlert(
                title: "Success",
                message: "Bootable USB created successfully!",
                style: .informational
            )
            
        } catch is CancellationError {
            // abortProcess owns the aborted state once this run has unwound.
            await releaseResources()
            return
        } catch {
            await releaseResources()

            processState.stage = .error(error.localizedDescription)
            showAlert(
                title: "Error",
                message: error.localizedDescription,
                style: .critical
            )
            return
        }

        await releaseResources()
    }

    // Every exit path from a run releases what the run acquired; `defer` cannot
    // await, and deferring a detached Task made the ordering unpredictable.
    private func releaseResources() async {
        await isoHandler.cleanup()
        await powerAssertion.releaseAssertion()
    }
    
    // MARK: - Helpers
    
    var canStart: Bool {
        selectedDrive != nil && isoFile != nil && !processState.isProcessing
    }
    
    private func showAlert(title: String, message: String, style: NSAlert.Style) {
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
