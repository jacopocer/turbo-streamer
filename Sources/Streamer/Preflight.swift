import Foundation
import Network

/// Lightweight pre-flight reachability check for an RTMP/RTMPS destination.
enum Preflight {

    /// Parses host + port from an rtmp:// or rtmps:// URL.
    static func hostPort(from rtmpURL: String) -> (host: String, port: UInt16)? {
        guard let comps = URLComponents(string: rtmpURL.trimmingCharacters(in: .whitespaces)),
              let host = comps.host, !host.isEmpty else { return nil }
        let scheme = (comps.scheme ?? "rtmp").lowercased()
        let defaultPort: UInt16 = (scheme == "rtmps" || scheme == "rtmpts") ? 443 : 1935
        // comps.port can be out of UInt16 range for a malformed URL — clamp safely.
        let port = comps.port.flatMap { UInt16(exactly: $0) } ?? defaultPort
        return (host, port)
    }

    /// Attempts a TCP connection to the destination, returning true if reachable within `timeout`.
    static func isReachable(_ rtmpURL: String, timeout: TimeInterval = 4) async -> Bool {
        guard let (host, port) = hostPort(from: rtmpURL),
              let nwPort = NWEndpoint.Port(rawValue: port) else { return false }

        return await withCheckedContinuation { continuation in
            let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
            var finished = false
            let finish: (Bool) -> Void = { ok in
                guard !finished else { return }
                finished = true
                conn.cancel()
                continuation.resume(returning: ok)
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:                       finish(true)
                case .failed, .cancelled:          finish(false)
                default:                           break
                }
            }
            conn.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(false) }
        }
    }
}
