import SwiftUI

@main
struct ReceiverApp: App {
    @StateObject private var server = ServerManager()

    init() {
        // Before anything reads preferences (the server's feeds, the onboarding flag).
        PreferencesMigration.adoptPreviousDomain()
        FontLoader.loadBundledFonts()
    }

    var body: some Scene {
        WindowGroup("Turbo Receiver") {
            RootView()
                .environmentObject(server)
                .frame(minWidth: 760, minHeight: 540)
                .preferredColorScheme(.dark)
        }
    }
}
