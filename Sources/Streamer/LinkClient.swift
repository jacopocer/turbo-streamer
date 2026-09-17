import Foundation

/// Client for the turbolink rendezvous. The streamer opens a session, shows the
/// code, and polls for receivers that joined. Only coordinates travel through
/// the server — the stream itself goes straight to each receiver.
enum LinkClient {
    static let defaultBase = "https://turbostreamer.indigital.tv"

    /// Overridable so it can be pointed at a local instance while testing.
    static var baseURL: String {
        let stored = UserDefaults.standard.string(forKey: "TurboStreamer.linkBase") ?? ""
        return stored.isEmpty ? defaultBase : stored
    }

    struct Session: Decodable { let code: String; let secret: String; let expiresAt: String }
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
