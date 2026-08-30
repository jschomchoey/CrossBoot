import Foundation
import AppKit
import UniformTypeIdentifiers

@MainActor
class CrossBootViewModel: ObservableObject {
    // MARK: - Published Properties
    @Published var drives: [Drive] = []
    @Published var selectedDrive: Drive?
    @Published var isoFiles: [ISOFile] = []
    @Published var bypassRequirements = false
    @Published var bypassOnlineAccount = false
    @Published var processState = ProcessState()
    @Published var isScanning = false
    @Published var isAnalyzing = false

    // Bad input and scan failures keep the user on the setup form; only a run
    // that actually started can finish in a failed state.
    @Published var inputError: String?

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
        defer { isScanning = false }

        do {
            drives = try await diskManager.listRemovableDrives()
            inputError = nil
        } catch {
            // Without this the UI just says "No USB Drive Found" and hides why.
            drives = []
            Log.disk.error("Failed to list drives: \(error.localizedDescription, privacy: .public)")
            inputError = "Could not list drives: \(error.localizedDescription)"
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

        Task { await analyze(urls) }
    }

    func removeISO(_ iso: ISOFile) {
        guard !processState.isProcessing else { return }

        isoFiles.removeAll { $0.id == iso.id }
        inputError = nil
    }

    // Each ISO is mounted and inspected as it is added, so a combination Windows
    // Setup could not handle is refused here rather than after the drive is
    // erased. It also gives the list something to say about each file.
    private func analyze(_ urls: [URL]) async {
        isAnalyzing = true
        defer { isAnalyzing = false }

        for url in urls {
            guard url.pathExtension.lowercased() == "iso" else {
                inputError = "\(url.lastPathComponent) is not an ISO file"
                continue
            }

            guard !isoFiles.contains(where: { $0.url == url }) else { continue }

            do {
                let iso = try await isoHandler.analyze(url)

                if let conflict = architectureConflict(with: iso) {
                    inputError = conflict
                    continue
                }

                isoFiles.append(iso)
                // The newest Windows goes first: it supplies the boot files, and
                // the setup menu lists the images in this order.
                isoFiles.sort { $0.newestBuild > $1.newestBuild }

                inputError = nil
                processState = ProcessState()
            } catch {
                Log.process.error("Failed to analyze ISO: \(error.localizedDescription, privacy: .public)")
                inputError = "Could not read \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
    }

    private func architectureConflict(with iso: ISOFile) -> String? {
        guard let added = iso.architecture,
              let existing = isoFiles.compactMap(\.architecture).first,
              added != existing else {
            return nil
        }

        return """
        \(iso.name) is \(added.name) but the drive already holds \(existing.name) media. \
        Windows Setup boots one architecture, so they cannot share a drive.
        """
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
        }
    }

    private func performCreateBootableUSB() async {
        guard let drive = selectedDrive else {
            processState = .failed("No USB drive selected")
            return
        }

        let plan: InstallMediaPlan
        do {
            plan = try InstallMediaPlan.make(from: isoFiles)
        } catch {
            // Nothing has been touched yet, so this is still a setup problem.
            inputError = error.localizedDescription
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
    private func releaseResources() async {
        await isoHandler.cleanup()
        await powerAssertion.releaseAssertion()
    }

    // MARK: - Helpers

    var canStart: Bool {
        selectedDrive != nil && !isoFiles.isEmpty && !isAnalyzing && !processState.isProcessing
    }

    private static func successMessage(for plan: InstallMediaPlan) -> String {
        guard case .merged(_, let groups, _) = plan.mode else {
            return "The drive is ready. You can eject it and boot from it."
        }

        let count = groups.flatMap(\.images).count
        return """
        The drive is ready with \(count) Windows editions from \(groups.count) ISOs. \
        Windows Setup will ask which one to install. Eject it and boot from it.
        """
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
