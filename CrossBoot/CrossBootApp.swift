import SwiftUI

// The window is one fixed width and as tall as the page inside it. Neither
// mode's page changes height with what is on screen, and the two modes hold
// different controls, so switching mode resizes the window the way a
// preferences window resizes between its tabs.
enum WindowLayout {
    static let width: CGFloat = 460
    // Whatever the pages ask for, they have to fit a display 900pt tall with a
    // menu bar over it.
    static let maximumHeight: CGFloat = 800
}

@main
struct CrossBootApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(width: WindowLayout.width)
        }
        // The content sizes itself, so this pins the window to it: no resizing,
        // no zoom, no full screen, and the frame macOS restores from a previous
        // launch gets clamped back instead of winning.
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}
