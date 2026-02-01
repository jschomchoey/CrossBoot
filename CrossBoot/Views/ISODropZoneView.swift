import SwiftUI
import UniformTypeIdentifiers

/// Drop zone
struct ISODropZoneView: View {
    let isoFile: ISOFile?
    let onSelect: () -> Void
    let onDrop: ([URL]) -> Void
    
    @State private var isTargeted = false
    
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(backgroundColor)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(
                            isTargeted ? Color.accentColor : Color.gray.opacity(0.3),
                            style: StrokeStyle(lineWidth: 2, dash: isoFile == nil ? [8] : [])
                        )
                )
            
            if let iso = isoFile {
                // ISO Selected State
                HStack(spacing: 12) {
                    Image(systemName: "opticaldisc")
                        .font(.system(size: 40))
                        .foregroundColor(.blue)
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text(iso.name)
                            .font(.headline)
                            .lineLimit(1)
                        
                        Text(iso.sizeFormatted)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    Button(action: onSelect) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.plain)
                }
                .padding()
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "plus")
                        .font(.system(size: 28))
                        .foregroundColor(.secondary)
                    
                    Text("Select an ISO file or drag it here")
                        .foregroundColor(.secondary)
                }
            }
        }
        .frame(height: 150)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers)
        }
    }
    
    private var backgroundColor: Color {
        if isTargeted {
            return Color.accentColor.opacity(0.1)
        } else if isoFile != nil {
            return Color(NSColor.controlBackgroundColor)
        } else {
            return Color.clear
        }
    }
    
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { data, error in
            guard let data = data as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else {
                return
            }
            
            DispatchQueue.main.async {
                if url.pathExtension.lowercased() == "iso" {
                    onDrop([url])
                }
            }
        }
        
        return true
    }
}

#Preview("Empty") {
    ISODropZoneView(
        isoFile: nil,
        onSelect: {},
        onDrop: { _ in }
    )
    .padding()
}

#Preview("With ISO") {
    ISODropZoneView(
        isoFile: try? ISOFile(url: URL(fileURLWithPath: "/path/to/Windows11.iso")),
        onSelect: {},
        onDrop: { _ in }
    )
    .padding()
}
