import SwiftUI

/// Main content view
struct ContentView: View {
    @StateObject private var viewModel = CrossBootViewModel()
    @State private var rotation: Double = 0

    var body: some View {
        VStack(spacing: 16) {
            // ISO Drop Zone
            ISODropZoneView(
                isoFile: viewModel.isoFile,
                onSelect: { viewModel.selectISO() },
                onDrop: { urls in viewModel.handleISODrop(urls) }
            )
            .disabled(viewModel.processState.isProcessing)

            // Destination Disk Section
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Destination Disk")
                        .font(.headline)

                    Spacer()

                    Button {
                        rotation += 360
                        Task { await viewModel.scanDrives() }
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .rotationEffect(.degrees(rotation))
                            .animation(.easeInOut(duration: 0.5), value: rotation)
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.processState.isProcessing)
                }

                DriveSelectorView(
                    drives: viewModel.drives,
                    selectedDrive: $viewModel.selectedDrive
                )
                .disabled(viewModel.processState.isProcessing)
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)

            // Advanced Options
            VStack(alignment: .leading, spacing: 4) {
                Text("Advanced Options")
                    .font(.headline)

                Toggle("Bypass Windows 11 Requirements", isOn: $viewModel.bypassRequirements)
                    .disabled(viewModel.processState.isProcessing)

                Toggle("Bypass Online Account", isOn: $viewModel.bypassOnlineAccount)
                    .disabled(viewModel.processState.isProcessing)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Create/Abort Button
            if viewModel.processState.isProcessing {
                NativeButton(
                    title: "Abort",
                    isEnabled: viewModel.processState.stage != .aborting,
                    isSecondary: true,
                    action: { viewModel.abortProcess() }
                )
            } else {
                NativeButton(
                    title: "Create Bootable Drive",
                    isEnabled: viewModel.canStart,
                    action: {
                        if viewModel.confirmErase() {
                            viewModel.createBootableUSB()
                        }
                    }
                )
            }

            // Progress Section
            ProgressSection(state: viewModel.processState)
        }
        .padding(24)
        .onAppear {
            Task { await viewModel.scanDrives() }
        }
    }
}

#Preview {
    ContentView()
}
