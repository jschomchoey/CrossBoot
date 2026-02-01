import SwiftUI
import AppKit

@main
struct CrossBootApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(width: 600, height: 500)
        }
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Configure all windows to be non-resizable
        if let window = NSApplication.shared.windows.first {
            configureWindow(window)
        }
        
        // Observe new windows
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { notification in
            if let window = notification.object as? NSWindow {
                self.configureWindow(window)
            }
        }
    }
    
    private func configureWindow(_ window: NSWindow) {
        window.styleMask.remove(.resizable)
        window.styleMask.remove(.fullScreen)
        
        // Set fixed size
        window.setContentSize(NSSize(width: 600, height: 500))
        
        // Disable zoom button (maximize)
        window.standardWindowButton(.zoomButton)?.isEnabled = false
    }
}
