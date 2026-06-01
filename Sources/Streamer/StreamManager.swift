import Foundation

@MainActor
final class StreamManager: ObservableObject {

    // MARK: - Published state

    @Published var configs: [StreamConfig] = [StreamConfig(index: 1)] {
        didSet { saveConfigs() }
    }
    @Published private(set) var runningStreams: [RunningStreamRecord] = []
    @Published private(set) var statuses: [UUID: StreamStatus]  = [:]

    private static let configsKey = "TurboStreamer.savedConfigs.v1"

    // Device lists (shared across all config cards)
    @Published private(set) var avVideoDevices:  [CaptureDevice] = []
    @Published private(set) var avAudioDevices:  [CaptureDevice] = []
    @Published private(set) var deckLinkDevices: [CaptureDevice] = []
    @Published private(set) var isScanningDevices = false

    // MARK: - Private

    private var stopFlags:      [UUID: Bool]              = [:]
    private var tasks:          [UUID: Task<Void, Never>] = [:]
    private var logFileHandles: [UUID: FileHandle]        = [:]
    private let registry = ProcessRegistry()

    let ffmpegPath: String

    init() {
        let bundled = Bundle.main.bundlePath + "/Contents/Resources/bin/ffmpeg"
        if FileManager.default.fileExists(atPath: bundled) {
            ffmpegPath = bundled
        } else if FileManager.default.fileExists(atPath: "/opt/homebrew/bin/ffmpeg") {
            ffmpegPath = "/opt/homebrew/bin/ffmpeg"
        } else {
            ffmpegPath = "/usr/local/bin/ffmpeg"
        }

        // Restore previously saved configs (assigning in init does not fire didSet)
        if let saved = Self.loadConfigs(), !saved.isEmpty {
            configs = saved
        }
    }

    // MARK: - Config persistence

    private func saveConfigs() {
        if let data = try? JSONEncoder().encode(configs) {
            UserDefaults.standard.set(data, forKey: Self.configsKey)
        }
    }

    private static func loadConfigs() -> [StreamConfig]? {
        guard let data = UserDefaults.standard.data(forKey: configsKey) else { return nil }
        return try? JSONDecoder().decode([StreamConfig].self, from: data)
    }

    // MARK: - Config management

    func setCount(_ n: Int) {
        let n = max(1, min(n, 8))
        if n > configs.count {
            configs += (configs.count ..< n).map { StreamConfig(index: $0 + 1) }
        } else {
            configs = Array(configs.prefix(n))
        }
    }

    // MARK: - Derived state

    var hasActiveStreams: Bool {
        runningStreams.contains { statuses[$0.id]?.phase.isActive == true }
    }

    var allStopped: Bool {
        runningStreams.allSatisfy { !(statuses[$0.id]?.phase.isActive ?? false) }
    }

    // MARK: - Stream lifecycle

    /// Starts all current configs as new stream instances and appends them to the Live tab.
    func startStreams() {
        let logsDir = logsDirectory()
        let now = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let timestamp = formatter.string(from: now)

        for config in configs {
            let safeName = config.name
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
            let logURL = logsDir.appendingPathComponent("\(timestamp)_\(safeName).log")

            let record = RunningStreamRecord(config: config, startedAt: now, logFileURL: logURL)
            runningStreams.append(record)
            statuses[record.id]   = StreamStatus()
            stopFlags[record.id]  = false

            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            logFileHandles[record.id] = FileHandle(forWritingAtPath: logURL.path)

            spawnTask(for: record)
        }
    }

    func stopStream(id: UUID) {
        stopFlags[id] = true
        tasks[id]?.cancel()
        tasks[id] = nil
        registry.terminate(id: id)
        if statuses[id]?.phase.isActive == true {
            statuses[id]?.phase = .stopped
            appendLog("■ Stream stopped by user.", to: id)
        }
        closeLogFile(id: id)
    }

    func stopAll() {
        for record in runningStreams { stopStream(id: record.id) }
    }

    /// Removes finished streams from the Live list.
    func clearStopped() {
        runningStreams.removeAll { !(statuses[$0.id]?.phase.isActive ?? false) }
    }

    // MARK: - Device listing

    /// Scans AVFoundation capture devices and populates the published lists.
    func refreshAVDevices() async {
        isScanningDevices = true
        let raw = await runFFmpegCapturingOutput(
            args: ["-hide_banner", "-f", "avfoundation", "-list_devices", "true", "-i", "\"\""]
        )
        let parsed = Self.parseAVFoundation(raw)
        avVideoDevices = parsed.video
        avAudioDevices = parsed.audio
        isScanningDevices = false
    }

