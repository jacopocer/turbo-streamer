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
        // Resizable so the green button (zoom / full screen) is enabled.
        .windowResizability(.contentMinSize)
        .defaultSize(width: 880, height: 860)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
