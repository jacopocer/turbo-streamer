import Foundation

/// The Receiver's bundle identifier changed once. macOS keeps an app's preferences
/// under its identifier — the feeds above all, and a feed's key is the publish secret
/// every paired streamer is configured with — so a copy launched under the new
/// identifier would start with no feeds. On first launch it adopts the previous
/// domain's values. The old identifier is found, not named: any other
/// "<…>.turboreceiver" preferences domain on this Mac.
enum PreferencesMigration {
    static let doneKey = "TurboReceiver.preferencesAdopted"

    static func adoptPreviousDomain(into defaults: UserDefaults = .standard,
                                    currentID: String = Bundle.main.bundleIdentifier ?? "") {
        guard !currentID.isEmpty, defaults.object(forKey: doneKey) == nil else { return }
        defer { defaults.set(true, forKey: doneKey) }
        let prefs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Preferences")
        let previous = ((try? FileManager.default.contentsOfDirectory(atPath: prefs.path)) ?? [])
            .filter { $0.hasSuffix(".turboreceiver.plist") }
            .map { String($0.dropLast(".plist".count)) }
            .filter { $0 != currentID }
        for domain in previous {
            guard let values = defaults.persistentDomain(forName: domain) else { continue }
            for (key, value) in values where defaults.object(forKey: key) == nil {   // never overwrite
                defaults.set(value, forKey: key)
            }
        }
    }
}