    /// Scans Blackmagic DeckLink sources and populates the published list.
    func refreshDeckLinkDevices() async {
        isScanningDevices = true
        let raw = await runFFmpegCapturingOutput(args: ["-hide_banner", "-sources", "decklink"])
        deckLinkDevices = Self.parseDeckLink(raw)
        isScanningDevices = false
    }

    /// Runs ffmpeg with the given args and returns combined stdout/stderr.
    private func runFFmpegCapturingOutput(args: [String]) async -> String {
        let path = ffmpegPath
        let libDir = URL(fileURLWithPath: path)
            .deletingLastPathComponent()
            .appendingPathComponent("lib").path
        return await Task.detached(priority: .userInitiated) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            if FileManager.default.fileExists(atPath: libDir) {
                var env = ProcessInfo.processInfo.environment
                let existing = env["DYLD_LIBRARY_PATH"] ?? ""
                env["DYLD_LIBRARY_PATH"] = existing.isEmpty ? libDir : "\(libDir):\(existing)"
                p.environment = env
            }
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError  = pipe
            try? p.run()
            p.waitUntilExit()
            return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        }.value
    }

    // MARK: - Device list parsers

    /// Parses `ffmpeg -f avfoundation -list_devices` output into video/audio lists.
    static func parseAVFoundation(_ output: String) -> (video: [CaptureDevice], audio: [CaptureDevice]) {
        var video: [CaptureDevice] = []
        var audio: [CaptureDevice] = []
        var mode = 0   // 1 = video, 2 = audio

        for line in output.components(separatedBy: "\n") {
            if line.contains("AVFoundation video devices") { mode = 1; continue }
            if line.contains("AVFoundation audio devices") { mode = 2; continue }
            guard mode != 0 else { continue }

            // Each line looks like: "[AVFoundation indev @ 0x..] [0] FaceTime HD Camera"
            // Skip the log-prefix bracket, then read "[index] name".
            guard let prefixEnd = line.firstIndex(of: "]") else { continue }
            let rest = line[line.index(after: prefixEnd)...]
            guard let open  = rest.firstIndex(of: "["),
                  let close = rest.firstIndex(of: "]"),
                  open < close else { continue }
            let idx  = rest[rest.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
            guard Int(idx) != nil else { continue }
            let name = rest[rest.index(after: close)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }

            let device = CaptureDevice(index: idx, name: name)
            if mode == 1 { video.append(device) } else { audio.append(device) }
        }
        return (video, audio)
    }

    /// Parses `ffmpeg -sources decklink` output into a device list.
    static func parseDeckLink(_ output: String) -> [CaptureDevice] {
        var devices: [CaptureDevice] = []
        for line in output.components(separatedBy: "\n") {
            guard let open  = line.firstIndex(of: "["),
                  let close = line.firstIndex(of: "]"),
                  open < close else { continue }
            let name = String(line[line.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
            // Skip ffmpeg log lines like "[decklink @ 0x..] ..."
            if name.isEmpty || name.contains("@") { continue }
            devices.append(CaptureDevice(index: "", name: name))
        }
        return devices
    }

    // MARK: - Private: log helpers

    private func appendLog(_ text: String, to id: UUID) {
        statuses[id]?.appendLog(text)
        if let fh = logFileHandles[id], let data = (text + "\n").data(using: .utf8) {
            fh.write(data)
        }
    }

    private func closeLogFile(id: UUID) {
        logFileHandles[id]?.closeFile()
        logFileHandles[id] = nil
    }

    private func logsDirectory() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir  = docs.appendingPathComponent("TurboStreamer Logs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Private: task spawning

    private func spawnTask(for record: RunningStreamRecord) {
        let id = record.id

        tasks[id] = Task {
            var attempt = 0

            while !Task.isCancelled {
                guard stopFlags[id] == false else { break }

                attempt += 1
                statuses[id]?.phase = attempt == 1 ? .running : .reconnecting(attempt: attempt)
                appendLog("▶ Starting (attempt \(attempt))…", to: id)

                let exitCode = await runFFmpeg(record: record)

                if Task.isCancelled      { break }
                if stopFlags[id] == true { break }

                if exitCode == 0 {
                    appendLog("✓ Stream ended cleanly.", to: id)
                    statuses[id]?.phase = .stopped
                    break
                }

                appendLog("⚠ Disconnected (exit \(exitCode)) — reconnecting in 10 s…", to: id)
                for _ in 0 ..< 10 {
                    if Task.isCancelled || stopFlags[id] == true { break }
                    try? await Task.sleep(for: .seconds(1))
                }
            }

            if statuses[id]?.phase.isActive == true { statuses[id]?.phase = .stopped }
            closeLogFile(id: id)
        }
    }

    // MARK: - Private: process execution

    private func runFFmpeg(record: RunningStreamRecord) async -> Int32 {
        let id     = record.id
        let config = record.config
        let args   = buildArgs(for: config)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments     = args
        process.standardInput = FileHandle.nullDevice

        let libDir = URL(fileURLWithPath: ffmpegPath)
            .deletingLastPathComponent()
            .appendingPathComponent("lib").path
        if FileManager.default.fileExists(atPath: libDir) {
            var env = ProcessInfo.processInfo.environment
            let existing = env["DYLD_LIBRARY_PATH"] ?? ""
            env["DYLD_LIBRARY_PATH"] = existing.isEmpty ? libDir : "\(libDir):\(existing)"
            process.environment = env
        }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError  = pipe

        let cmd = ([ffmpegPath] + args).joined(separator: " ")
        appendLog("CMD: \(cmd)\n", to: id)

        registry.store(process, for: id)

        return await withCheckedContinuation { continuation in

            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty,
                      let text = String(data: data, encoding: .utf8) else { return }
                Task { @MainActor [weak self] in
                    self?.appendLog(text, to: id)
                }
            }

            process.terminationHandler = { [registry] p in
                pipe.fileHandleForReading.readabilityHandler = nil
                let tail = pipe.fileHandleForReading.readDataToEndOfFile()
                if !tail.isEmpty, let text = String(data: tail, encoding: .utf8) {
                    Task { @MainActor [weak self] in
                        self?.appendLog(text, to: id)
                    }
                }
                registry.remove(id: id, ifMatches: p)
                continuation.resume(returning: p.terminationStatus)
            }

            do {
                try process.run()
            } catch {
                registry.remove(id: id, ifMatches: process)
                Task { @MainActor [weak self] in
                    self?.appendLog("✗ Failed to launch ffmpeg: \(error.localizedDescription)", to: id)
                }
                continuation.resume(returning: -2)
            }
        }
    }

    // MARK: - Private: argument builder

    private func buildArgs(for config: StreamConfig) -> [String] {
        let bitrateNum = Int(config.videoBitrate.replacingOccurrences(of: "k", with: "")) ?? 4500
        let bufsize    = "\(bitrateNum * 2)k"
        let fpsInt     = Int(config.fps) ?? 30
        let dest       = "\(config.rtmpURL)/\(config.streamKey)"

        var args: [String]

        if config.inputType == .file {
            args = [
                "-hide_banner", "-loglevel", "info",
                "-hwaccel", "videotoolbox",
                "-re", "-stream_loop", "-1",
                "-i", config.filePath
            ]
        } else if config.inputType == .decklink {
            // Blackmagic DeckLink: device referenced by name, audio included automatically.
            // -thread_queue_size buffers the high-bitrate live feed so it doesn't overrun
            // while the RTMP output is still connecting.
            args = [
                "-hide_banner", "-loglevel", "info",
                "-f", "decklink",
                "-thread_queue_size", "1024",
                "-i", config.deckLinkDeviceName
            ]
        } else {
            let audio = config.audioDeviceIndex.isEmpty ? "none" : config.audioDeviceIndex
            args = [
                "-hide_banner", "-loglevel", "info",
                "-f", "avfoundation",
                "-thread_queue_size", "1024",
                "-video_size", config.resolution.captureSize,
                "-framerate", config.fps,
                "-i", "\(config.videoDeviceIndex):\(audio)"
            ]
        }

        args += ["-vf", config.resolution.scaleFilter, "-r", config.fps]

        // Encoder is chosen automatically — no user toggle.
        //  • 4K  → VideoToolbox: the only encoder fast enough at 2160p. Realtime,
        //          no frame reordering, software fallback allowed, so it never stalls.
        //  • ≤1080p → libx264 veryfast/zerolatency: proven, reliable, best quality,
        //          and easily real-time on Apple Silicon.
        if config.resolution == .uhd {
            args += [
                "-c:v", "h264_videotoolbox",
                "-profile:v", "high",
                "-b:v", config.videoBitrate,
                "-g",   "\(fpsInt * 2)",
                "-realtime", "1",
                "-prio_speed", "1",
                "-bf", "0",
                "-allow_sw", "1"
            ]
        } else {
            args += [
                "-c:v", "libx264", "-preset", "veryfast",
                "-profile:v", "high", "-pix_fmt", "yuv420p",
                "-b:v",    config.videoBitrate,
                "-maxrate", config.videoBitrate,
                "-bufsize", bufsize,
                "-g",      "\(fpsInt * 2)",
                "-tune",   "zerolatency"
            ]
        }

        args += [
            "-c:a", "aac",
            "-b:a", config.audioBitrate,
            "-ar",  "48000",
            "-ac",  "2",
            "-f",   "flv",
            dest
        ]

        return args
    }
}
