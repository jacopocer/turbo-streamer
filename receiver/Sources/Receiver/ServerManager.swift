import Foundation
import Combine
import SwiftUI
import AppKit
import Darwin

/// Orchestrates a bundled MediaMTX process. The app itself never touches media:
/// MediaMTX ingests RTMP and republishes the same stream on RTSP / RTMP / HLS to
/// every reader on the LAN. Same crash-isolation model as Turbo Streamer.
@MainActor
final class ServerManager: ObservableObject {

    // MARK: - Published state

    @Published var keys: [IngestKey] = [] { didSet { saveKeys() } }
    @Published private(set) var isRunning = false
    @Published private(set) var statuses: [String: PathStatus] = [:]
    @Published private(set) var isReceiving = false   // a feed is flowing right now
    @Published private(set) var isTroubled  = false   // a feed that was live has dropped
    private var everReady: Set<String> = []           // feeds that have been live this run
    private var dropped:   Set<String> = []           // live-then-lost feeds (drives the frantic icon)
    @Published private(set) var logLines: [String] = []
    @Published private(set) var ndiEnabled: Set<String> = []      // keys currently emitting NDI

    // NDI bridge processes, per key: ffmpeg decoder + ndi-sender, plus a supervisor.
    var ndiDecoders: [String: Process] = [:]
    var ndiSenders:  [String: Process] = [:]
    var ndiTasks:    [String: Task<Void, Never>] = [:]

    func setNDIEnabled(_ on: Bool, for key: String) {
        if on { ndiEnabled.insert(key) } else { ndiEnabled.remove(key) }
    }
    @Published private(set) var addresses: [String] = []
    @Published var selectedAddress: String = ""

    // MARK: - Private

    private var process: Process?
    private var pipe: Pipe?
    private var pollTask: Task<Void, Never>?
    private var lastBytes: [String: (bytes: Int, at: Date)] = [:]
    private var relayFallbackTasks: [String: Task<Void, Never>] = [:]
    private static let keysKey = "TurboReceiver.keys.v1"

    let mediamtxPath: String

    /// The app's own Tailscale node (see TurboNet): once up, its 100.x address is what
    /// the pairing announces, so a streamer anywhere can reach this receiver directly.
    let turboNet = TurboNet(appTag: "receiver")
    private var netObservers: [AnyCancellable] = []

