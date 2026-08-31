import SwiftUI

// The window is one fixed size. Neither mode's page changes height with what is
// on screen, so there is nothing to resize it to - this is the taller of the two
// pages, measured, and WindowSizingTests fails if either page outgrows it or
// falls far enough behind it to leave a band of empty window.
enum WindowLayout {
    static let width: CGFloat = 460
    static let height: CGFloat = 750
}

@main
struct CrossBootApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(width: WindowLayout.width, height: WindowLayout.height)
        }
        // The content has one fixed size, so this pins the window to it: no
        // resizing, no zoom, no full screen, and the frame macOS restores from a
        // previous launch gets clamped back instead of winning.
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}
