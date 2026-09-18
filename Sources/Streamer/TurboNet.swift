import Foundation
import AppKit

/// The app's own Tailscale node: launches the bundled `turbo-net` helper (tsnet, in
/// user space, no daemon or root) and talks to it over JSON lines. One node per app;
/// tunnels are opened on demand. The join key comes from turbolink, minted on the
/// spot; when the server has no Tailscale token yet, the helper prints a login URL
/// instead and the app shows it once.
@MainActor
final class TurboNet: ObservableObject {
    enum State: Equatable {
        case off, starting, needsLogin(String), up, failed(String)
    }
    @Published private(set) var state: State = .off
    @Published private(set) var ip: String = ""
    @Published private(set) var hostname: String = ""
    /// Per-tunnel path quality: true = direct, false = through a DERP relay.
    @Published private(set) var peerDirect: [String: Bool] = [:]
    @Published private(set) var peerRelay: [String: String] = [:]

    let helperPath: String
    let available: Bool
    private let stateDir: URL
    private let appTag: String
    private var process: Process?
    private var stdin: FileHandle?
    private var buffer = Data()
    private var waiters: [String: CheckedContinuation<String?, Never>] = [:]
    var log: (String) -> Void = { _ in }

    init(appTag: String) {
        self.appTag = appTag
        helperPath = Bundle.main.bundlePath + "/Contents/Resources/bin/turbo-net"
        available = FileManager.default.isExecutableFile(atPath: helperPath)
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        stateDir = base.appendingPathComponent(appTag == "receiver" ? "TurboReceiver" : "TurboStreamer")
            .appendingPathComponent("tailnet")
        let machine = (Host.current().localizedName ?? "mac")
            .lowercased()
            .map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        hostname = "turbo-\(appTag)-\(machine.isEmpty ? "mac" : String(machine.prefix(40)))"
    }

    static func isTailnetAddress(_ host: String) -> Bool {
        let p = host.split(separator: ".").compactMap { Int($0) }
        return p.count == 4 && p[0] == 100 && (64...127).contains(p[1])
    }

    // MARK: - Lifecycle

    /// Joins the tailnet (idempotent). Returns once the node has an address, needs a
    /// login, or failed.
    func start() async {
        guard available else { state = .failed("turbo-net helper not bundled"); return }
        if case .up = state { return }
        if case .starting = state { return }
        state = .starting
        let key = await fetchAuthKey()
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: helperPath)
        var args = ["--state", stateDir.path, "--hostname", hostname]
        if let key { args += ["--authkey", key, "--ephemeral"] }
        p.arguments = args
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty, let self else { return }
            Task { @MainActor in self.ingest(d) }
        }
        p.terminationHandler = { [weak self] proc in
            proc.terminationHandler = nil
            outPipe.fileHandleForReading.readabilityHandler = nil
            guard let self else { return }
            Task { @MainActor in
                if case .failed = self.state {} else { self.state = .off }
                self.ip = ""
                self.process = nil
                self.stdin = nil
                for (_, w) in self.waiters { w.resume(returning: nil) }
                self.waiters = [:]
            }
        }
        do {
            try p.run()
            process = p
            stdin = inPipe.fileHandleForWriting
            log("🕸 Turbo network: joining as \(hostname)…")
        } catch {
            state = .failed(error.localizedDescription)
            return
        }
        // Wait for up / needsLogin / failed (bounded).
        for _ in 0..<60 {
            switch state {
            case .up, .needsLogin, .failed: return
            default: try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    func stop() {
        if let p = process, p.isRunning { kill(p.processIdentifier, SIGKILL) }
        process = nil; stdin = nil; state = .off; ip = ""
    }

    // MARK: - Tunnels

    /// Receiver: expose local UDP `to` as tailnet :port. Returns when the listener is up.
    func listen(id: String, port: Int, to: String) async -> Bool {
        await start()
        guard case .up = state else { return false }
        return await command(["cmd": "listen", "id": id, "port": port, "to": to], id: id) != nil
    }

    /// Streamer: returns the local "127.0.0.1:port" whose traffic reaches `peer` on the
    /// tailnet, or nil.
    func dial(id: String, to peer: String) async -> String? {
        await start()
        guard case .up = state else { return nil }
        return await command(["cmd": "dial", "id": id, "to": peer], id: id)
    }

    func close(id: String) {
        send(["cmd": "close", "id": id])
        peerDirect[id] = nil; peerRelay[id] = nil
    }

    private func command(_ cmd: [String: Any], id: String) async -> String? {
        await withCheckedContinuation { c in
            waiters[id]?.resume(returning: nil)
            waiters[id] = c
            send(cmd)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(15))
                if let w = self.waiters.removeValue(forKey: id) { w.resume(returning: nil) }
            }
        }
    }

    private func send(_ cmd: [String: Any]) {
        guard let stdin, let data = try? JSONSerialization.data(withJSONObject: cmd) else { return }
        try? stdin.write(contentsOf: data + Data("\n".utf8))
    }

    // MARK: - Events from the helper

    private func ingest(_ d: Data) {
        buffer.append(d)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let event = obj["event"] as? String else { continue }
            handle(event, obj)
        }
    }

    private func handle(_ event: String, _ o: [String: Any]) {
        let id = o["id"] as? String ?? ""
        switch event {
        case "auth_url":
            if let u = o["url"] as? String, state != .needsLogin(u) {
                state = .needsLogin(u)
                log("🕸 Turbo network needs a one-time login: \(u)")
            }
        case "up":
            ip = o["ip"] as? String ?? ""
            state = .up
            log("🕸 Turbo network: connected as \(ip) (\(hostname)).")
        case "listening":
            waiters.removeValue(forKey: id)?.resume(returning: "\(o["port"] ?? 0)")
        case "local":
            waiters.removeValue(forKey: id)?.resume(returning: o["addr"] as? String)
        case "peer":
            let direct = o["direct"] as? Bool ?? false
            let relay = o["relay"] as? String ?? ""
            if peerDirect[id] != direct {
                peerDirect[id] = direct
                log(direct ? "🕸 Path to \(o["addr"] ?? ""): direct."
                           : "🕸 Path to \(o["addr"] ?? ""): through Tailscale relay \(relay) — slower; the Turbo relay may do better.")
            }
            peerRelay[id] = relay
        case "error":
            let msg = o["message"] as? String ?? "error"
            log("🕸 Turbo network: \(msg)")
            if id.isEmpty { state = .failed(msg) } else { waiters.removeValue(forKey: id)?.resume(returning: nil) }
        default: break
        }
    }

    // MARK: - Join key from turbolink

    private func fetchAuthKey() async -> String? {
        guard let url = URL(string: "\(LinkClient.baseURL)/v1/tailnet/key") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["app": appTag, "host": hostname])
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let key = obj["authKey"] as? String, !key.isEmpty else {
            log("🕸 Turbo network: no join key from the server — a one-time login will be asked.")
            return nil
        }
        return key
    }

    /// Opens the one-time login page in the browser.
    func openLogin() {
        if case .needsLogin(let u) = state, let url = URL(string: u) { NSWorkspace.shared.open(url) }
    }
}
