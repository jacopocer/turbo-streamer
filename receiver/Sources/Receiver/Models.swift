import Foundation

// MARK: - Ingest key

/// One ingest endpoint. `key` is both the MediaMTX path and the shared secret:
/// only paths listed in the generated config are accepted, so an unknown key is
/// refused at publish time.
struct IngestKey: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var key: String

    init(name: String, key: String = IngestKey.randomKey()) {
        self.name = name
        self.key = key
    }

    /// 24 chars of lowercase+digits — long enough to act as the publish secret.
    static func randomKey() -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<24).map { _ in alphabet.randomElement()! })
    }

    // Resilient decode: adding fields later must never wipe saved keys.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id   = (try? c.decode(UUID.self,   forKey: .id))   ?? UUID()
        name = (try? c.decode(String.self, forKey: .name)) ?? "Feed"
        key  = (try? c.decode(String.self, forKey: .key))  ?? IngestKey.randomKey()
    }
}

// MARK: - Live path state (polled from the MediaMTX API)

struct PathStatus: Equatable {
    var ready = false
    var tracks: [String] = []
    var readers = 0
    var bytesReceived = 0
    var sourceType: String?

    /// Bitrate in kbit/s, derived from the byte delta between two polls.
    var kbps: Int = 0

    var trackSummary: String { tracks.isEmpty ? "—" : tracks.joined(separator: " + ") }
}

// MARK: - Server ports (fixed; MediaMTX serves every protocol at once)

enum Ports {
    static let rtmp = 1935
    static let rtsp = 8554
    static let hls  = 8888
    static let api  = 9997
    static let srt  = 8890
}
