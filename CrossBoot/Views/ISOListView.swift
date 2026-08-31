import SwiftUI

/// The source list, built the way macOS builds an editable list in Settings:
/// one bordered container with a plus/minus bar attached to its bottom edge.
///
/// The container has a fixed height and scrolls internally, so adding a fourth
/// ISO cannot resize a window that is pinned to its content.
struct ISOListView: View {
    let isoFiles: [ISOFile]
    // The ISO that supplies the boot files, which the ordering alone does not say.
    let baseID: ISOFile.ID?
    let isAnalyzing: Bool
    let onAdd: () -> Void
    let onRemove: (ISOFile) -> Void

    @State private var selection: ISOFile.ID?

    private static let visibleRows = 3
    private static let rowHeight: CGFloat = 42
    private static let barHeight: CGFloat = 24

    var body: some View {
        List(selection: $selection) {
            ForEach(isoFiles) { iso in
                row(iso)
                    .frame(height: Self.rowHeight)
            }
        }
        // The section's card is the container. A bordered list would draw a
        // second frame inside it, which is the nesting this replaced.
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .overlay { if isoFiles.isEmpty { emptyLabel } }
        .safeAreaInset(edge: .bottom, spacing: 0) { bar }
        .frame(height: CGFloat(Self.visibleRows) * Self.rowHeight + Self.barHeight)
    }

    private var emptyLabel: some View {
        Text("Drag Windows ISO files here")
            .font(.callout)
            .foregroundStyle(.secondary)
            .allowsHitTesting(false)
    }

    private func row(_ iso: ISOFile) -> some View {
        HStack(spacing: 8) {
            // An ISO with no install image cannot be combined with others, and
            // the list is where that has to be visible.
            Image(systemName: iso.images.isEmpty ? "exclamationmark.triangle.fill" : "opticaldisc.fill")
                .foregroundStyle(iso.images.isEmpty ? Color.orange : Color.accentColor)

            VStack(alignment: .leading, spacing: 1) {
                Text(iso.name)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(iso.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            if iso.id == baseID {
                Text("base")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.quaternary))
                    .help("Supplies the boot files and the setup that installs every edition")
            }
        }
    }

    private var bar: some View {
        VStack(spacing: 0) {
            Divider()

            HStack(spacing: 0) {
                Button(action: onAdd) {
                    Image(systemName: "plus")
                        .frame(width: 24)
                }
                .help("Add an ISO")

                Divider()
                    .frame(height: 12)

                Button {
                    guard let selected = isoFiles.first(where: { $0.id == selection }) else { return }
                    selection = nil
                    onRemove(selected)
                } label: {
                    Image(systemName: "minus")
                        .frame(width: 24)
                }
                .disabled(selection == nil)
                .help("Remove the selected ISO")

                if isAnalyzing {
                    Divider()
                        .frame(height: 12)

                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                        .padding(.horizontal, 6)

                    Text("Reading…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .buttonStyle(.borderless)
            .frame(height: Self.barHeight)
            .background(.quaternary.opacity(0.4))
        }
    }
}

private func previewISO(_ name: String, build: Int, editions: Int) -> ISOFile? {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
    try? Data().write(to: url)

    return try? ISOFile(
        url: url,
        installImage: InstallImage(relativePath: "sources/install.wim", sizeBytes: 5_000_000_000),
        images: (1...editions).map {
            WindowsImage(index: $0, name: "Edition \($0)", architecture: .x64, build: build, totalBytes: 0)
        },
        hasBootLoader: true
    )
}

#Preview("With ISOs") {
    let isos = [
        previewISO("Win11_24H2_x64.iso", build: 26100, editions: 11),
        previewISO("Win10_22H2_x64.iso", build: 19045, editions: 9)
    ].compactMap { $0 }

    return Form {
        Section {
            ISOListView(
                isoFiles: isos,
                baseID: isos.first?.id,
                isAnalyzing: false,
                onAdd: {},
                onRemove: { _ in }
            )
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        } header: {
            Text("Windows ISOs")
        }
    }
    .formStyle(.grouped)
    .frame(width: WindowLayout.width)
}
