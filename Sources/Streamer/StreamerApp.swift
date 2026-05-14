import SwiftUI

@main
struct TurboStreamerApp: App {
    @StateObject private var manager = StreamManager()

    init() {
        FontLoader.loadBundledFonts()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(manager)
                .preferredColorScheme(.dark)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
