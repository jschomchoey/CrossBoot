import SwiftUI
import UniformTypeIdentifiers

/// The whole app on one page: the mode sits in the toolbar, the setup form
/// under it, and the run reports at the bottom. Everything stays put while a run
/// is in flight - the form locks and the button turns into Stop - and both modes
/// lay out to the one height the window is fixed at.
struct ContentView: View {
    @StateObject private var viewModel: CrossBootViewModel

    @State private var isDropTargeted = false
    @State private var refreshRotation: Double = 0

    init(viewModel: @autoclosure @escaping () -> CrossBootViewModel = CrossBootViewModel()) {
        _viewModel = StateObject(wrappedValue: viewModel())
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    sourceRows
                } header: {
                    sourceHeader
                } footer: {
                    // Whatever this reports, it reports in the same space: the
                    // page cannot change height between one run and the next.
                    sourceFooter
                        .lineLimit(2, reservesSpace: true)
                }

                Section {
                    DriveSelectorView(
                        drives: viewModel.drives,
                        selectedDrive: $viewModel.selectedDrive
                    )

                    LabeledContent("Device") {
                        Text(viewModel.selectedDrive?.device ?? "-")
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(viewModel.selectedDrive == nil ? Color.secondary : Color.primary)
                    }
                } header: {
                    destinationHeader
                } footer: {
                    destinationFooter
                }