    init() {
        // Bundled first, then the dev checkout's vendor/ dir.
        let bundled = Bundle.main.bundlePath + "/Contents/Resources/bin/mediamtx"
        let vendor  = FileManager.default.currentDirectoryPath + "/vendor/mediamtx"
        if FileManager.default.isExecutableFile(atPath: bundled)      { mediamtxPath = bundled }
        else if FileManager.default.isExecutableFile(atPath: vendor)  { mediamtxPath = vendor }
        else                                                          { mediamtxPath = "/opt/homebrew/bin/mediamtx" }

        if let data = UserDefaults.standard.data(forKey: Self.keysKey),
           let saved = try? JSONDecoder().decode([IngestKey].self, from: data), !saved.isEmpty {
            keys = saved
        } else {
            keys = [IngestKey(name: "McQueen")]
        }
        refreshAddresses()

        turboNet.log = { [weak self] line in self?.appendLog(line) }
        turboNet.$ip
            .receive(on: RunLoop.main)
            .sink { [weak self] ip in
                guard let self else { return }
                self.refreshAddresses()
                if !ip.isEmpty { self.selectedAddress = ip }   // the remote-capable address wins
            }
            .store(in: &netObservers)
        turboNet.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &netObservers)
        Task { await turboNet.start() }

        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated { self.killServer(); self.turboNet.stop() }
        }
    }

    // MARK: - Keys

    func addKey(named name: String) {
        let k = IngestKey(name: name.isEmpty ? "Feed \(keys.count + 1)" : name)
        keys.append(k)
        // MediaMTX accepts new paths at runtime, so no restart is needed.
        if isRunning { Task { await apiCall(method: "POST", path: "/v3/config/paths/add/\(k.key)", body: "{}") } }
    }

    func removeKey(_ k: IngestKey) {
        keys.removeAll { $0.id == k.id }
        statuses[k.key] = nil
        if isRunning { Task { await apiCall(method: "DELETE", path: "/v3/config/paths/delete/\(k.key)") } }
    }

    /// Remembers the relay read URL that turbolink handed back for this feed.
    func setRelaySource(_ k: IngestKey, _ source: String, rtmp: String = "") {
        guard let i = keys.firstIndex(where: { $0.id == k.id }) else { return }
        keys[i].relaySource = source
        keys[i].relaySourceRTMP = rtmp
    }

    /// Direct (a publisher sends to this app) or Relay (MediaMTX pulls the feed from the
    /// public relay). Applied live through the API while the server runs; "publisher" is
    /// MediaMTX's word for "no source, wait for someone to publish".
    func setPullFromRelay(_ k: IngestKey, _ on: Bool) {
        guard let i = keys.firstIndex(where: { $0.id == k.id }) else { return }
        keys[i].pullFromRelay = on
        relayFallbackTasks[k.key]?.cancel(); relayFallbackTasks[k.key] = nil
        if !on {
            appendLog("↓ \(k.name): direct — waiting for a publisher.")
            if isRunning { Task { await self.applySource(k.key, "publisher") } }
            return
        }
        guard !keys[i].relaySource.isEmpty else { return }
        let key = k.key
        // Prefer RTMP over TCP for the relay: reliable where UDP is blocked. SRT only when
        // there is no RTMP URL (older sessions).
        let src = keys[i].relaySourceRTMP.isEmpty ? keys[i].relaySource : keys[i].relaySourceRTMP
        appendLog("↓ \(k.name): pulling from the relay over \(keys[i].relaySourceRTMP.isEmpty ? "SRT" : "RTMP").")
        if isRunning, !src.isEmpty { Task { await self.applySource(key, src) } }
    }

    private func applySource(_ key: String, _ source: String) async {
        await apiCall(method: "PATCH", path: "/v3/config/paths/patch/\(key)", body: "{\"source\":\"\(source)\"}")
    }

    func regenerateKey(_ k: IngestKey) {
        guard let i = keys.firstIndex(where: { $0.id == k.id }) else { return }
        let old = keys[i].key
        let fresh = IngestKey.randomKey()
        keys[i].key = fresh
        statuses[old] = nil
        if isRunning {
            Task {
                await apiCall(method: "DELETE", path: "/v3/config/paths/delete/\(old)")
                await apiCall(method: "POST", path: "/v3/config/paths/add/\(fresh)", body: "{}")
            }
        }
    }

    private func saveKeys() {
        if let data = try? JSONEncoder().encode(keys) {
            UserDefaults.standard.set(data, forKey: Self.keysKey)
        }
    }

    // MARK: - URLs shown to the user

    func ingestURL(_ k: IngestKey) -> String { "rtmp://\(selectedAddress):\(Ports.rtmp)/\(k.key)" }
    func rtspURL(_ k: IngestKey)   -> String { "rtsp://\(lanAddress):\(Ports.rtsp)/\(k.key)" }
    func hlsURL(_ k: IngestKey)    -> String { "http://\(lanAddress):\(Ports.hls)/\(k.key)" }

    /// The address for viewers on the receiver's own network (OBS, a browser): a private
    /// LAN IP, never the Tailscale 100.x one, which a LAN device without Tailscale can't
    /// reach. Falls back to the selected address when there's no private IP.
    var lanAddress: String {
        addresses.first(where: { ip in
            let p = ip.split(separator: ".").compactMap { Int($0) }
            guard p.count == 4 else { return false }
            return p[0] == 192 && p[1] == 168 || p[0] == 10 || (p[0] == 172 && (16...31).contains(p[1]))
        }) ?? selectedAddress
    }
    /// Low-latency publish endpoint. The path travels in the SRT streamid.
    func srtURL(_ k: IngestKey)    -> String { "srt://\(selectedAddress):\(Ports.srt)  (streamid: publish:\(k.key))" }

    // MARK: - Server lifecycle

    func start() {
        guard !isRunning else { return }
        guard FileManager.default.isExecutableFile(atPath: mediamtxPath) else {
            appendLog("✗ mediamtx not found at \(mediamtxPath) — run receiver/fetch-mediamtx.sh")
            return
        }
        let config = writeConfig()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: mediamtxPath)
        p.arguments     = [config.path]
        p.standardInput = FileHandle.nullDevice

        let out = Pipe()
        p.standardOutput = out
        p.standardError  = out
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty, let text = String(data: d, encoding: .utf8), let self else { return }
            Task { @MainActor in self.appendLog(text) }
        }
        p.terminationHandler = { [weak self] proc in
            proc.terminationHandler = nil
            out.fileHandleForReading.readabilityHandler = nil
            let code = proc.terminationStatus
            guard let self else { return }
            Task { @MainActor in
                self.isRunning = false
                self.pollTask?.cancel()
                self.statuses = [:]
                self.appendLog("■ Server stopped (exit \(code)).")
            }
        }
        do {
            try p.run()
            process = p
            pipe = out
            isRunning = true
            appendLog("▶ Server started — RTMP :\(Ports.rtmp) · RTSP :\(Ports.rtsp) · HLS :\(Ports.hls)")
            startPolling()
            // Expose the SRT door on the Turbo network too.
            Task { [weak self] in
                guard let self else { return }
                if await self.turboNet.listen(id: "srt", port: Ports.srt, to: "127.0.0.1:\(Ports.srt)") {
                    self.appendLog("🕸 SRT :\(Ports.srt) also reachable on the Turbo network at \(self.turboNet.ip).")
                }
            }
        } catch {
            appendLog("✗ Failed to launch mediamtx: \(error.localizedDescription)")
        }
    }

    func stop() {
        stopAllNDI()
        turboNet.close(id: "srt")
        pollTask?.cancel(); pollTask = nil
        process?.terminate()
        process = nil
        isRunning = false
        statuses = [:]
        everReady = []; dropped = []
        isReceiving = false; isTroubled = false
    }

    /// SIGKILL on quit so the server never orphans and keeps the ports bound.
    func killServer() {
        stopAllNDI()
        pollTask?.cancel()
        if let p = process, p.isRunning { kill(p.processIdentifier, SIGKILL) }
        process = nil
        isRunning = false
    }

    private func writeConfig() -> URL {
        var yml = """
        logLevel: info
        api: yes
        apiAddress: 127.0.0.1:\(Ports.api)
        rtmp: yes
        rtmpAddress: 0.0.0.0:\(Ports.rtmp)
        rtsp: yes
        rtspAddress: 0.0.0.0:\(Ports.rtsp)
        hls: yes
        hlsAddress: 0.0.0.0:\(Ports.hls)
        hlsVariant: fmp4
        hlsAlwaysRemux: yes
        webrtc: no
        srt: yes
        srtAddress: 0.0.0.0:\(Ports.srt)
        moq: no
        paths:

        """
        // Only declared keys are accepted — an unknown path is refused at publish time.
        // A feed in Relay mode has a source: MediaMTX pulls it from the public relay
        // instead of waiting for a publisher. (moq is off: MediaMTX 1.21 enables it by
        // default, taking :8892 and writing a self-signed cert into the working dir.)
        if keys.isEmpty { yml += "  _placeholder:\n" }
        else {
            for k in keys {
                yml += "  \(k.key):\n"
                // Relay pull defaults to RTMP over TCP: the relay is used exactly when a
                // network is hostile, and those block SRT's UDP (port 8890) far more often
                // than TCP 1935. SRT stays available for the direct path, not the relay.
                if k.pullFromRelay {
                    let src = k.relaySourceRTMP.isEmpty ? k.relaySource : k.relaySourceRTMP
                    if !src.isEmpty { yml += "    source: \(src)\n" }
                }
            }
        }

        let dir = (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                   ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent("TurboReceiver")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("mediamtx.yml")
        try? yml.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Status polling

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(for: .milliseconds(1500))
            }
        }
    }

    private struct APIList: Decodable { let items: [APIPath] }
    private struct APIPath: Decodable {
        let name: String
        let ready: Bool
        let tracks: [String]?
        let bytesReceived: Int?
        let readers: [APIReader]?
        let source: APISource?
    }
    private struct APIReader: Decodable { let type: String? }
    private struct APISource: Decodable { let type: String? }

    private func poll() async {
        guard let url = URL(string: "http://127.0.0.1:\(Ports.api)/v3/paths/list") else { return }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let list = try? JSONDecoder().decode(APIList.self, from: data) else { return }
        let now = Date()
        var fresh: [String: PathStatus] = [:]
        for item in list.items {
            var s = PathStatus()
            s.ready         = item.ready
            s.tracks        = item.tracks ?? []
            s.readers       = item.readers?.count ?? 0
            s.bytesReceived = item.bytesReceived ?? 0
            s.sourceType    = item.source?.type
            if let prev = lastBytes[item.name] {
                let dt = now.timeIntervalSince(prev.at)
                if dt > 0.3 {
                    s.kbps = Int(Double(max(0, s.bytesReceived - prev.bytes)) * 8.0 / dt / 1000.0)
                } else {
                    s.kbps = statuses[item.name]?.kbps ?? 0
                }
            }
            lastBytes[item.name] = (s.bytesReceived, now)
            fresh[item.name] = s
        }
        statuses = fresh

        // Health for the animated icon: rock while receiving, go frantic when a feed
        // that was live drops out.
        var receiving = false
        for (name, st) in fresh {
            if st.ready { receiving = true; everReady.insert(name); dropped.remove(name) }
            else if everReady.contains(name) { dropped.insert(name) }
        }
        let present = Set(fresh.keys)
        everReady.formIntersection(present)
        dropped.formIntersection(present)
        isReceiving = receiving
        isTroubled  = isRunning && !dropped.isEmpty
    }

    @discardableResult
    private func apiCall(method: String, path: String, body: String? = nil) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(Ports.api)\(path)") else { return false }
        var req = URLRequest(url: url, timeoutInterval: 5)
        req.httpMethod = method
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = Data(body.utf8)
        }
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (200..<300).contains((resp as? HTTPURLResponse)?.statusCode ?? 0)
    }

    // MARK: - Local addresses

    /// Every non-loopback IPv4 the machine has, so the user can pick the LAN or
    /// Tailscale address the senders/readers should actually use.
    func refreshAddresses() {
        var found: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifaddr) == 0, let first = ifaddr {
            for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
                let flags = Int32(ptr.pointee.ifa_flags)
                guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
                guard let sa = ptr.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count),
                               nil, 0, NI_NUMERICHOST) == 0 {
                    let ip = String(cString: host)
                    if !ip.isEmpty, !found.contains(ip) { found.append(ip) }
                }
            }
            freeifaddrs(ifaddr)
        }
        if !turboNet.ip.isEmpty, !found.contains(turboNet.ip) { found.insert(turboNet.ip, at: 0) }
        addresses = found
        if selectedAddress.isEmpty || !found.contains(selectedAddress) {
            // Prefer a Tailscale address (100.x) if present — that's the remote path.
            selectedAddress = found.first(where: { $0.hasPrefix("100.") }) ?? found.first ?? "127.0.0.1"
        }
    }

    // MARK: - Log

    func appendLog(_ text: String) {
        let incoming = text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        logLines.append(contentsOf: incoming)
        if logLines.count > 400 { logLines.removeFirst(logLines.count - 400) }
    }
}
