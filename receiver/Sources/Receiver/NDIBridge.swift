import Foundation
import Darwin

/// NDI output. For each enabled feed the app runs two subprocesses:
///   ffmpeg   — decodes the feed from MediaMTX and writes raw UYVY422 video and
///              s16le audio into two FIFOs
///   ndi-sender — reads those FIFOs and publishes them as an NDI source
/// Same orchestrator model as everything else: the app moves no pixels itself.
extension ServerManager {

    // MARK: - Tool paths

    private var binDir: String { Bundle.main.bundlePath + "/Contents/Resources/bin" }
    var ffmpegPath: String  { binDir + "/ffmpeg" }
    var ffprobePath: String { binDir + "/ffprobe" }
    var ndiSenderPath: String { binDir + "/ndi-sender" }

    /// NDI needs our sender plus the NDI runtime that NDI Tools installs.
    var ndiAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: ndiSenderPath)
            && (FileManager.default.fileExists(atPath: binDir + "/lib/libndi.dylib")
                || FileManager.default.fileExists(atPath: "/usr/local/lib/libndi.dylib"))
            && FileManager.default.isExecutableFile(atPath: ffmpegPath)
    }

    private func subprocessEnv() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let lib = binDir + "/lib"
        if FileManager.default.fileExists(atPath: lib) {
            let existing = env["DYLD_LIBRARY_PATH"] ?? ""
            env["DYLD_LIBRARY_PATH"] = existing.isEmpty ? lib : "\(lib):\(existing)"
        }
        return env
    }

    // MARK: - Public toggle

    func toggleNDI(_ k: IngestKey) {
        if ndiEnabled.contains(k.key) {
            setNDIEnabled(false, for: k.key)
            stopNDI(key: k.key)
            appendLog("■ NDI off for \(k.name)")
        } else {
            guard ndiAvailable else {
                appendLog("✗ NDI unavailable — needs ndi-sender bundled and NDI Tools installed")
                return
            }
            guard statuses[k.key]?.ready == true else {
                appendLog("✗ NDI needs a live feed first — nothing is publishing to \(k.name)")
                return
            }
            setNDIEnabled(true, for: k.key)
            Task { await launchNDI(key: k.key, name: k.name) }
            superviseNDI(key: k.key, name: k.name)
        }
    }

    // MARK: - Lifecycle

    private func ndiDir() -> URL {
        let d = (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                 ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent("TurboReceiver/ndi")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// width, height, fps and whether the source carries audio.
    private func probeSource(key: String) async -> (w: Int, h: Int, fps: String, audio: Bool)? {
        let url = "rtsp://127.0.0.1:\(Ports.rtsp)/\(key)"
        let out = await runCapturing(ffprobePath, [
            "-v", "error", "-rtsp_transport", "tcp",
            "-select_streams", "v:0",
            "-show_entries", "stream=width,height,r_frame_rate",
            "-of", "csv=p=0", url
        ])
        let parts = out.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "\n").first?.components(separatedBy: ",") ?? []
        guard parts.count >= 3, let w = Int(parts[0]), let h = Int(parts[1]), w > 0, h > 0 else { return nil }
        let fps = parts[2].isEmpty ? "25/1" : parts[2]
        let hasAudio = (statuses[key]?.tracks ?? []).contains { $0.lowercased().contains("audio") }
        return (w, h, fps, hasAudio)
    }

    func runCapturing(_ path: String, _ args: [String]) async -> String {
        let env = subprocessEnv()
        return await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            p.environment = env
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            try? p.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(data: data, encoding: .utf8) ?? ""
        }.value
    }

    func launchNDI(key: String, name: String) async {
        guard ndiEnabled.contains(key) else { return }
        guard let info = await probeSource(key: key) else {
            appendLog("✗ NDI: could not read the format of \(name) — is it still live?")
            setNDIEnabled(false, for: key)
            return
        }
        guard ndiEnabled.contains(key) else { return }   // toggled off while probing

        let dir = ndiDir()
        let vFifo = dir.appendingPathComponent("\(key)-v.raw").path
        let aFifo = dir.appendingPathComponent("\(key)-a.raw").path
        for f in [vFifo, aFifo] {
            unlink(f)
            if mkfifo(f, 0o600) != 0 {
                appendLog("✗ NDI: cannot create FIFO \(f)")
                setNDIEnabled(false, for: key)
                return
            }
        }

        // ndi-sender first: it opens the FIFOs for reading, ffmpeg then opens them
        // for writing and both unblock each other.
        let sender = Process()
        sender.executableURL = URL(fileURLWithPath: ndiSenderPath)
        var sArgs = ["--name", name,
                     "--video", vFifo,
                     "--width", "\(info.w)", "--height", "\(info.h)",
                     "--fps-num", info.fps.components(separatedBy: "/").first ?? "25",
                     "--fps-den", info.fps.components(separatedBy: "/").last ?? "1"]
        if info.audio { sArgs += ["--audio", aFifo, "--rate", "48000", "--channels", "2"] }
        sender.arguments = sArgs
        sender.standardInput = FileHandle.nullDevice
        let sErr = Pipe()
        sender.standardError = sErr
        sender.standardOutput = FileHandle.nullDevice
        sErr.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty, let t = String(data: d, encoding: .utf8), let self else { return }
            Task { @MainActor in self.appendLog("NDI \(name): \(t.trimmingCharacters(in: .whitespacesAndNewlines))") }
        }

        let dec = Process()
        dec.executableURL = URL(fileURLWithPath: ffmpegPath)
        var dArgs = ["-y", "-hide_banner", "-loglevel", "error",
                     "-rtsp_transport", "tcp",
                     "-i", "rtsp://127.0.0.1:\(Ports.rtsp)/\(key)",
                     "-map", "0:v", "-f", "rawvideo", "-pix_fmt", "uyvy422",
                     "-s", "\(info.w)x\(info.h)", vFifo]
        if info.audio {
            dArgs += ["-map", "0:a", "-f", "s16le", "-ar", "48000", "-ac", "2", aFifo]
        }
        dec.arguments = dArgs
        dec.standardInput = FileHandle.nullDevice
        dec.standardOutput = FileHandle.nullDevice
        dec.standardError = FileHandle.nullDevice
        dec.environment = subprocessEnv()

        do {
            try sender.run()
            try dec.run()
            ndiSenders[key] = sender
            ndiDecoders[key] = dec
            appendLog("▶ NDI \"\(name)\" — \(info.w)x\(info.h) @ \(info.fps)\(info.audio ? " + audio" : ", no audio")")
        } catch {
            appendLog("✗ NDI failed to start: \(error.localizedDescription)")
            setNDIEnabled(false, for: key)
            teardownNDIProcesses(key: key)
        }
    }

    /// Restarts the bridge if either process dies while NDI is still switched on
    /// (e.g. the remote feed dropped and came back).
    private func superviseNDI(key: String, name: String) {
        ndiTasks[key]?.cancel()
        ndiTasks[key] = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self, self.ndiEnabled.contains(key) else { return }
                let alive = (self.ndiDecoders[key]?.isRunning ?? false)
                         && (self.ndiSenders[key]?.isRunning ?? false)
                if !alive {
                    self.teardownNDIProcesses(key: key)
                    guard self.statuses[key]?.ready == true else { continue }  // wait for the feed
                    self.appendLog("↻ NDI \(name): bridge restarting")
                    await self.launchNDI(key: key, name: name)
                }
            }
        }
    }

    func teardownNDIProcesses(key: String) {
        if let d = ndiDecoders[key], d.isRunning { d.terminate() }
        if let s = ndiSenders[key], s.isRunning { s.terminate() }
        ndiDecoders[key] = nil
        ndiSenders[key] = nil
        let dir = ndiDir()
        unlink(dir.appendingPathComponent("\(key)-v.raw").path)
        unlink(dir.appendingPathComponent("\(key)-a.raw").path)
    }

    func stopNDI(key: String) {
        ndiTasks[key]?.cancel()
        ndiTasks[key] = nil
        teardownNDIProcesses(key: key)
    }

    func stopAllNDI() {
        for key in Array(ndiEnabled) {
            setNDIEnabled(false, for: key)
            stopNDI(key: key)
        }
    }
}
