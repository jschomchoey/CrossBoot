import Foundation
import AppKit

/// Main ViewModel for CrossBoot app
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
    
    // MARK: - Drive Operations
    
    /// Scan for available USB drives
    func scanDrives() async {
        isScanning = true
        drives = await diskManager.listRemovableDrives()
        
        // Auto-select first drive if available
        if selectedDrive == nil, let first = drives.first {
            selectedDrive = first
        }
        
        // Clear selection if drive was removed
        if let selected = selectedDrive, !drives.contains(where: { $0.id == selected.id }) {
            selectedDrive = drives.first
        }
        
        isScanning = false
    }
    
    // MARK: - ISO Operations
    
    /// Show file picker to select ISO
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
    
    /// Handle ISO file drop
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
    
    /// Create bootable USB drive
    func createBootableUSB() async {
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
        
        do {
            // Step 1: Format USB
            processState = ProcessState(stage: .formatting, progress: 2)
            try await diskManager.formatDrive(drive.device)
            processState.progress = 5
            
            // Get USB mount point
            guard let usbPath = await diskManager.getMountPoint(drive.device) else {
                throw DiskError.mountPointNotFound
            }
            
            // Step 2: Mount ISO and analyze
            processState.stage = .analyzing
            mountPoint = try await isoHandler.mountISO(iso.url)
            
            // Check if WIM needs splitting
            let (needsSplit, wimPath) = await isoHandler.checkWIMSize(mountPoint!)
            
            // Step 3: Split WIM if needed
            if needsSplit, let wim = wimPath {
                processState.stage = .splitting
                hasSplit = true
                
                splitTempDir = try await wimLibService.splitWIM(wim) { [weak self] percent in
                    Task { @MainActor in
                        // Split: 5% -> 15%
                        self?.processState.progress = 5 + Double(percent) * 0.1
                    }
                }
                
                await isoHandler.setTempDirectory(splitTempDir!)
            }
            
            // Step 4: Copy files
            processState.stage = .copying
            
            try await isoHandler.copyFilesToUSB(
                from: mountPoint!,
                to: usbPath,
                splitTempDir: splitTempDir,
                skipInstallWim: hasSplit
            ) { [weak self] progress, fileName in
                guard let self = self else { return }
                
                // Adjust progress based on whether split happened
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
            
            // Step 5: Create autounattend.xml if needed
            if bypassRequirements || bypassOnlineAccount {
                try await isoHandler.createAutounattend(
                    at: usbPath,
                    bypassRequirements: bypassRequirements,
                    bypassOnlineAccount: bypassOnlineAccount
                )
            }
            
            // Done!
            processState = ProcessState(stage: .done, progress: 100)
            
            // Show success alert
            showAlert(
                title: "Success",
                message: "Bootable USB created successfully!",
                style: .informational
            )
            
        } catch {
            processState.stage = .error(error.localizedDescription)
            showAlert(
                title: "Error",
                message: error.localizedDescription,
                style: .critical
            )
        }
        
        // Cleanup
        await isoHandler.cleanup()
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
        alert.informativeText = "All data on \"\(drive.name)\" will be permanently deleted."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Erase")
        alert.addButton(withTitle: "Cancel")
        
        return alert.runModal() == .alertFirstButtonReturn
    }
}
