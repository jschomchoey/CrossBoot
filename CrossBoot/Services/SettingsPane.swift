import Foundation
import AppKit

// The two System Settings panes a refused run sends the user to.
//
// CrossBoot does not need Full Disk Access itself: the step that writes the
// drive runs in Terminal, and it is Terminal that macOS holds responsible for
// what that step touches. See PrivilegedRunner.
enum SettingsPane {
    // Opened rather than described: both panes are several levels in, and the
    // app has to be switched on there by hand.
    static func openFullDiskAccess() {
        open("com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles")
    }

    static func openAutomation() {
        open("com.apple.settings.PrivacySecurity.extension?Privacy_Automation")
    }

    private static func open(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:\(pane)") else { return }

        NSWorkspace.shared.open(url)
    }
}
