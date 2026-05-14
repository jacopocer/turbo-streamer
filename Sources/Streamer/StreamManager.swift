import Foundation

@MainActor
final class StreamManager: ObservableObject {

    // MARK: - Published state

    @Published var configs: [StreamConfig]                       = [StreamConfig(index: 1)]
    @Published private(set) var runningStreams: [RunningStreamRecord] = []
    @Published private(set) var statuses: [UUID: StreamStatus]  = [:]

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

    func listDevices() async -> String {
        let path = ffmpegPath
        return await Task.detached(priority: .userInitiated) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = ["-hide_banner", "-f", "avfoundation", "-list_devices", "true", "-i", "\"\""]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError  = pipe
            try? p.run()
            p.waitUntilExit()
            return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        }.value
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
        } else {
            let audio = config.audioDeviceIndex.isEmpty ? "none" : config.audioDeviceIndex
            args = [
                "-hide_banner", "-loglevel", "info",
                "-f", "avfoundation",
                "-video_size", config.resolution.captureSize,
                "-framerate", config.fps,
                "-i", "\(config.videoDeviceIndex):\(audio)"
            ]
        }

        args += ["-vf", config.resolution.scaleFilter, "-r", config.fps]

        if config.useHardwareEncoding {
            args += [
                "-c:v", "h264_videotoolbox",
                "-profile:v", "high",
                "-b:v", config.videoBitrate,
                "-g",   "\(fpsInt * 2)"
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
