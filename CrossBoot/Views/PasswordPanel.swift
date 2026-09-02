import AppKit

// Asks for the administrator password the privileged step needs.
//
// The step runs under sudo so that it stays a child of this app and inherits the
// Full Disk Access createinstallmedia needs for its last step; see
// PrivilegedRunner for why the usual authorization prompt cannot be used.
//
// Nothing here keeps the value: it is read once, the field it came from is
// cleared, and the caller hands it straight to sudo's standard input.
@MainActor
enum PasswordPanel {
    static func ask(toErase drive: Drive) -> String? {
        let alert = NSAlert()
        alert.messageText = "CrossBoot needs your administrator password"
        alert.informativeText = """
        Writing a macOS installer runs Apple's createinstallmedia as root, which \
        erases "\(drive.name)".
        """
        alert.alertStyle = .informational

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Password"
        alert.accessoryView = field

        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field

        let answer = alert.runModal()
        let password = field.stringValue
        field.stringValue = ""

        guard answer == .alertFirstButtonReturn, !password.isEmpty else { return nil }

        return password
    }
}
