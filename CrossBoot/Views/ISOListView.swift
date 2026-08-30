import SwiftUI

/// The source list, rendered as Form rows.
///
/// The box holding the ISOs has a fixed height and scrolls internally, so adding
/// a fourth ISO cannot resize a window that is pinned to its content.
struct ISOListView: View {
    let isoFiles: [ISOFile]
    let isAnalyzing: Bool
    let onAdd: () -> Void
    let onRemove: (ISOFile) -> Void

    private static let visibleRows = 3
    private static let rowHeight: CGFloat = 38

    private var boxHeight: CGFloat {
        CGFloat(Self.visibleRows) * Self.rowHeight
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            box

            HStack(spacing: 8) {
                Button("Add ISO…", action: onAdd)

                if isAnalyzing {
                    ProgressView()
                        .controlSize(.small)
                    Text("Reading…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var box: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(NSColor.textBackgroundColor))

            if isoFiles.isEmpty {
                Text("Drag Windows ISO files here, or anywhere onto this window.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(isoFiles) { iso in
                            row(iso)

                            if iso.id != isoFiles.last?.id {
                                Divider()
                            }
                        }
                    }
                }
            }
        }
        .frame(height: boxHeight)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color(NSColor.separatorColor))
        )
    }

    private func row(_ iso: ISOFile) -> some View {
        HStack(spacing: 10) {
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

            Button {
                onRemove(iso)
            } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Remove \(iso.name)")
        }
        .padding(.horizontal, 10)
        .frame(height: Self.rowHeight)
    }

    private var summary: String {
        guard !isoFiles.isEmpty else { return "" }

        let editions = isoFiles.reduce(0) { $0 + $1.images.count }
        let isos = isoFiles.count == 1 ? "1 ISO" : "\(isoFiles.count) ISOs"

        guard editions > 0 else { return isos }
        return "\(isos) · \(editions) editions"
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
    Form {
        ISOListView(
            isoFiles: [
                previewISO("Win11_24H2_x64.iso", build: 26100, editions: 11),
                previewISO("Win10_22H2_x64.iso", build: 19045, editions: 9)
            ].compactMap { $0 },
            isAnalyzing: false,
            onAdd: {},
            onRemove: { _ in }
        )
    }
    .formStyle(.grouped)
    .frame(width: WindowLayout.width)
}

#Preview("Empty") {
    Form {
        ISOListView(isoFiles: [], isAnalyzing: true, onAdd: {}, onRemove: { _ in })
    }
    .formStyle(.grouped)
    .frame(width: WindowLayout.width)
}
