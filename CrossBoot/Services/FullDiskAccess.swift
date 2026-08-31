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
    // short of Full Disk Access opens it.
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

    // An app that has to be added to the list by hand has to be found first, and
    // a build that is not in /Applications is not somewhere anyone can guess.
    static func showApplication() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }
}
