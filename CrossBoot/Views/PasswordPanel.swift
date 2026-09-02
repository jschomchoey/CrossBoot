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
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")

        let field = NSSecureTextField()
        field.placeholderString = "Password"
        field.setFrameSize(NSSize(width: textWidth(of: alert), height: field.fittingSize.height))
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        let answer = alert.runModal()
        let password = field.stringValue
        field.stringValue = ""

        guard answer == .alertFirstButtonReturn, !password.isEmpty else { return nil }

        return password
    }

    // An alert lays its accessory out beside its text rather than inside it, and
    // it widens itself to fit whatever it is given. A field wider than the text
    // therefore widened the alert while the text went on wrapping where it did,
    // which left the field standing out past every line above it. Asking the
    // alert what its text measures - rather than assuming a width - keeps the
    // two edges together whatever the alert is told to say.
    private static func textWidth(of alert: NSAlert) -> CGFloat {
        alert.layout()

        guard let content = alert.window.contentView else { return standardTextWidth }

        var widest: CGFloat = 0
        var remaining = [content]

        while let view = remaining.popLast() {
            if view is NSTextField { widest = max(widest, view.frame.width) }
            remaining.append(contentsOf: view.subviews)
        }

        return widest > 0 ? widest : standardTextWidth
    }

    // What the text of an alert this app's size measures today, used only if the
    // alert is ever laid out with no label to measure.
    private static let standardTextWidth: CGFloat = 220
}
