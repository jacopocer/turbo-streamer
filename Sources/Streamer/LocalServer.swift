import Foundation
import AppKit
import Darwin

/// Ports the local server binds. Same as Turbo Receiver's, so OBS/browser instructions
/// match; the two apps aren't meant to run on the same Mac at once.
enum LocalPorts {
    static let rtmp = 1935, rtsp = 8554, hls = 8888, api = 9997, srt = 8890
}

/// A live path served on the LAN (polled from the MediaMTX API).
struct LocalPathStatus: Equatable {
    var ready = false
    var tracks: [String] = []
    var readers = 0
    var kbps = 0
}

/// Turbo Streamer's embedded LAN server: runs the bundled MediaMTX so the app's own
/// stream is available on the local network over RTSP/RTMP/HLS/SRT and as NDI — the same
/// serving stack as Turbo Receiver, for the all-local case where nothing leaves the LAN.
@MainActor
final class LocalServer: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var statuses: [String: LocalPathStatus] = [:]
    @Published private(set) var addresses: [String] = []
    @Published var selectedAddress: String = "127.0.0.1"
    @Published private(set) var ndiEnabled: Set<String> = []
    @Published private(set) var logLines: [String] = []

    /// (path, display name) for every stream that should be served.
    private(set) var paths: [(path: String, name: String)] = []

    private var process: Process?
    private var pollTask: Task<Void, Never>?
    private var lastBytes: [String: (bytes: Int, at: Date)] = [:]

    // NDI subprocesses, keyed by path.
    private var ndiDecoders: [String: Process] = [:]
    private var ndiSenders:  [String: Process] = [:]
    private var ndiTasks:    [String: Task<Void, Never>] = [:]

    private var binDir: String { Bundle.main.bundlePath + "/Contents/Resources/bin" }
    private var mediamtxPath: String { binDir + "/mediamtx" }
    private var ffmpegPath: String { binDir + "/ffmpeg" }
    private var ffprobePath: String { binDir + "/ffprobe" }
    private var ndiSenderPath: String { binDir + "/ndi-sender" }

    var available: Bool { FileManager.default.isExecutableFile(atPath: mediamtxPath) }
    var ndiAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: ndiSenderPath)
            && (FileManager.default.fileExists(atPath: binDir + "/lib/libndi.dylib")
                || FileManager.default.fileExists(atPath: "/usr/local/lib/libndi.dylib"))
            && FileManager.default.isExecutableFile(atPath: ffmpegPath)
    }

    private func appendLog(_ s: String) {
        logLines.append(s)
        if logLines.count > 200 { logLines.removeFirst(logLines.count - 200) }
    }

    // MARK: - URLs

    /// Where the app's own ffmpeg publishes this stream.
    func ingestURL(_ path: String) -> String { "rtmp://127.0.0.1:\(LocalPorts.rtmp)/\(path)" }
    /// Consumer URLs use the LAN address so other machines can reach them.
    func rtspURL(_ path: String) -> String { "rtsp://\(lanAddress):\(LocalPorts.rtsp)/\(path)" }
    func hlsURL(_ path: String)  -> String { "http://\(lanAddress):\(LocalPorts.hls)/\(path)" }
    func srtURL(_ path: String)  -> String { "srt://\(lanAddress):\(LocalPorts.srt)  (streamid: read:\(path))" }

    /// A private LAN IP for consumers (never the Tailscale 100.x address).
    var lanAddress: String {
        addresses.first(where: { ip in
            let p = ip.split(separator: ".").compactMap { Int($0) }
            guard p.count == 4 else { return false }
            return (p[0] == 192 && p[1] == 168) || p[0] == 10 || (p[0] == 172 && (16...31).contains(p[1]))
        }) ?? addresses.first ?? "127.0.0.1"
    }

    // MARK: - Lifecycle

    func setPaths(_ list: [(path: String, name: String)]) {
        paths = list
        if isRunning {
            // Add any new paths live; MediaMTX accepts them at runtime.
            for p in list { Task { await apiCall("POST", "/v3/config/paths/add/\(p.path)", "{}") } }
        }
    }

    func start() {
        guard !isRunning, available else {
            if !available { appendLog("✗ mediamtx not bundled — LAN publishing unavailable") }
            return
        }
        refreshAddresses()
        let config = writeConfig()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: mediamtxPath)
        p.arguments = [config.path]
        p.standardInput = FileHandle.nullDevice
        let out = Pipe()
        p.standardOutput = out; p.standardError = out
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty, let t = String(data: d, encoding: .utf8), let self else { return }
            Task { @MainActor in self.appendLog(t.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        p.terminationHandler = { [weak self] proc in
            proc.terminationHandler = nil
            out.fileHandleForReading.readabilityHandler = nil
            guard let self else { return }
            Task { @MainActor in
                self.isRunning = false; self.pollTask?.cancel(); self.statuses = [:]
            }
        }
        do {
            try p.run()
            process = p; isRunning = true
            appendLog("▶ LAN server up — RTMP :\(LocalPorts.rtmp) · RTSP :\(LocalPorts.rtsp) · HLS :\(LocalPorts.hls) · SRT :\(LocalPorts.srt)")
            startPolling()
        } catch {
            appendLog("✗ Failed to launch mediamtx: \(error.localizedDescription)")
        }
    }

    func stop() {
        stopAllNDI()
        pollTask?.cancel(); pollTask = nil
        if let p = process, p.isRunning { kill(p.processIdentifier, SIGKILL) }
        process = nil; isRunning = false; statuses = [:]
    }

    private func writeConfig() -> URL {
        var yml = """
        logLevel: info
        api: yes
        apiAddress: 127.0.0.1:\(LocalPorts.api)
        rtmp: yes
        rtmpAddress: 0.0.0.0:\(LocalPorts.rtmp)
        rtsp: yes
        rtspAddress: 0.0.0.0:\(LocalPorts.rtsp)
        hls: yes
        hlsAddress: 0.0.0.0:\(LocalPorts.hls)
        hlsVariant: mpegts
        hlsAlwaysRemux: yes
        webrtc: no
        srt: yes
        srtAddress: 0.0.0.0:\(LocalPorts.srt)
        moq: no
        paths:

        """
        if paths.isEmpty { yml += "  _placeholder:\n" }
        else { for p in paths { yml += "  \(p.path):\n" } }
        let dir = (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                   ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent("TurboStreamer")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("local-mediamtx.yml")
        try? yml.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Addresses

    func refreshAddresses() {
        var found: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifaddr) == 0, let first = ifaddr {
            for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
                let flags = Int32(ptr.pointee.ifa_flags)
                guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
                guard let sa = ptr.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let ip = String(cString: host)
                    if !ip.isEmpty, !found.contains(ip) { found.append(ip) }
                }
            }
            freeifaddrs(ifaddr)
        }
        addresses = found
        if selectedAddress.isEmpty || !found.contains(selectedAddress) {
            selectedAddress = lanAddress
        }
    }

    // MARK: - Polling

    private struct APIList: Decodable { let items: [APIPath] }
    private struct APIPath: Decodable {
        let name: String; let ready: Bool; let tracks: [String]?
        let bytesReceived: Int?; let readers: [APIReader]?
    }
    private struct APIReader: Decodable { let type: String? }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled { await self?.poll(); try? await Task.sleep(for: .milliseconds(1500)) }
        }
    }
    private func poll() async {
        guard let url = URL(string: "http://127.0.0.1:\(LocalPorts.api)/v3/paths/list") else { return }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let list = try? JSONDecoder().decode(APIList.self, from: data) else { return }
        let now = Date(); var fresh: [String: LocalPathStatus] = [:]
        for item in list.items {
            var s = LocalPathStatus()
            s.ready = item.ready; s.tracks = item.tracks ?? []; s.readers = item.readers?.count ?? 0
            let bytes = item.bytesReceived ?? 0
            if let prev = lastBytes[item.name] {
                let dt = now.timeIntervalSince(prev.at)
                s.kbps = dt > 0.3 ? Int(Double(max(0, bytes - prev.bytes)) * 8.0 / dt / 1000.0) : (statuses[item.name]?.kbps ?? 0)
            }
            lastBytes[item.name] = (bytes, now)
            fresh[item.name] = s
        }
        statuses = fresh
    }

    @discardableResult
    private func apiCall(_ method: String, _ path: String, _ body: String? = nil) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(LocalPorts.api)\(path)") else { return false }
        var req = URLRequest(url: url, timeoutInterval: 5); req.httpMethod = method
        if let body { req.setValue("application/json", forHTTPHeaderField: "Content-Type"); req.httpBody = Data(body.utf8) }
        return ((try? await URLSession.shared.data(for: req)) != nil)
    }

    // MARK: - NDI (decode the local feed → FIFOs → ndi-sender)

    private func subprocessEnv() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let lib = binDir + "/lib"
        if FileManager.default.fileExists(atPath: lib) {
            let existing = env["DYLD_LIBRARY_PATH"] ?? ""
            env["DYLD_LIBRARY_PATH"] = existing.isEmpty ? lib : "\(lib):\(existing)"
        }
        return env
    }

    func toggleNDI(path: String, name: String) {
        if ndiEnabled.contains(path) {
            ndiEnabled.remove(path); stopNDI(path); appendLog("■ NDI off for \(name)")
        } else {
            guard ndiAvailable else { appendLog("✗ NDI unavailable — ndi-sender/runtime not bundled"); return }
            guard statuses[path]?.ready == true else { appendLog("✗ NDI needs a live feed first — start the stream"); return }
            ndiEnabled.insert(path)
            Task { await launchNDI(path: path, name: name) }
            superviseNDI(path: path, name: name)
        }
    }

    private func ndiDir() -> URL {
        let d = (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                 ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent("TurboStreamer/ndi")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func probeSource(path: String) async -> (w: Int, h: Int, fps: String, audio: Bool)? {
        let out = await runCapturing(ffprobePath, [
            "-v", "error", "-rtsp_transport", "tcp", "-select_streams", "v:0",
            "-show_entries", "stream=width,height,r_frame_rate", "-of", "csv=p=0",
            "rtsp://127.0.0.1:\(LocalPorts.rtsp)/\(path)"])
        let parts = out.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").first?.components(separatedBy: ",") ?? []
        guard parts.count >= 3, let w = Int(parts[0]), let h = Int(parts[1]), w > 0, h > 0 else { return nil }
        let fps = parts[2].isEmpty ? "25/1" : parts[2]
        let audio = (statuses[path]?.tracks ?? []).contains { $0.lowercased().contains("audio") }
        return (w, h, fps, audio)
    }

    private func runCapturing(_ path: String, _ args: [String]) async -> String {
        let env = subprocessEnv()
        return await Task.detached {
            let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args; p.environment = env
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
            try? p.run(); let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
            return String(data: d, encoding: .utf8) ?? ""
        }.value
    }

    private func launchNDI(path: String, name: String) async {
        guard ndiEnabled.contains(path), let info = await probeSource(path: path) else {
            if ndiEnabled.contains(path) { appendLog("✗ NDI: couldn't read \(name)'s format"); ndiEnabled.remove(path) }
            return
        }
        guard ndiEnabled.contains(path) else { return }
        let dir = ndiDir()
        let vFifo = dir.appendingPathComponent("\(path)-v.raw").path
        let aFifo = dir.appendingPathComponent("\(path)-a.raw").path
        for f in [vFifo, aFifo] { unlink(f); if mkfifo(f, 0o600) != 0 { appendLog("✗ NDI: FIFO error"); ndiEnabled.remove(path); return } }

        let sender = Process()
        sender.executableURL = URL(fileURLWithPath: ndiSenderPath)
        var sArgs = ["--name", name, "--video", vFifo, "--width", "\(info.w)", "--height", "\(info.h)",
                     "--fps-num", info.fps.components(separatedBy: "/").first ?? "25",
                     "--fps-den", info.fps.components(separatedBy: "/").last ?? "1"]
        if info.audio { sArgs += ["--audio", aFifo, "--rate", "48000", "--channels", "2"] }
        sender.arguments = sArgs
        sender.standardInput = FileHandle.nullDevice
        let sErr = Pipe(); sender.standardError = sErr; sender.standardOutput = FileHandle.nullDevice
        sErr.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty, let t = String(data: d, encoding: .utf8), let self else { return }
            Task { @MainActor in self.appendLog("NDI \(name): \(t.trimmingCharacters(in: .whitespacesAndNewlines))") }
        }

        let dec = Process()
        dec.executableURL = URL(fileURLWithPath: ffmpegPath)
        var dArgs = ["-y", "-hide_banner", "-loglevel", "error", "-rtsp_transport", "tcp",
                     "-i", "rtsp://127.0.0.1:\(LocalPorts.rtsp)/\(path)",
                     "-map", "0:v", "-f", "rawvideo", "-pix_fmt", "uyvy422", "-s", "\(info.w)x\(info.h)", vFifo]
        if info.audio { dArgs += ["-map", "0:a", "-f", "s16le", "-ar", "48000", "-ac", "2", aFifo] }
        dec.arguments = dArgs
        dec.standardInput = FileHandle.nullDevice; dec.standardOutput = FileHandle.nullDevice; dec.standardError = FileHandle.nullDevice
        dec.environment = subprocessEnv()
        do {
            try sender.run(); try dec.run()
            ndiSenders[path] = sender; ndiDecoders[path] = dec
            appendLog("▶ NDI \"\(name)\" — \(info.w)x\(info.h) @ \(info.fps)\(info.audio ? " + audio" : "")")
        } catch { appendLog("✗ NDI failed: \(error.localizedDescription)"); ndiEnabled.remove(path); teardownNDI(path) }
    }

    private func superviseNDI(path: String, name: String) {
        ndiTasks[path]?.cancel()
        ndiTasks[path] = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self, self.ndiEnabled.contains(path) else { return }
                let alive = (self.ndiDecoders[path]?.isRunning ?? false) && (self.ndiSenders[path]?.isRunning ?? false)
                if !alive {
                    self.teardownNDI(path)
                    guard self.statuses[path]?.ready == true else { continue }
                    self.appendLog("↻ NDI \(name): restarting")
                    await self.launchNDI(path: path, name: name)
                }
            }
        }
    }

    private func teardownNDI(_ path: String) {
        if let d = ndiDecoders[path], d.isRunning { d.terminate() }
        if let s = ndiSenders[path], s.isRunning { s.terminate() }
        ndiDecoders[path] = nil; ndiSenders[path] = nil
        let dir = ndiDir()
        unlink(dir.appendingPathComponent("\(path)-v.raw").path)
        unlink(dir.appendingPathComponent("\(path)-a.raw").path)
    }
    private func stopNDI(_ path: String) { ndiTasks[path]?.cancel(); ndiTasks[path] = nil; teardownNDI(path) }
    func stopAllNDI() { for k in Array(ndiEnabled) { ndiEnabled.remove(k); stopNDI(k) } }
}
