import SwiftUI
import UniformTypeIdentifiers

/// The whole app on one page. Everything stays put while a run is in flight:
/// the form locks, the button turns into Stop, and progress reports at the
/// bottom, so the window is laid out once and never resized.
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
                    ISOListView(
                        isoFiles: viewModel.isoFiles,
                        isAnalyzing: viewModel.isAnalyzing,
                        onAdd: viewModel.selectISOs,
                        onRemove: viewModel.removeISO
                    )
                } header: {
                    Text("Windows ISOs")
                } footer: {
                    Text("Add more than one ISO to put several Windows versions on the same drive.")
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
                    Toggle(isOn: $viewModel.bypassRequirements) {
                        Text("Bypass Windows 11 Requirements")
                        Text("Skips the TPM 2.0, Secure Boot and RAM checks during setup.")
                    }

                    Toggle(isOn: $viewModel.bypassOnlineAccount) {
                        Text("Bypass Online Account")
                        Text("Lets setup finish with a local account instead of a Microsoft account.")
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
        .task { await viewModel.scanDrives() }
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
            .disabled(isStopping)
        } else {
            Button {
                if viewModel.confirmErase() {
                    viewModel.createBootableUSB()
                }
            } label: {
                Text("Create Bootable Drive")
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

        // The type is only known here, so a non-ISO drop is reported by the
        // view model rather than dropped silently.
        providersRemaining.notify(queue: .main) {
            viewModel.addISOs(dropped.urls)
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
