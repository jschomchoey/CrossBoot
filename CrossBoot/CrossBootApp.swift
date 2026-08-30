import SwiftUI
import AppKit

// The window is fixed size; the SwiftUI frame and the AppKit window share these.
enum WindowLayout {
    static let width: CGFloat = 450
    static let height: CGFloat = 415
}

@main
struct CrossBootApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(width: WindowLayout.width, height: WindowLayout.height)
        }
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let window = Self.mainWindow(among: NSApplication.shared.windows) {
            configure(window)
            return
        }

        // SwiftUI may not have built the window yet. Take the first real window
        // that appears, then stop listening - re-applying this on every focus
        // change would fight anything that resizes the window later.
        windowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let window = notification.object as? NSWindow,
                  Self.mainWindow(among: [window]) != nil else { return }

            self.configure(window)
            self.stopObservingWindows()
        }
    }

    deinit {
        stopObservingWindows()
    }

    // Identified by capability rather than title, which changes with localization.
    private static func mainWindow(among windows: [NSWindow]) -> NSWindow? {
        windows.first { $0.canBecomeMain && !($0 is NSPanel) }
    }

    private func stopObservingWindows() {
        guard let observer = windowObserver else { return }
        NotificationCenter.default.removeObserver(observer)
        windowObserver = nil
    }

    private func configure(_ window: NSWindow) {
        window.styleMask.remove(.resizable)
        window.styleMask.remove(.fullScreen)
        window.setContentSize(NSSize(width: WindowLayout.width, height: WindowLayout.height))
        window.standardWindowButton(.zoomButton)?.isEnabled = false
    }
}