                Section("Advanced Options") {
                    if viewModel.mediaKind == .windows {
                        Toggle(isOn: $viewModel.bypassRequirements) {
                            Text("Bypass Windows 11 Requirements")
                            Text("Skips the TPM 2.0, Secure Boot and RAM checks during setup.")
                        }

                        Toggle(isOn: $viewModel.bypassOnlineAccount) {
                            Text("Bypass Online Account")
                            Text("Lets setup finish with a local account instead of a Microsoft account.")
                        }
                    } else {
                        Toggle(isOn: $viewModel.showsUnusableVersions) {
                            Text("Show Versions This Mac Cannot Build")
                            Text("Lists releases that need a newer macOS, or predate Apple Silicon.")
                        }

                        Toggle(isOn: $viewModel.removesPreparedInstaller) {
                            Text("Remove the Installer Afterwards")
                            Text("Deletes the installer this run leaves in /Applications.")
                        }
                    }
                }
            }
            .formStyle(.grouped)
            // The window is sized to show the whole form, so its scroll view has
            // nothing to reveal. Left enabled it reports one point more content
            // than it was given and leaves a scroll bar sitting there.
            .scrollDisabled(true)
            // Nothing here may change mid-run: the drive is already being erased.
            .disabled(viewModel.processState.isProcessing)

            actionBar
        }
        .frame(maxWidth: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
        // Dropping anywhere in the window beats aiming at a small zone.
        .onDrop(of: [.fileURL], isTargeted: dropTarget, perform: handleDrop)
        .overlay(dropHighlight)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                modePicker
            }
        }
        .task { await viewModel.scanDrives() }
        .task(id: viewModel.mediaKind) {
            guard viewModel.mediaKind == .macOS else { return }
            await viewModel.loadMacOSVersions()
        }
    }

    // Which kind of media a run produces is the one choice the whole page hangs
    // off, so it sits in the toolbar rather than taking a row of the form.
    private var modePicker: some View {
        Picker("Media", selection: mediaKind) {
            ForEach(MediaKind.allCases) { kind in
                Text(kind.name).tag(kind)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .disabled(viewModel.processState.isProcessing)
    }

    private var mediaKind: Binding<MediaKind> {
        Binding(
            get: { viewModel.mediaKind },
            set: { viewModel.select($0) }
        )
    }

    @ViewBuilder
    private var sourceRows: some View {
        switch viewModel.mediaKind {
        case .windows:
            ISOListView(
                isoFiles: viewModel.isoFiles,
                baseID: viewModel.plan?.base.id,
                isAnalyzing: viewModel.isAnalyzing,
                onAdd: viewModel.selectISOs,
                onRemove: viewModel.removeISO
            )
            // The list draws its own border, so the row must not draw a second
            // one around it.
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        case .macOS:
            MacOSVersionPicker(
                versions: visibleVersions,
                selection: $viewModel.selectedVersion,
                isLoading: viewModel.isLoadingVersions
            )
        }
    }

    private var sourceHeader: some View {
        HStack {
            Text(viewModel.mediaKind == .windows ? "Windows ISOs" : "macOS Version")

            Spacer()

            // The ISO list carries its own add and remove buttons; the version
            // menu has nowhere to put them, so they live here.
            if viewModel.mediaKind == .macOS {
                macOSSourceMenu
            }
        }
    }

    private var macOSSourceMenu: some View {
        Menu {
            Button("Choose an Installer…", action: viewModel.selectInstallers)

            // Only what the user added can be taken back out; the rest is what
            // Apple publishes.
            if let selected = viewModel.selectedVersion, viewModel.isRemovable(selected) {
                Button("Remove \(selected.title) from the List") {
                    viewModel.removeInstaller(selected)
                }
            }

            Divider()

            Button("Reload from Apple") {
                Task { await viewModel.loadMacOSVersions(refresh: true) }
            }
            .disabled(viewModel.isLoadingVersions)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Add, remove or reload macOS versions")
    }

    // A version already picked stays listed even once the filter is put back on,
    // so the selection cannot disappear out from under the run button.
    private var visibleVersions: [MacOSInstaller] {
        guard !viewModel.showsUnusableVersions else { return viewModel.macOSVersions }

        return viewModel.macOSVersions.filter {
            MacOSMediaPlan.refusal(for: $0) == nil || $0.id == viewModel.selectedVersion?.id
        }
    }

    @ViewBuilder
    private var sourceFooter: some View {
        switch viewModel.mediaKind {
        case .windows: Text(windowsSummary)
        case .macOS: macOSFooter
        }
    }

    // What the drive is about to be asked to hold, which the run only reports
    // after the erase has been confirmed.
    private var windowsSummary: String {
        guard !viewModel.isoFiles.isEmpty else {
            return "Add more than one ISO to put several Windows versions on the same drive."
        }

        let isos = viewModel.isoFiles.count == 1 ? "1 ISO" : "\(viewModel.isoFiles.count) ISOs"
        let editions = viewModel.isoFiles.reduce(0) { $0 + $1.images.count }

        var parts = [isos]
        if editions > 0 {
            parts.append(editions == 1 ? "1 edition" : "\(editions) editions")
        }
        if let plan = viewModel.plan {
            parts.append("needs about \(plan.estimatedDriveBytes.formattedSize)")
        }

        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var macOSFooter: some View {
        // A version this Mac cannot build is picked from the menu like any
        // other, so this is where it says why the run is not offered.
        if let selected = viewModel.selectedVersion,
           let refusal = MacOSMediaPlan.refusal(for: selected) {
            Label(refusal.errorDescription ?? "", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        } else if viewModel.isLoadingVersions {
            Text("Asking Apple which versions are available…")
        } else if let plan = viewModel.macOSPlan {
            Text(macOSSummary(for: plan))
        } else {
            Text("Apple's catalog is not filtered by this Mac, so it lists older and newer releases alike.")
        }
    }

    // An installer the user already has costs no download, so the size that
    // matters differs with where the version comes from.
    private func macOSSummary(for plan: MacOSMediaPlan) -> String {
        let drive = "needs about \(plan.estimatedDriveBytes.formattedSize) on the drive"

        switch plan.installer.origin {
        case .catalog, .softwareUpdate:
            return "Downloads \(plan.installer.sizeBytes.formattedSize) from Apple · \(drive)"
        case .application, .package:
            return "Ready to write · \(drive)"
        }
    }

    private var destinationHeader: some View {
        HStack {
            Text("Destination")

            Spacer()

            Button {
                refreshRotation += 360
                Task { await viewModel.scanDrives() }
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .rotationEffect(.degrees(refreshRotation))
                    .animation(.easeInOut(duration: 0.5), value: refreshRotation)
            }
            .buttonStyle(.borderless)
            .disabled(viewModel.isScanning)
            .help("Rescan for USB drives")
        }
    }

    @ViewBuilder
    private var destinationFooter: some View {
        if viewModel.selectedDrive != nil {
            Label(
                "Everything on this drive will be erased.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .foregroundStyle(.orange)
        } else {
            Text("Plug in a USB drive, then refresh.")
        }
    }

    private var actionBar: some View {
        VStack(spacing: 10) {
            primaryButton

            // The rounded fill draws a visible stub even at zero, so it is
            // tinted away until there is real progress to show.
            ProgressView(value: viewModel.processState.progress, total: 100)
                .tint(viewModel.processState.progress > 0 ? Color.accentColor : Color.clear)

            HStack(alignment: .top, spacing: 8) {
                Text(statusMessage)
                    .foregroundStyle(statusTint)
                    .textSelection(.enabled)
                    // Two lines are always reserved, so a long message never
                    // changes the height of the window around it.
                    .lineLimit(2, reservesSpace: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text("\(Int(viewModel.processState.progress))%")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.bar)
    }

    @ViewBuilder
    private var primaryButton: some View {
        if viewModel.processState.isProcessing {
            let isStopping = viewModel.processState.stage == .aborting

            Button(role: .destructive) {
                viewModel.abortProcess()
            } label: {
                Text(isStopping ? "Stopping…" : "Stop")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            // Nothing is running to be stopped while the authorization prompt is
            // up; dismissing that prompt is what ends the run.
            .disabled(!viewModel.processState.isCancellable)
        } else {
            Button {
                if viewModel.confirmErase() {
                    viewModel.createBootableUSB()
                }
            } label: {
                Text(viewModel.mediaKind == .windows ? "Create Bootable Drive" : "Create macOS Installer")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!viewModel.canStart)
        }
    }

    // A bad drop or a failed scan is about to be corrected here, so it takes the
    // status line over whatever the last run left behind.
    private var statusMessage: String {
        if let inputError = viewModel.inputError { return inputError }

        let stage = viewModel.processState.stage.description
        let file = viewModel.processState.currentFile

        return file.isEmpty ? stage : "\(stage) · \(file)"
    }

    private var statusTint: Color {
        if viewModel.inputError != nil { return .red }

        switch viewModel.processState.stage {
        case .error: return .red
        case .done: return .green
        default: return .secondary
        }
    }

    private var acceptsDrop: Bool {
        !viewModel.processState.isProcessing
    }

    // A run in flight must not light up as a drop target it would then refuse.
    private var dropTarget: Binding<Bool> {
        Binding(
            get: { isDropTargeted },
            set: { isDropTargeted = $0 && acceptsDrop }
        )
    }

    @ViewBuilder
    private var dropHighlight: some View {
        if isDropTargeted {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.accentColor, lineWidth: 2)
                .background(Color.accentColor.opacity(0.08))
                .allowsHitTesting(false)
                .padding(4)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard acceptsDrop else { return false }

        // A drop can carry several files and each provider answers on its own
        // thread, so the URLs are gathered before the view model sees any of
        // them: one batch means one analysis pass and one error message.
        let dropped = DroppedURLs()
        let providersRemaining = DispatchGroup()

        for provider in providers {
            providersRemaining.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { data, _ in
                defer { providersRemaining.leave() }

                guard let data = data as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else {
                    return
                }

                dropped.append(url)
            }
        }

        // The type is only known here, so a drop the mode cannot use is reported
        // by the view model rather than dropped silently.
        providersRemaining.notify(queue: .main) {
            switch viewModel.mediaKind {
            case .windows: viewModel.addISOs(dropped.urls)
            case .macOS: viewModel.addInstallers(dropped.urls)
            }
        }

        return true
    }
}

// Drop callbacks answer on whichever thread the provider chooses, and the batch
// is read back on the main queue once they all have.
private final class DroppedURLs: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [URL] = []

    func append(_ url: URL) {
        lock.lock()
        defer { lock.unlock() }
        collected.append(url)
    }

    var urls: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return collected
    }
}

#Preview {
    ContentView()
        .frame(width: WindowLayout.width)
}
