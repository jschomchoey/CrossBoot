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
        
        var hasSplit = false
        var splitTempDir: URL?
        var mountPoint: String?
        
        // Create power assertion to prevent system sleep during USB creation
        do {
            try await powerAssertion.createAssertion(reason: "Creating Windows bootable USB")
        } catch {
            print("⚠️ Failed to create power assertion: \(error.localizedDescription)")
            // Continue anyway - this is not fatal
        }

        do {
            // Check before erasing rather than filling the drive and failing
            // partway through the copy.
            guard drive.size >= iso.sizeBytes else {
                throw DiskError.insufficientSpace(required: iso.sizeBytes, available: drive.size)
            }

            processState = ProcessState(stage: .formatting, progress: 2)
            try await diskManager.formatDrive(drive)
            
            try Task.checkCancellation()
            processState.progress = 5
            
            guard let usbPath = await diskManager.getMountPoint(drive.device) else {
                throw DiskError.mountPointNotFound
            }
            
            processState.stage = .analyzing
            mountPoint = try await isoHandler.mountISO(iso.url)
            
            guard let safeMountPoint = mountPoint else {
                throw ISOError.mountFailed
            }
            let (needsSplit, wimPath) = await isoHandler.checkWIMSize(safeMountPoint)
            
            try Task.checkCancellation()
            
            if needsSplit, let wim = wimPath {
                processState.stage = .splitting
                hasSplit = true
                
                splitTempDir = try await wimLibService.splitWIM(wim) { [weak self] percent in
                    Task { @MainActor in
                        // Split: 5% -> 15%
                        self?.processState.progress = 5 + Double(percent) * 0.1
                    }
                }
                
                guard let tempDir = splitTempDir else {
                    throw ISOError.copyFailed("Split temporary directory not found")
                }
                
                await isoHandler.setTempDirectory(tempDir)
            }
            
            processState.stage = .copying
            
            guard let sourceMount = mountPoint else {
                throw ISOError.mountFailed
            }
            
            try await isoHandler.copyFilesToUSB(
                from: sourceMount,
                to: usbPath,
                splitTempDir: splitTempDir,
                skipInstallWim: hasSplit
            ) { [weak self] progress, fileName in
                guard let self = self else { return }
                
                // Adjust progress 
                let adjusted: Double
                if hasSplit {
                    // Split happened: 15% -> 99%
                    adjusted = 15 + progress * 0.84
                } else {
                    // No split: 5% -> 99%
                    adjusted = 5 + progress * 0.94
                }
                
                self.processState.progress = adjusted
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
