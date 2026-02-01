import SwiftUI

@main
struct CrossBootApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 400, maxWidth: 600)
        }
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}
