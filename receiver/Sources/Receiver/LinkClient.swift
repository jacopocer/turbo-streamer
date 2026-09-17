import Foundation

/// Client for the turbolink rendezvous. It exchanges connection coordinates only:
/// the stream itself never goes near the server.
enum LinkClient {
    static let defaultBase = "https://turbostreamer.indigital.tv"

    /// Overridable so the service can be pointed at a local instance while testing.
    static var baseURL: String {
        let stored = UserDefaults.standard.string(forKey: "TurboReceiver.linkBase") ?? ""
        return stored.isEmpty ? defaultBase : stored
    }

    /// Where this receiver can pull the feed from if the streamer sends through the relay.
    struct Relay: Decodable {
        let host: String
        let srtPort: Int
        let path: String
        let latencyMs: Int
        let source: String   // MediaMTX path source: srt://host:port?streamid=read:path:user:pass
    }
    struct JoinResult: Decodable {
        let ok: Bool
        let receiverId: String
        let sessionName: String
        let relay: Relay?
    }
    private struct APIError: Decodable { let error: String }

    enum Failure: LocalizedError {
        case badCode, server(String), network(String)
        var errorDescription: String? {
            switch self {
            case .badCode:            return "Code not recognised, or expired"
            case .server(let m):      return m
            case .network(let m):     return m
            }
        }
    }

    /// Publishes where this receiver can be reached, under the streamer's code.
    static func join(code: String,
                     label: String,
                     host: String,
                     port: Int,
                     streamKey: String,
                     latencyMs: Int) async throws -> JoinResult {
        let clean = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard clean.count >= 4, let url = URL(string: "\(baseURL)/v1/session/\(clean)/join") else {
            throw Failure.badCode
        }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "label": label, "protocol": "srt", "host": host,
            "port": port, "streamKey": streamKey, "latencyMs": latencyMs,
        ])
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 404 { throw Failure.badCode }
            guard (200..<300).contains(code) else {
                let msg = (try? JSONDecoder().decode(APIError.self, from: data))?.error
                throw Failure.server(msg ?? "server replied \(code)")
            }
            return try JSONDecoder().decode(JoinResult.self, from: data)
        } catch let e as Failure {
            throw e
        } catch {
            throw Failure.network(error.localizedDescription)
        }
    }
}
