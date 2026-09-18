import SwiftUI

@main
struct ReceiverApp: App {
    @StateObject private var server = ServerManager()

    init() { FontLoader.loadBundledFonts() }

    var body: some Scene {
        WindowGroup("Turbo Receiver") {
            RootView()
                .environmentObject(server)
                .frame(minWidth: 760, minHeight: 540)
                .preferredColorScheme(.dark)
        }
    }
}
