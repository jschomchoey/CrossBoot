import SwiftUI

/// Main content view for CrossBoot app
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
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Destination Disk")
                        .font(.headline)
                    
                    Spacer()
                    
                    Button {
                        rotation += 360

                        Task {
                               await viewModel.scanDrives()
                        }
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
                    isDestructive: true,
                    action: {
                        viewModel.abortProcess()
                    }
                )
                .frame(height: 32)
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
                .frame(height: 32)
            }
            
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

// MARK: - Native macOS Button (macOS 11 compatible)

struct NativeButton: NSViewRepresentable {
    var title: String
    var isEnabled: Bool
    var isDestructive: Bool = false
    var action: () -> Void
    
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton()
        button.title = title
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.target = context.coordinator
        button.action = #selector(Coordinator.buttonClicked)
        
        if !isDestructive {
            button.keyEquivalent = "\r" // Enter key only for primary action
        }
        
        return button
    }
    
    func updateNSView(_ nsView: NSButton, context: Context) {
        nsView.title = title
        nsView.isEnabled = isEnabled
        
        // Apply destructive styling
        if isDestructive {
            nsView.contentTintColor = .systemRed
            nsView.keyEquivalent = ""
        } else {
            nsView.contentTintColor = nil
            nsView.keyEquivalent = "\r"
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }
    
    class Coordinator: NSObject {
        var action: () -> Void
        
        init(action: @escaping () -> Void) {
            self.action = action
        }
        
        @objc func buttonClicked() {
            action()
        }
    }
}
// MARK: - Native macOS Progress Indicator

struct NativeProgressBar: NSViewRepresentable {
    var value: Double
    var maxValue: Double
    
    func makeNSView(context: Context) -> NSProgressIndicator {
        let indicator = NSProgressIndicator()
        indicator.style = .bar
        indicator.isIndeterminate = false
        indicator.minValue = 0
        indicator.maxValue = maxValue
        indicator.controlSize = .regular
        return indicator
    }
    
    func updateNSView(_ nsView: NSProgressIndicator, context: Context) {
        nsView.doubleValue = value
        nsView.maxValue = maxValue
    }
}

// MARK: - Progress Section

struct ProgressSection: View {
    let state: ProcessState
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            NativeProgressBar(value: state.progress, maxValue: 100)
                .frame(height: 20)
            
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
