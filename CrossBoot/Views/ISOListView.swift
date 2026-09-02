import SwiftUI

/// The source list, built the way macOS builds an editable list in Settings:
/// one bordered well with a plus/minus bar attached to its bottom edge.
///
/// The well has a fixed height and scrolls internally, so adding a fourth ISO
/// cannot resize a window that is pinned to its content.
///
/// The rows are drawn rather than listed, and the well is drawn here rather
/// than left to the section around it. A `List` inside a `Form` is laid out as
/// inline content: it fills the section's card, but AppKit reports its scroll
/// view with no scroller and no elasticity, so a fourth ISO was drawn where
/// nothing could reach it. Anything else in that row scrolls, but is inset
/// inside the card - `listRowInsets` does not reach it - which left the bar
/// floating short of the card's edges. Drawing the well settles both.
struct ISOListView: View {
    let isoFiles: [ISOFile]
    // The ISO that supplies the boot files, which the ordering alone does not say.
    let baseID: ISOFile.ID?
    let isAnalyzing: Bool
    let onAdd: () -> Void
    let onRemove: (ISOFile) -> Void

    @State private var selection: ISOFile.ID?
    @Environment(\.controlActiveState) private var activeState

    private static let visibleRows = 3
    private static let rowHeight: CGFloat = 42
    private static let barHeight: CGFloat = 24
    private static let cornerRadius: CGFloat = 6

    private static var contentHeight: CGFloat { CGFloat(visibleRows) * rowHeight }

    var body: some View {
        // The bar stands beside the rows rather than over them: nothing scrolls
        // underneath it, so it needs no fill of its own to hide anything.
        VStack(spacing: 0) {
            ScrollView {
                if isoFiles.isEmpty {
                    emptyLabel
                } else {
                    VStack(spacing: 0) {
                        ForEach(isoFiles) { iso in
                            row(iso)
                        }
                    }
                }
            }

            bar
        }
        .frame(height: Self.contentHeight + Self.barHeight)
        // No fill: the well takes the colour of the card it sits in, which
        // macOS tints with the desktop behind the window. A fixed colour stayed
        // grey while everything around it turned with the wallpaper.
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: Self.cornerRadius)
                .strokeBorder(Color(nsColor: .separatorColor))
        }
    }

    // Said in the rows' own space rather than over them, so it sits where the
    // first ISO will and not behind the bar.
    private var emptyLabel: some View {
        Text("Drag Windows ISO files here")
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: Self.contentHeight)
            .allowsHitTesting(false)
    }

    private func row(_ iso: ISOFile) -> some View {
        let isSelected = iso.id == selection
        // A selected row is filled with the accent colour only while this
        // window is the one being used, which is what every list on the system
        // does. Everything in the row is then drawn in the colour AppKit picks
        // to sit on that fill - white against blue, black against yellow - so
        // the row stays readable whichever accent colour is set.
        let emphasized = isSelected && activeState != .inactive

        return HStack(spacing: 8) {
            // An ISO with no install image cannot be combined with others, and
            // the list is where that has to be visible.
            Image(systemName: iso.images.isEmpty ? "exclamationmark.triangle.fill" : "opticaldisc.fill")
                .foregroundStyle(emphasized ? Self.selectedText : (iso.images.isEmpty ? Color.orange : Color.accentColor))

            VStack(alignment: .leading, spacing: 1) {
                Text(iso.name)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(iso.summary)
                    .font(.caption)
                    .foregroundStyle(Self.secondaryTint(emphasized))
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            if iso.id == baseID {
                Text("base")
                    .font(.caption2)
                    .foregroundStyle(Self.secondaryTint(emphasized))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Self.badgeTint(emphasized)))
                    .help("Supplies the boot files and the setup that installs every edition")
            }
        }
        .foregroundStyle(emphasized ? Self.selectedText : Color.primary)
        .padding(.horizontal, 10)
        .frame(height: Self.rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selectionFill(isSelected, emphasized: emphasized))
        // The gaps between the name and the badge select the row too.
        .contentShape(Rectangle())
        .onTapGesture { selection = iso.id }
        // Drawn rows carry none of the meaning a list row carries by itself.
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    // What AppKit draws on top of an emphasized selection, whatever accent
    // colour the system is set to.
    private static let selectedText = Color(nsColor: .alternateSelectedControlTextColor)

    private static func secondaryTint(_ emphasized: Bool) -> AnyShapeStyle {
        emphasized ? AnyShapeStyle(selectedText.opacity(0.8)) : AnyShapeStyle(.secondary)
    }

    private static func badgeTint(_ emphasized: Bool) -> AnyShapeStyle {
        emphasized ? AnyShapeStyle(selectedText.opacity(0.25)) : AnyShapeStyle(.quaternary)
    }

    @ViewBuilder
    private func selectionFill(_ isSelected: Bool, emphasized: Bool) -> some View {
        if emphasized {
            Color(nsColor: .selectedContentBackgroundColor)
        } else if isSelected {
            Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
        } else {
            Color.clear
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
            .frame(maxHeight: .infinity)
        }
        // The divider counts towards the bar, so the rows above it are left
        // exactly the height the list says it shows.
        .frame(height: Self.barHeight)
        // A tint over the card rather than a colour of its own: it darkens in
        // the light appearance and lightens in the dark one, and it turns with
        // the window the way everything around it does.
        .background(.quaternary)
    }
}

private func previewISO(_ name: String, build: Int, editions: Int) -> ISOFile? {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
    try? Data().write(to: url)

    return try? ISOFile(
        url: url,
        installImage: InstallImage(relativePath: "sources/install.wim", sizeBytes: 5_000_000_000, compression: .lzx),
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
