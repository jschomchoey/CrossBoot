import Foundation
import AppKit
import UniformTypeIdentifiers

// The macOS half of the view model. It lives beside the Windows half rather than
// inside it so neither declaration grows past what one screen can hold.
@MainActor
extension CrossBootViewModel {

    // MARK: - Versions

    // Apple's catalog is the list that matters: it is not filtered by hardware,
    // so it reaches releases older and newer than the one this Mac is offered.
    // softwareupdate is asked alongside it only to fill in anything the catalog
    // did not carry, and neither is allowed to fail the other.
    func loadMacOSVersions(refresh: Bool = false) async {
        guard !isLoadingVersions, refresh || !loadedVersions else { return }

        isLoadingVersions = true
        defer { isLoadingVersions = false }

        let catalog = Task { try await SoftwareCatalog.shared.installers(refresh: refresh) }
        let offered = Task { try await InstallerSource.softwareUpdateInstallers() }

        var problem: String?
        var fetched: [MacOSInstaller] = []

        do {
            fetched = try await catalog.value
        } catch {
            Log.process.error("Could not read the macOS catalog: \(error.localizedDescription, privacy: .public)")
            problem = error.localizedDescription
        }

        let listed = (try? await offered.value) ?? []

        remoteInstallers = (fetched + listed).sorted { $0.version > $1.version }
        refreshVersionList()

        // A catalog that could not be reached still leaves whatever the user
        // added and whatever softwareupdate offered, so it is only worth
        // reporting when it left the list with nothing in it.
        inputError = macOSVersions.isEmpty ? (problem ?? CatalogError.empty.localizedDescription) : nil
        loadedVersions = !macOSVersions.isEmpty
    }

    // MARK: - Local installers

    func selectInstallers() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle, UTType(filenameExtension: "pkg")].compactMap { $0 }
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.message = "Select an \"Install macOS\" app or an InstallAssistant package"

        if panel.runModal() == .OK {
            addInstallers(panel.urls)
        }
    }

    func addInstallers(_ urls: [URL]) {
        guard !processState.isProcessing else { return }

        Task { await readInstallers(urls) }
    }

    // Only what the user added can be taken back out; the fetched list is what
    // Apple publishes.
    func removeInstaller(_ installer: MacOSInstaller) {
        guard !processState.isProcessing else { return }

        localInstallers.removeAll { $0.id == installer.id }
        if selectedVersion?.id == installer.id { selectedVersion = nil }

        refreshVersionList()
        inputError = nil
    }

    func isRemovable(_ installer: MacOSInstaller) -> Bool {
        localInstallers.contains { $0.id == installer.id }
    }

    private func readInstallers(_ urls: [URL]) async {
        isLoadingVersions = true
        defer { isLoadingVersions = false }

        var refusals: [String] = []

        for url in urls {
            do {
                let installer = try await Self.installer(at: url)

                guard !localInstallers.contains(where: { $0.id == installer.id }) else { continue }

                localInstallers.append(installer)
                selectedVersion = installer
            } catch {
                Log.process.error("Could not read installer: \(error.localizedDescription, privacy: .public)")
                refusals.append(error.localizedDescription)
            }
        }

        refreshVersionList()
        inputError = refusals.isEmpty ? nil : refusals.joined(separator: " · ")
    }

    private static func installer(at url: URL) async throws -> MacOSInstaller {
        switch url.pathExtension.lowercased() {
        case "app":
            return try InstallerSource.installer(atApplication: url)
        case "pkg":
            return try await InstallerSource.installer(atPackage: url)
        default:
            throw MacOSMediaPlanError.installerUnreadable(url.lastPathComponent)
        }
    }

    // What the user added goes first - it needs no download - and the rest stays
    // newest first. The same release reaches the list from more than one source,
    // so it is shown once.
    func refreshVersionList() {
        var seen: Set<String> = []

        macOSVersions = (localInstallers + remoteInstallers).filter { installer in
            seen.insert("\(installer.name) \(installer.version) \(installer.build)").inserted
        }

        if let selected = selectedVersion, !macOSVersions.contains(where: { $0.id == selected.id }) {
            selectedVersion = nil
        }

        if selectedVersion == nil {
            selectedVersion = macOSVersions.first { MacOSMediaPlan.refusal(for: $0) == nil }
        }
    }

    // MARK: - Run

    // Without Full Disk Access, createinstallmedia is refused its last step -
    // after the download, and after the drive has been erased and written. That
    // is far too late to find out, so it is asked for before anything starts.
    func confirmAccess() -> Bool {
        guard mediaKind == .macOS, !FullDiskAccess.isGranted else { return true }

        let alert = NSAlert()
        alert.messageText = "CrossBoot needs Full Disk Access"
        alert.informativeText = """
        macOS refuses the last step of writing a macOS installer - making the drive bootable -         unless CrossBoot has Full Disk Access.

        Add CrossBoot under Privacy & Security > Full Disk Access, then quit and reopen it.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            FullDiskAccess.openSettings()
        }

        return false
    }

    var macOSPlan: MacOSMediaPlan? {
        guard let selectedVersion else { return nil }
        return try? MacOSMediaPlan.make(for: selectedVersion)
    }

    func performMacOSRun() async {
        guard let drive = selectedDrive else {
            processState = .failed("No USB drive selected")
            return
        }

        guard let installer = selectedVersion else {
            inputError = MacOSMediaPlanError.noInstaller.localizedDescription
            return
        }

        let plan: MacOSMediaPlan
        do {
            plan = try MacOSMediaPlan.make(for: installer)
        } catch {
            // Nothing has been touched yet, so this is still a setup problem.
            inputError = error.localizedDescription
            return
        }

        do {
            try await powerAssertion.createAssertion(reason: "Creating a macOS installer drive")
        } catch {
            // Not fatal; the run continues without sleep protection.
            Log.process.error("Failed to create power assertion: \(error.localizedDescription, privacy: .public)")
        }

        let builder = MacOSMediaBuilder { [weak self] state in
            self?.processState = state
        }

        do {
            try await builder.build(plan, onto: drive, removingInstaller: removesPreparedInstaller)

            showAlert(
                title: "Success",
                message: Self.successMessage(for: plan, removesInstaller: removesPreparedInstaller),
                style: .informational
            )
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

    private static func successMessage(for plan: MacOSMediaPlan, removesInstaller: Bool) -> String {
        let installer = plan.installer
        var message = "The drive is ready with \(installer.title). Hold Option at startup to boot from it."

        // Preparing the installer leaves it in /Applications, which is several
        // gigabytes the user did not ask to keep.
        // A `where` on one pattern of a multi-pattern case guards only that
        // pattern, so the condition is kept out of the switch entirely.
        let prepared: Bool
        switch installer.origin {
        case .application: prepared = false
        case .catalog, .package, .softwareUpdate: prepared = true
        }

        if prepared, !removesInstaller {
            message += "\n\n\(installer.applicationURL.lastPathComponent) was left in /Applications "
            message += "(\(installer.sizeBytes.formattedSize)). You can move it to the Trash."
        }

        return message
    }
}
