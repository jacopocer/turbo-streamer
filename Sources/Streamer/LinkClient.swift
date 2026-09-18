import Foundation

/// Client for the turbolink rendezvous. The streamer opens a session, shows the
/// code, and polls for receivers that joined. Only coordinates travel through
/// the server; the stream goes straight to each receiver, or through the relay
/// next to it when the streamer picks "Use relay".
enum LinkClient {
    static let defaultBase = "https://turbostreamer.indigital.tv"

    /// Overridable so it can be pointed at a local instance while testing.
    static var baseURL: String {
        let stored = UserDefaults.standard.string(forKey: "TurboStreamer.linkBase") ?? ""
        return stored.isEmpty ? defaultBase : stored
    }

    /// The public relay's coordinates for this session (option B): the streamer publishes
    /// here instead of straight to a receiver when there is no direct path (NAT, blocked
    /// UDP), and each receiver pulls from it. The key strings are composed by the server so
    /// they drop into the same url/key fields as a direct destination.
    struct Relay: Decodable, Equatable {
        let host: String
        let srtPort: Int
        let rtmpPort: Int
        let path: String
        let latencyMs: Int
        let srtURL: String
        let streamKey: String
        let rtmpURL: String
        let rtmpKey: String
    }
    struct Session: Decodable {
        let code: String
        let secret: String
        let expiresAt: String
        let relay: Relay?
    }
    struct Receiver: Decodable, Identifiable, Equatable {
        let id: String
        let label: String
        let `protocol`: String
        let host: String
        let port: Int
        let streamKey: String
        let latencyMs: Int

        /// The destination URL to put in the stream's config.
        var url: String { "\(`protocol`)://\(host):\(port)" }
        /// Reachable only from the receiver's own network (it announced a private address).
        var isLANOnly: Bool { LinkClient.isLANAddress(host) }
    }

    /// True for addresses that only work from inside the same network (RFC 1918, link-local,
    /// loopback). Tailscale's 100.64/10 is deliberately NOT here: that is the remote path.
    static func isLANAddress(_ host: String) -> Bool {
        let p = host.split(separator: ".").compactMap { Int($0) }
        guard p.count == 4 else { return host.lowercased() == "localhost" }
        if p[0] == 10 || p[0] == 127 { return true }
        if p[0] == 192, p[1] == 168 { return true }
        if p[0] == 172, (16...31).contains(p[1]) { return true }
        if p[0] == 169, p[1] == 254 { return true }
        return false
    }
    private struct SessionState: Decodable { let name: String; let receivers: [Receiver] }
    private struct APIError: Decodable { let error: String }

    enum Failure: LocalizedError {
        case expired, server(String), network(String)
        var errorDescription: String? {
            switch self {
            case .expired:        return "Session expired — create a new code"
            case .server(let m):  return m
            case .network(let m): return m
            }
        }
    }

    static func createSession(name: String) async throws -> Session {
        guard let url = URL(string: "\(baseURL)/v1/session") else { throw Failure.server("bad base URL") }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["name": name])
        return try await run(req)
    }

    static func receivers(code: String, secret: String) async throws -> [Receiver] {
        guard let url = URL(string: "\(baseURL)/v1/session/\(code)") else { throw Failure.expired }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue(secret, forHTTPHeaderField: "x-secret")
        let state: SessionState = try await run(req)
        return state.receivers
    }

    /// The streamer tells the rendezvous which transport it settled on, so receivers align
    /// (publisher mode for a direct publish, pull for the relay).
    static func reportTransport(code: String, secret: String, mode: String, detail: String) async {
        guard let url = URL(string: "\(baseURL)/v1/session/\(code)/transport") else { return }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(secret, forHTTPHeaderField: "x-secret")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["mode": mode, "detail": detail])
        _ = try? await URLSession.shared.data(for: req)
    }

    static func close(code: String, secret: String) async {
        guard let url = URL(string: "\(baseURL)/v1/session/\(code)") else { return }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "DELETE"
        req.setValue(secret, forHTTPHeaderField: "x-secret")
        _ = try? await URLSession.shared.data(for: req)
    }

    private static func run<T: Decodable>(_ req: URLRequest) async throws -> T {
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if status == 404 { throw Failure.expired }
            guard (200..<300).contains(status) else {
                let msg = (try? JSONDecoder().decode(APIError.self, from: data))?.error
                throw Failure.server(msg ?? "server replied \(status)")
            }
            return try JSONDecoder().decode(T.self, from: data)
        } catch let e as Failure {
            throw e
        } catch {
            throw Failure.network(error.localizedDescription)
        }
    }
}
