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
                    isSecondary: true,
                    action: {
                        viewModel.abortProcess()
                    }
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

// MARK: - Custom Button

struct NativeButton: View {
    var title: String
    var isEnabled: Bool
    var isDestructive: Bool = false
    var isSecondary: Bool = false
    var action: () -> Void
    
    @State private var isHovered = false
    @State private var isPressed = false
    
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12))
                .foregroundColor(textColor)
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .background(backgroundGradient)
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(borderColor, lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { hovering in
            isHovered = hovering
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
    }
    
    private var backgroundGradient: LinearGradient {
        if !isEnabled {
            return LinearGradient(
                colors: [
                    Color(NSColor.controlBackgroundColor),
                    Color(NSColor.controlBackgroundColor).opacity(0.8)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        
        if isDestructive {
            let baseColor = Color(NSColor.systemRed)
            if isPressed {
                return LinearGradient(
                    colors: [baseColor.opacity(0.7), baseColor.opacity(0.8)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            } else if isHovered {
                return LinearGradient(
                    colors: [baseColor.opacity(0.95), baseColor],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            return LinearGradient(
                colors: [baseColor.opacity(0.9), baseColor],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        
        if isSecondary {
            let baseColor = Color(NSColor.controlBackgroundColor)
            if isPressed {
                return LinearGradient(
                    colors: [baseColor.opacity(0.6), baseColor.opacity(0.7)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            } else if isHovered {
                return LinearGradient(
                    colors: [baseColor.opacity(0.9), baseColor],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            return LinearGradient(
                colors: [baseColor.opacity(0.8), baseColor.opacity(0.9)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        
        let accentColor = Color(NSColor.controlAccentColor)
        if isPressed {
            return LinearGradient(
                colors: [accentColor.opacity(0.8), accentColor.opacity(0.8)],
                startPoint: .top,
                endPoint: .bottom
            )
        } else if isHovered {
            return LinearGradient(
                colors: [accentColor.opacity(0.8), accentColor.opacity(1.05).opacity(1.0)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        return LinearGradient(
            colors: [accentColor.opacity(0.8), accentColor],
            startPoint: .top,
            endPoint: .bottom
        )
    }
    
    private var textColor: Color {
        if !isEnabled {
            return Color(NSColor.disabledControlTextColor)
        }
        if isSecondary {
            return Color(NSColor.labelColor)
        }
        return .white
    }
    
    private var borderColor: Color {
        if !isEnabled {
            return Color(NSColor.separatorColor)
        }
        if isSecondary {
            return Color(NSColor.separatorColor)
        }
        return Color.clear
    }
}

// MARK: - Custom Progress Bar

struct CustomProgressBar: View {
    var value: Double
    var total: Double
    var height: CGFloat = 6
    
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // Track
                Capsule()
                    .fill(Color.secondary.opacity(0.15))
                    .frame(height: height)
                
                // Fill
                if value > 0 {
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: max(0, min(geometry.size.width * CGFloat(value / total), geometry.size.width)), height: height)
                        .animation(.linear(duration: 0.2), value: value)
                }
            }
        }
        .frame(height: height)
    }
}

// MARK: - Progress Section

struct ProgressSection: View {
    let state: ProcessState
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CustomProgressBar(value: state.progress, total: 100)
                .padding(.vertical, 4)
            
            HStack {
                Text("Status: \(state.stage.description)")
                    .foregroundColor(statusColor)
                    .lineLimit(1)
                
                Spacer()
                
                Text("\(Int(state.progress))%")
                    .foregroundColor(statusColor)
//                    .font(.system(.caption, ))
            }
//            .font(.caption)
        }
//        .padding()
//        .background(Color(NSColor.controlBackgroundColor))
//        .cornerRadius(8)
    }
    
    private var statusColor: Color {
        switch state.stage {
//        case .error: return .red
//        case .done: return .green
        default: return .secondary
        }
    }
}

#Preview {
    ContentView()
}
