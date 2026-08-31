import SwiftUI

/// The macOS source rows: a run writes exactly one release, so the choice is a
/// popup menu with the rows that describe what it picked - the shape the
/// Destination section below already uses.
///
/// The Windows side lists ISOs because a run combines several of them; here
/// there is nothing to add to or take out of, which is why the two sides do not
/// look alike.
struct MacOSVersionPicker: View {
    let versions: [MacOSInstaller]
    @Binding var selection: MacOSInstaller?
    let isLoading: Bool

    private var selectedID: Binding<MacOSInstaller.ID?> {
        Binding(
            get: { selection?.id },
            set: { id in selection = versions.first { $0.id == id } }
        )
    }

    // Grouped rather than stacked: each child reaches the enclosing Form section
    // as a row of its own.
    var body: some View {
        Group {
            Picker("Version", selection: selectedID) {
                // An empty menu still has to say why it is empty, and the tag
                // keeps the binding matching the nil selection behind it.
                if versions.isEmpty {
                    Text(isLoading ? "Looking for versions…" : "No versions found")
                        .tag(MacOSInstaller.ID?.none)
                }

                ForEach(versions) { version in
                    Text(menuTitle(for: version))
                        .tag(MacOSInstaller.ID?.some(version.id))
                }
            }
            .disabled(versions.isEmpty)

            LabeledContent("Build") {
                Text(selection?.build ?? "-")
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(selection == nil ? Color.secondary : Color.primary)
            }

            LabeledContent("Source") {
                Text(selection?.origin.name ?? "-")
                    .foregroundStyle(selection == nil ? Color.secondary : Color.primary)
            }
        }
    }

    // A version this Mac cannot build is only listed when the user asked for
    // those, and the menu is where that has to be visible - the row it would
    // otherwise be picked from silently.
    private func menuTitle(for version: MacOSInstaller) -> String {
        guard let refusal = MacOSMediaPlan.refusal(for: version) else { return version.title }

        return "\(version.title) — \(refusal.shortReason)"
    }
}

private func previewInstaller(_ name: String, _ version: String, _ build: String, size: Int64) -> MacOSInstaller {
    MacOSInstaller(
        name: name,
        version: MacOSVersion(version) ?? MacOSVersion([0]),
        build: build,
        sizeBytes: size,
        minimumHostVersion: nil,
        origin: .catalog(
            productID: build,
            packageURL: URL(fileURLWithPath: "/tmp/InstallAssistant.pkg")
        )
    )
}

#Preview("With Versions") {
    let versions = [
        previewInstaller("macOS Tahoe", "26.6.2", "25G83", size: 18_384_624_402),
        previewInstaller("macOS Sequoia", "15.7.9", "24G830", size: 15_655_958_320),
        previewInstaller("macOS Ventura", "13.7.8", "22H730", size: 12_205_110_942)
    ]

    return Form {
        Section {
            MacOSVersionPicker(
                versions: versions,
                selection: .constant(versions.first),
                isLoading: false
            )
        } header: {
            Text("macOS Version")
        }
    }
    .formStyle(.grouped)
    .frame(width: WindowLayout.width)
}

#Preview("Empty") {
    Form {
        Section {
            MacOSVersionPicker(versions: [], selection: .constant(nil), isLoading: true)
        } header: {
            Text("macOS Version")
        }
    }
    .formStyle(.grouped)
    .frame(width: WindowLayout.width)
}
