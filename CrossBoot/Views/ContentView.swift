import SwiftUI

/// Main content view for CrossBoot app
struct ContentView: View {
    @StateObject private var viewModel = CrossBootViewModel()
    
    var body: some View {
        VStack(spacing: 16) {
            // ISO Drop Zone
            ISODropZoneView(
                isoFile: viewModel.isoFile,
                onSelect: { viewModel.selectISO() },
                onDrop: { urls in viewModel.handleISODrop(urls) }
            )
            
            // Destination Disk Section
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Destination Disk")
                        .font(.headline)
                    
                    Spacer()
                    
                    Button(action: {
                        Task { await viewModel.scanDrives() }
                    }) {
                        Image(systemName: "arrow.clockwise")
                            .rotationEffect(.degrees(viewModel.isScanning ? 360 : 0))
                            .animation(viewModel.isScanning ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default, value: viewModel.isScanning)
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.processState.isProcessing)
                }
                
                DriveSelectorView(
                    drives: viewModel.drives,
                    selectedDrive: $viewModel.selectedDrive
                )
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
            
            // Advanced Options
            VStack(alignment: .leading, spacing: 8) {
                Text("Advanced Options")
                    .font(.headline)
                
                Toggle("Bypass Windows 11 Requirements", isOn: $viewModel.bypassRequirements)
                    .disabled(viewModel.processState.isProcessing)
                
                Toggle("Bypass Online Account", isOn: $viewModel.bypassOnlineAccount)
                    .disabled(viewModel.processState.isProcessing)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            
            // Create Button
            Button(action: {
                if viewModel.confirmErase() {
                    Task { await viewModel.createBootableUSB() }
                }
            }) {
                HStack {
                    // Image(systemName: "externaldrive.badge.plus")
                    Text("Create Bootable Drive")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!viewModel.canStart)
            
            // Progress Section
            ProgressSection(state: viewModel.processState)
        }
        .padding(20)
        .frame(minWidth: 400, maxWidth: 500)
        .onAppear {
            Task { await viewModel.scanDrives() }
        }
    }
}

// MARK: - Primary Button Style (macOS 11 compatible)

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(.white)
            .background(Color.accentColor.opacity(configuration.isPressed ? 0.8 : 1.0))
            .cornerRadius(8)
    }
}

// MARK: - Progress Section

struct ProgressSection: View {
    let state: ProcessState
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProgressView(value: state.progress, total: 100)
                .progressViewStyle(.linear)
            
            HStack {
                Text("Status: \(state.stage.description)")
                    .foregroundColor(statusColor)
                    .lineLimit(1)
                
                Spacer()
                
                Text("\(Int(state.progress))%")
                    .font(.system(.caption, design: .monospaced))
            }
            .font(.caption)
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }
    
    private var statusColor: Color {
        switch state.stage {
        case .error: return .red
        case .done: return .green
        default: return .secondary
        }
    }
}

#Preview {
    ContentView()
}
