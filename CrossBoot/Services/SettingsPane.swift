import Foundation
import AppKit

// The System Settings pane a refused run sends the user to.
enum SettingsPane {
    // Opened rather than described: the pane is several levels in, and the app
    // has to be switched on there by hand.
    static func openFullDiskAccess() {
        open("com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles")
    }

    private static func open(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:\(pane)") else { return }

        NSWorkspace.shared.open(url)
    }
}
