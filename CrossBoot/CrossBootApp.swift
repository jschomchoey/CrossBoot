import SwiftUI

// The window is one fixed size. The page has a single layout whose height does
// not vary with what is on screen, so there is nothing to resize it to.
enum WindowLayout {
    static let width: CGFloat = 460
    static let height: CGFloat = 788
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
