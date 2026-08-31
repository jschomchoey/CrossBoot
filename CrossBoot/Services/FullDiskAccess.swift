import Foundation
import AppKit

// Whether macOS lets this app reach the whole disk.
//
// createinstallmedia's last step - blessing the drive it has just written -
// creates a file on the mounted installer volume, and TCC refuses that with
// EPERM unless the app that started it holds Full Disk Access. Running as root
// does not help: the decision is made about the app responsible for the process,
// not about the user it runs as.
enum FullDiskAccess {
    // TCC's own database is what the grant is normally probed with: nothing
    // short of Full Disk Access opens it, and it never has to be read.
    private static let probe = "/Library/Application Support/com.apple.TCC/TCC.db"

    static var isGranted: Bool {
        FileManager.default.isReadableFile(atPath: probe)
    }

    // Opened rather than described: the pane is several levels into System
    // Settings, and the app has to be added there by hand.
    static func openSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles"
        ) else {
            return
        }

        NSWorkspace.shared.open(url)
    }
}
