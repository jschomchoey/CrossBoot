import Foundation
import AppKit

// Whether macOS lets this app reach the whole disk.
//
// createinstallmedia's last step - blessing the drive it has just written -
// creates a file on the mounted installer volume, and TCC refuses that without
// Full Disk Access. The step runs as a child of this app (see PrivilegedRunner),
// so it is this app's grant that decides whether the drive can be finished.
enum FullDiskAccess {
    // TCC's own database: nothing short of the grant opens it.
    private static let probe = "/Library/Application Support/com.apple.TCC/TCC.db"

    // The file is opened rather than asked about. `access()` is answered without
    // tccd hearing of it, and it is tccd hearing a refusal that puts the app
    // into the Full Disk Access list for the user to switch on - an app that has
    // never been refused anything is not listed there at all. Nothing is read.
    static var isGranted: Bool {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: probe)) else {
            return false
        }

        try? handle.close()
        return true
    }

    // Opened rather than described: the pane is several levels into System
    // Settings, and the app has to be switched on there by hand.
    static func openSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles"
        ) else {
            return
        }

        NSWorkspace.shared.open(url)
    }
}
