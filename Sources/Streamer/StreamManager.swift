import Foundation
import AppKit
import AVFoundation

@MainActor
final class StreamManager: ObservableObject {

    // MARK: - Published state

    @Published var configs: [StreamConfig] = [StreamConfig(index: 1)] {
        didSet { saveConfigs(); syncPreviewsToConfigChanges(old: oldValue) }
    }
    @Published private(set) var runningStreams: [RunningStreamRecord] = []
    @Published private(set) var statuses: [UUID: StreamStatus]  = [:]

    private static let configsKey = "TurboStreamer.savedConfigs.v1"

    @Published private(set) var savedProfileNames: [String] = []
    private static let profilesKey = "TurboStreamer.savedProfiles.v1"

    /// Global webhook URL for drop/recover alerts (empty = off). Persisted.
    @Published var alertWebhookURL: String = "" {
        didSet {
            UserDefaults.standard.set(alertWebhookURL, forKey: Self.alertWebhookKey)
            alertTestResult = nil   // any prior Send-test result is stale once the URL changes
        }
    }
    @Published var alertTestResult: String?   // transient Send-test outcome shown in the Alerts popover
    private static let alertWebhookKey = "TurboStreamer.alertWebhookURL.v1"

    // Device lists (shared across all config cards)
    @Published private(set) var avVideoDevices:  [CaptureDevice] = []
    @Published private(set) var avAudioDevices:  [CaptureDevice] = []
    @Published private(set) var deckLinkDevices: [CaptureDevice] = []
    @Published private(set) var isScanningDevices = false

    // MARK: - Private

    private var stopFlags:      [UUID: Bool]              = [:]
    private var tasks:          [UUID: Task<Void, Never>] = [:]
    private var logFileHandles: [UUID: FileHandle]        = [:]
    private var lastProgressAt: [UUID: Date]              = [:]
    private var framesSeenThisRun: Set<UUID>              = []    // did the current ffmpeg run ever push a frame?
    private var tailnetRuns: Set<UUID>                    = []    // streams whose SRT goes through the Turbo network tunnel

    /// The app's own Tailscale node (see TurboNet). Started at launch, non-blocking.
    let turboNet = TurboNet(appTag: "streamer")
    @Published private(set) var networkLog: [String] = []

    /// Embedded LAN server (MediaMTX + NDI): serve the app's own stream on the local
    /// network, for the all-local case where nothing needs to leave the LAN.
    let localServer = LocalServer()
    @Published var localPublishEnabled = false { didSet { UserDefaults.standard.set(localPublishEnabled, forKey: "TurboStreamer.localPublish") } }
    private var slateProcesses: [UUID: Process]           = [:]
    private var slatePipes:     [UUID: Pipe]              = [:]
    private var overlayText:    [UUID: String]            = [:]   // live overlay text per stream
    private var captureFramerate: [UUID: String]          = [:]   // device-supported fps, probed once
    private var droppedStreams: Set<UUID> = []   // healthy streams that dropped (pairs drop↔recover alerts)
    @Published private(set) var mutedStreams: Set<UUID> = []   // live streams with the outgoing audio silenced
    private var stdinPipes: [UUID: Pipe] = [:]   // ffmpeg stdin, for runtime filter commands (mute)
    /// Destination swapped in by pre-flight (SRT blocked → the relay's RTMP door), per run.
    private var destinationOverride: [UUID: (url: String, key: String)] = [:]
    @Published private(set) var previewing: Set<UUID>     = []     // configs with a live preview running
    private var previewProcesses: [UUID: Process]         = [:]
    private var previewPipes:     [UUID: Pipe]            = [:]
    private var previewRestartTasks: [UUID: Task<Void, Never>] = [:]
    private let registry = ProcessRegistry()

    /// No video frames for this long ⇒ input is stalled/hung ⇒ force a restart.
    private let hangTimeout: TimeInterval = 10

    /// Power-management token that keeps the Mac awake while streaming.
    private var activityToken: NSObjectProtocol?

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

        localPublishEnabled = UserDefaults.standard.bool(forKey: "TurboStreamer.localPublish")
        turboNet.log = { [weak self] line in
            guard let self else { return }
            self.networkLog.append(line)
            if self.networkLog.count > 60 { self.networkLog.removeFirst(self.networkLog.count - 60) }
        }
        Task { await turboNet.start() }

        // Restore previously saved configs (assigning in init does not fire didSet)
        if let saved = Self.loadConfigs(), !saved.isEmpty {
            configs = saved
        }
        savedProfileNames = Self.loadProfiles().map(\.name)
        alertWebhookURL   = UserDefaults.standard.string(forKey: Self.alertWebhookKey) ?? ""

        // Writing a filter command to a dead ffmpeg's stdin must not kill the app.
        signal(SIGPIPE, SIG_IGN)

        // Fresh debug log each session
        try? "=== session start \(Date()) ===\n".write(to: debugLogURL(), atomically: true, encoding: .utf8)

        installSleepObservers()
    }

    // MARK: - Power management

    /// Warn when the Mac is about to sleep — a closed lid forces sleep, which we
    /// cannot prevent (only idle sleep is blocked by the power assertion).
    private func installSleepObservers() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.handleSystemSleep(waking: false) }
        }
        nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.handleSystemSleep(waking: true) }
        }
        // Kill all child ffmpeg processes on quit so they don't orphan and linger
        // (orphans from previous runs fight over the same files and break previews).
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated { self.killAllChildProcesses() }
        }
    }

    /// SIGKILL every ffmpeg we spawned (streams, slates, previews). Called on app quit.
    func killAllChildProcesses() {
        for p in previewProcesses.values where p.isRunning { kill(p.processIdentifier, SIGKILL) }
        for p in slateProcesses.values   where p.isRunning { kill(p.processIdentifier, SIGKILL) }
        registry.killAll()
        localServer.stop()   // don't orphan the embedded mediamtx / NDI
    }

    /// Keep the Mac from idle-sleeping while any stream is live; release when idle.
    private func refreshPowerAssertion() {
        if hasActiveStreams, activityToken == nil {
            activityToken = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .userInitiated],
                reason: "Turbo Streamer: live streaming in progress")
        } else if !hasActiveStreams, let token = activityToken {
            ProcessInfo.processInfo.endActivity(token)
            activityToken = nil
        }
    }

    private func handleSystemSleep(waking: Bool) {
        guard hasActiveStreams else { return }
        if waking {
            for r in runningStreams where statuses[r.id]?.phase.isActive == true {
                appendLog("● Mac woke — recovering the stream…", to: r.id)
            }
        } else {
            playAlert("Funk")
            for r in runningStreams where statuses[r.id]?.phase.isActive == true {
                appendLog("⚠ Mac is going to sleep — stream will be interrupted (a closed lid forces sleep and can't be prevented).", to: r.id)
            }
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

    // MARK: - Named profiles

    private static func loadProfiles() -> [Profile] {
        guard let data = UserDefaults.standard.data(forKey: profilesKey) else { return [] }
        return (try? JSONDecoder().decode([Profile].self, from: data)) ?? []
    }

    private func persistProfiles(_ profiles: [Profile]) {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: Self.profilesKey)
        }
        savedProfileNames = profiles.map(\.name)
    }

    /// Snapshot the current stream setup under `name` (overwrites one with the same name).
    func saveProfile(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var profiles = Self.loadProfiles().filter { $0.name != trimmed }
        profiles.append(Profile(name: trimmed, configs: configs))
        profiles.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        persistProfiles(profiles)
    }

    /// Replace the editable configs with a saved profile. Running streams are unaffected
    /// (they hold their own config snapshots), so this only changes the Configure tab.
    func loadProfile(named name: String) {
        guard let profile = Self.loadProfiles().first(where: { $0.name == name }),
              !profile.configs.isEmpty else { return }
        configs = profile.configs   // didSet persists + syncs previews
    }

    func deleteProfile(named name: String) {
        persistProfiles(Self.loadProfiles().filter { $0.name != name })
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

    /// True when an active stream is struggling: reconnecting, or the encoder is
    /// falling behind real time (speed well under 1x). Drives the "shaky" icon.
    var isTroubled: Bool {
        for record in runningStreams {
            guard let status = statuses[record.id], status.phase.isActive else { continue }
            if case .reconnecting = status.phase { return true }
            if let speed = status.liveSpeed,
               let value = Double(speed.replacingOccurrences(of: "x", with: "")),
               value < 0.8 {
                return true
            }
        }
        return false
    }

    // MARK: - Stream lifecycle

    /// Starts all current configs as new stream instances and appends them to the Live tab.
    func startStreams() {
        stopAllPreviews()   // release devices before the real streams grab them
        let logsDir = logsDirectory()
        let now = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let timestamp = formatter.string(from: now)

        if localPublishEnabled {
            localServer.setPaths(configs.map { (localPathName(for: $0), $0.name) })
            if !localServer.isRunning { localServer.start() }
        }
        for config in configs { launch(config, at: now, timestamp: timestamp) }
        refreshPowerAssertion()   // keep the Mac awake while live
    }

    /// Starts one config as a new running instance. Shared by startStreams and by a
    /// LAN-publish toggle that restarts live streams.
    @discardableResult
    private func launch(_ config: StreamConfig, at now: Date = Date(), timestamp: String? = nil) -> UUID {
        let ts: String
        if let timestamp { ts = timestamp }
        else { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd_HH-mm-ss"; ts = f.string(from: now) }
        let safeName = config.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let logURL = logsDirectory().appendingPathComponent("\(ts)_\(safeName).log")
        let record = RunningStreamRecord(config: config, startedAt: now, logFileURL: logURL)
        runningStreams.append(record)
        statuses[record.id]   = StreamStatus()
        stopFlags[record.id]  = false
        overlayText[record.id] = config.overlay.text
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        logFileHandles[record.id] = FileHandle(forWritingAtPath: logURL.path)
        spawnTask(for: record)
        return record.id
    }

    func stopStream(id: UUID) {
        stopFlags[id] = true
        tasks[id]?.cancel()
        tasks[id] = nil
        registry.terminate(id: id)           // SIGTERM → SIGKILL fallback (clean finalize)
        if let slate = slateProcesses[id] {  // kill fallback slate if it's on-air
            slateProcesses[id] = nil
            if slate.isRunning { slate.terminate() }
            slatePipes.removeValue(forKey: id)?.fileHandleForReading.readabilityHandler = nil
        }
        if statuses[id]?.phase.isActive == true {
            statuses[id]?.phase = .stopped
            appendLog("■ Stream stopped by user.", to: id)
        }
        mutedStreams.remove(id)
        stdinPipes[id] = nil
        destinationOverride[id] = nil
        if tailnetRuns.remove(id) != nil { turboNet.close(id: id.uuidString) }
        closeLogFile(id: id)
        refreshPowerAssertion()   // release the wake-lock if nothing is live
    }

    func stopAll() {
        for record in runningStreams { stopStream(id: record.id) }
    }

    /// Removes finished streams from the Live list AND frees all their per-stream
    /// resources — without this the dictionaries grow unbounded over a long session.
    func clearStopped() {
        let removed = runningStreams.filter { !(statuses[$0.id]?.phase.isActive ?? false) }
        runningStreams.removeAll { !(statuses[$0.id]?.phase.isActive ?? false) }
        for record in removed {
            let id = record.id
            statuses[id]        = nil
            stopFlags[id]       = nil
            lastProgressAt[id]  = nil
            framesSeenThisRun.remove(id)
            logFileHandles[id]?.closeFile()
            logFileHandles[id]  = nil
            slatePipes.removeValue(forKey: id)?.fileHandleForReading.readabilityHandler = nil
            slateProcesses[id]  = nil
            overlayText[id]     = nil
            captureFramerate[id] = nil
            try? FileManager.default.removeItem(at: snapshotPath(for: id))  // free cached frame
            try? FileManager.default.removeItem(at: overlayTextURL(for: id))
        }
    }

    // MARK: - Capture permissions (TCC)

    /// Requests camera access if needed. The app must request this itself so macOS
    /// prompts and records the grant — the bundled ffmpeg subprocess then inherits it.
    /// Enumerating devices works without permission, but *opening* the camera does not.
    @discardableResult
    func ensureCameraAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { c in
                AVCaptureDevice.requestAccess(for: .video) { c.resume(returning: $0) }
            }
        default: return false   // denied / restricted
        }
    }

    @discardableResult
    func ensureMicAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { c in
                AVCaptureDevice.requestAccess(for: .audio) { c.resume(returning: $0) }
            }
        default: return false
        }
    }

    var cameraAccessDenied: Bool {
        let s = AVCaptureDevice.authorizationStatus(for: .video)
        return s == .denied || s == .restricted
    }

    /// AVFoundation rejects any framerate the device doesn't natively support (the
    /// FaceTime camera, for example, does 15/30 only — not 25 or the 29.97 default).
    /// Probe the device's supported framerates and return the one closest to `target`.
    func probeCaptureFramerate(deviceIndex: String, target: Int, preferMax: Bool = false) async -> String {
        // Opening with no framerate fails fast AND prints the supported modes.
        let raw = await runFFmpegCapturingOutput(
            args: ["-hide_banner", "-f", "avfoundation", "-i", deviceIndex])
        var rates = Set<Int>()
        for line in raw.components(separatedBy: "\n") {
            guard let at = line.range(of: "@[") else { continue }
            let after = line[at.upperBound...]
            guard let rb = after.firstIndex(of: "]") else { continue }
            for tok in after[after.startIndex..<rb].split(separator: " ") {
                if let d = Double(tok) { rates.insert(Int(d.rounded())) }
            }
        }
        // "Match source": take the device's highest native rate; otherwise the
        // supported mode closest to the requested target.
        if preferMax, let maxRate = rates.max() { return String(maxRate) }
        guard let best = rates.min(by: { abs($0 - target) < abs($1 - target) }) else {
            return "30"   // sensible default if the device didn't report modes
        }
        return String(best)
    }

    /// Reads the video stream's frame rate from a media file using ffmpeg's input
    /// banner (no full decode). Returns a rounded integer string (e.g. "30", "60"), or nil.
    func probeFileFramerate(path: String) async -> String? {
        guard !path.isEmpty else { return nil }
        let raw = await runFFmpegCapturingOutput(args: ["-hide_banner", "-i", path])
        for line in raw.components(separatedBy: "\n") where line.contains("Video:") {
            // e.g. "..., 30 fps, 30 tbr, ..." — prefer the reported fps, else the tbr.
            if let v = Self.numberBefore(unit: "fps", in: line) { return v }
            if let v = Self.numberBefore(unit: "tbr", in: line) { return v }
        }
        return nil
    }

    /// Finds "<number> <unit>" in `line` and returns the number rounded to an int string.
    private static func numberBefore(unit: String, in line: String) -> String? {
        guard let r = line.range(of: " \(unit)") else { return nil }
        let head  = line[line.startIndex..<r.lowerBound]
        let token = String(head.reversed().prefix(while: { $0.isNumber || $0 == "." }).reversed())
        guard let d = Double(token) else { return nil }
        return String(Int(d.rounded()))
    }

    // MARK: - Device listing

    /// Scans AVFoundation capture devices and populates the published lists.
    func refreshAVDevices() async {
        isScanningDevices = true
        // Trigger the camera prompt while the user is browsing capture devices, so the
        // grant is in place by the time they go live.
        await ensureCameraAccess()
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
        let prevWarning = statuses[id]?.inputWarning
        let sawProgress = statuses[id]?.appendLog(text) ?? false

        if let fh = logFileHandles[id], let data = (text + "\n").data(using: .utf8) {
            fh.write(data)
        }

        if sawProgress {
            lastProgressAt[id] = Date()
            framesSeenThisRun.insert(id)
            // Frames resumed while reconnecting ⇒ we're back. Flip to live + chime.
            if case .reconnecting = statuses[id]?.phase {
                statuses[id]?.phase = .running
                playAlert("Glass")
                let name = runningStreams.first(where: { $0.id == id })?.config.name ?? "Stream"
                streamRecovered(id: id, name: name)
            }
        }

        // New content warning (freeze / black) → soft chime, once per onset
        if let warning = statuses[id]?.inputWarning, warning != prevWarning {
            playAlert("Tink")
        }
    }

    // MARK: - Alerts

    private func playAlert(_ name: NSSound.Name) {
        NSSound(named: name)?.play()
    }

    private func closeLogFile(id: UUID) {
        logFileHandles[id]?.closeFile()
        logFileHandles[id] = nil
    }

    /// A user-domain directory, falling back to the temp dir rather than trapping.
    private func baseDirectory(_ which: FileManager.SearchPathDirectory) -> URL {
        FileManager.default.urls(for: which, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
    }

    private func logsDirectory() -> URL {
        let docs = baseDirectory(.documentDirectory)
        let dir  = docs.appendingPathComponent("TurboStreamer Logs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Private: task spawning

    private func spawnTask(for record: RunningStreamRecord) {
        let id = record.id

        tasks[id] = Task {
            // ── Pre-flight: camera/mic permission + supported framerate for capture ──
            if record.config.inputType == .capture {
                let cam = await ensureCameraAccess()
                if record.config.audioDeviceIndex.isEmpty == false { await ensureMicAccess() }
                appendLog(cam
                    ? "✓ Camera access granted."
                    : "⚠ Camera access denied — enable this app under System Settings → Privacy & Security → Camera, then restart the stream.", to: id)
                let matchSrc = record.config.fpsMatchSource
                let target = Int(record.config.fps) ?? 30
                let chosen = await probeCaptureFramerate(deviceIndex: record.config.videoDeviceIndex, target: target, preferMax: matchSrc)
                captureFramerate[id] = chosen
                appendLog(matchSrc
                    ? "✓ Camera input matching source at \(chosen) fps (device's native rate)."
                    : "✓ Camera input at \(chosen) fps (closest mode the device supports to \(target)).", to: id)
            } else if record.config.inputType == .file, record.config.fpsMatchSource {
                // Pre-resolve the file's native rate once (cached for the whole session).
                let r = await probeFileFramerate(path: record.config.filePath)
                captureFramerate[id] = r ?? record.config.fps
                appendLog("✓ Matching source frame rate: \(r ?? record.config.fps) fps (from file).", to: id)
            } else if record.config.inputType == .decklink {
                let f = record.config.deckLinkFormat
                var line = f == .auto ? "✓ DeckLink: auto-detecting the input format" : "✓ DeckLink input format \(f.label)"
                if record.config.deckLinkConnector != .auto { line += " on \(record.config.deckLinkConnector.label)" }
                line += record.config.deckLinkTenBit ? ", 10-bit" : ", 8-bit"
                if record.config.fpsMatchSource {
                    line += f.fps.map { " — matching source at \($0) fps" }
                        ?? " — Match source needs an explicit Format, encoding at \(record.config.fps) fps"
                }
                appendLog(line + ".", to: id)
            }

            // ── Pre-flight: pick the transport. ──
            // Automatic pairing runs the full ladder (direct → relay-SRT → relay-RTMP) and
            // reports its choice so the receiver aligns. Otherwise the single configured
            // destination is probed, with the relay's RTMP door as a fallback.
            if record.config.autoPair {
                await resolveAutoTransport(record)
            } else {
            // SRT is UDP, which venue and hotel networks block more often than TCP. If the
            // relay was chosen it also has an RTMP door, so the stream moves there by itself.
            let destURL = record.config.rtmpURL
            destinationOverride[id] = nil
            tailnetRuns.remove(id)
            // A 100.64/10 destination lives on the Turbo network: reachable only through
            // this app's own node, so ffmpeg is pointed at a local port that the helper
            // carries to the peer. Smaller packets there: the tunnel's MTU is 1280.
            if let (host, port) = Self.srtHostPort(destURL), TurboNet.isTailnetAddress(host) {
                if let local = await turboNet.dial(id: id.uuidString, to: "\(host):\(port)") {
                    destinationOverride[id] = ("srt://\(local)", record.config.streamKey)
                    tailnetRuns.insert(id)
                    appendLog("🕸 \(host) is on the Turbo network — tunnelling through \(local).", to: id)
                } else {
                    appendLog("⚠ Turbo network tunnel to \(host) couldn't be opened (\(turboNet.state)) — trying the address as is.", to: id)
                }
            }
            let probeURL = destinationOverride[id]?.url ?? destURL
            appendLog("⏳ Pre-flight: checking \(destURL)…", to: id)
            if destURL.lowercased().hasPrefix("srt://") {
                if await probeSRT(probeURL) {
                    appendLog("✓ SRT destination answers — UDP path is open.", to: id)
                    statuses[id]?.transportWarning = nil
                } else if !record.config.altRTMPURL.isEmpty {
                    tailnetRuns.remove(id)
                    destinationOverride[id] = (record.config.altRTMPURL, record.config.altStreamKey)
                    appendLog("⚠ SRT (UDP) to \(destURL) is blocked or unreachable from this network — sending RTMP to the relay instead: \(record.config.altRTMPURL).", to: id)
                    statuses[id]?.transportWarning = "SRT (UDP) blocked — on RTMP fallback (higher latency, H.264 only)"
                } else {
                    appendLog("⚠ SRT destination not answering — UDP may be blocked here, or the receiver isn't up. Will keep retrying; linking through the relay gives an RTMP fallback.", to: id)
                }
            } else {
                let reachable = await Preflight.isReachable(destURL)
                appendLog(reachable
                    ? "✓ Destination reachable."
                    : "⚠ Destination not reachable yet — will keep retrying once started.", to: id)
            }
            }  // end manual (non-autoPair) pre-flight

            var attempt = 0
            var consecutiveFailures = 0
            let originalKbps = Self.kbps(record.config.videoBitrate)
            var currentKbps  = originalKbps

            while !Task.isCancelled {
                guard stopFlags[id] == false else { break }

                attempt += 1
                statuses[id]?.phase = attempt == 1 ? .running : .reconnecting(attempt: attempt)
                let bitrate = "\(currentKbps)k"
                appendLog("▶ Starting (attempt \(attempt)) at \(bitrate)…", to: id)

                let startedAt = Date()
                lastProgressAt[id] = Date()
                framesSeenThisRun.remove(id)
                let exitCode = await runFFmpeg(record: record, bitrate: bitrate)
                let ranFor   = Date().timeIntervalSince(startedAt)
                let connected = framesSeenThisRun.contains(id)

                if Task.isCancelled || stopFlags[id] == true { break }

                if exitCode == 0 {
                    appendLog("✓ Stream ended cleanly.", to: id)
                    statuses[id]?.phase = .stopped
                    break
                }

                // ── Adaptive bitrate ────────────────────────────────────────
                // Only a run that actually pushed frames says anything about the link. A
                // refused or unanswered connection is not congestion: lowering the bitrate
                // can't reach a host that isn't there, and would bring the stream back at
                // half quality once it is.
                if record.config.adaptiveBitrate {
                    if !connected {
                        appendLog("↻ Connection not established — bitrate stays at \(currentKbps)k.", to: id)
                    } else if ranFor < 20, currentKbps > Self.floorKbps(originalKbps) {
                        currentKbps = max(Self.floorKbps(originalKbps), currentKbps * 7 / 10)
                        appendLog("📉 Unstable — lowering bitrate to \(currentKbps)k.", to: id)
                    } else if ranFor > 120, currentKbps < originalKbps {
                        currentKbps = min(originalKbps, currentKbps * 13 / 10)
                        appendLog("📈 Stable — raising bitrate to \(currentKbps)k.", to: id)
                    }
                }

                // ── Reconnect with exponential backoff ──────────────────────
                if ranFor > Self.healthyRunSeconds { consecutiveFailures = 0 } else { consecutiveFailures += 1 }
                let delay = Self.backoffDelay(consecutiveFailures)

                statuses[id]?.phase = .reconnecting(attempt: attempt + 1)
                appendLog("⚠ Disconnected (exit \(exitCode)) — reconnecting in \(delay) s…", to: id)
                playAlert("Basso")
                if ranFor > Self.healthyRunSeconds {   // a healthy stream dropped (not initial-connect retries)
                    streamDropped(id: id, name: record.config.name)
                }

                // ── Fallback slate: keep the channel on-air during the gap ──
                let useSlate = record.config.fallbackEnabled
                if useSlate {
                    startSlate(for: record, bitrate: bitrate)
                    appendLog("▣ Showing fallback (recent frame) on-air…", to: id)
                }

                var waited = 0
                while waited < delay {
                    if Task.isCancelled || stopFlags[id] == true { break }
                    try? await Task.sleep(for: .seconds(1))
                    waited += 1
                }

                if useSlate { await stopSlate(id: id) }   // release RTMP before relaunching live
            }

            await stopSlate(id: id)
            if statuses[id]?.phase.isActive == true { statuses[id]?.phase = .stopped }
            lastProgressAt[id] = nil
            framesSeenThisRun.remove(id)
            droppedStreams.remove(id)
            mutedStreams.remove(id)
            stdinPipes[id] = nil
            closeLogFile(id: id)
            refreshPowerAssertion()   // release the wake-lock if this was the last live stream
        }
    }

    /// Parse a bitrate string like "5872k" → 5872 (kbps).
    static func kbps(_ s: String) -> Int {
        Int(s.lowercased().replacingOccurrences(of: "k", with: "")) ?? 4500
    }
    /// Lowest bitrate adaptive mode will drop to.
    static func floorKbps(_ original: Int) -> Int { max(800, original / 4) }

    /// Exponential backoff ladder for reconnect delays (seconds).
    static func backoffDelay(_ consecutiveFailures: Int) -> Int {
        let ladder = [1, 2, 4, 8, 15]
        return ladder[min(max(consecutiveFailures - 1, 0), ladder.count - 1)]
    }

    // MARK: - Webhook alerts

    /// A run longer than this counts as a "healthy" stream — used both to reset the
    /// reconnect backoff and to decide a real drop (vs. initial-connect flapping).
    static let healthyRunSeconds: TimeInterval = 30

    private struct AlertPayload: Encodable {
        let app = "Turbo Streamer"
        let event: String
        let stream: String
        let message: String
        let time: String
    }
    private static let iso8601 = ISO8601DateFormatter()

    /// The configured webhook as a validated http(s) URL with a host, or nil.
    private func webhookURL() -> URL? {
        let raw = alertWebhookURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host?.isEmpty == false
        else { return nil }
        return url
    }

    private static func alertRequest(_ url: URL, event: String, stream: String, message: String) -> URLRequest? {
        let payload = AlertPayload(event: event, stream: stream, message: message,
                                   time: iso8601.string(from: Date()))
        guard let body = try? JSONEncoder().encode(payload) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        return req
    }

    /// A healthy stream went down — alert once per outage episode (idempotent on the id).
    private func streamDropped(id: UUID, name: String) {
        guard droppedStreams.insert(id).inserted else { return }
        sendWebhookAlert(event: "drop", streamName: name, message: "Stream went offline — reconnecting.")
    }

    /// Frames resumed — alert only if we sent a matching drop, then clear the pairing.
    private func streamRecovered(id: UUID, name: String) {
        guard droppedStreams.remove(id) != nil else { return }
        sendWebhookAlert(event: "recover", streamName: name, message: "Stream is back online.")
    }

    /// Fire-and-forget POST for drop/recover. Never blocks or affects the stream: a
    /// detached task does the request and swallows every error. No-op if the URL is empty
    /// or not http(s). (URLSession.shared caps connections per host, so an alert burst
    /// can't fan out unbounded.)
    func sendWebhookAlert(event: String, streamName: String, message: String) {
        guard let url = webhookURL(),
              let req = Self.alertRequest(url, event: event, stream: streamName, message: message)
        else { return }
        Task.detached { _ = try? await URLSession.shared.data(for: req) }
    }

    /// Sends a one-off test payload and reports the outcome in `alertTestResult`, so the
    /// user can actually confirm their webhook wiring (instead of a silent no-op).
    func sendTestAlert() {
        guard let url = webhookURL() else {
            alertTestResult = "✗ Not a valid http(s):// URL"
            return
        }
        guard let req = Self.alertRequest(url, event: "test", stream: "Test",
                                          message: "Test alert from Turbo Streamer — your webhook works!") else {
            alertTestResult = "✗ Couldn't build the message"
            return
        }
        alertTestResult = "⏳ Sending…"
        Task {
            do {
                let (_, resp) = try await URLSession.shared.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                alertTestResult = (200..<300).contains(code)
                    ? "✓ Delivered — your webhook replied \(code)"
                    : "⚠ Reached the server, but it replied \(code)"
            } catch {
                alertTestResult = "✗ Failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Private: process execution

    private func runFFmpeg(record: RunningStreamRecord, bitrate: String) async -> Int32 {
        let id     = record.id
        let config = record.config
        let recordingURL = config.safetyRecording ? makeRecordingURL(for: config) : nil
        let snapURL      = config.fallbackEnabled ? snapshotPath(for: id) : nil

        // Overlay: write the *current* (possibly live-edited) text to the reload file
        // each launch, so a reconnect preserves whatever is on-air rather than resetting.
        var overlayURL: URL? = nil
        if config.overlay.enabled {
            let url = overlayTextURL(for: id)
            let text = overlayText[id] ?? config.overlay.text
            try? text.write(to: url, atomically: true, encoding: .utf8)
            overlayURL = url
        }

        let outputFPS = resolvedOutputFPS(for: config, captureFPS: captureFramerate[id])
        let codec = resolveCodec(for: config,
                                 fps: Int((Double(outputFPS) ?? 30).rounded()),
                                 isSRT: config.rtmpURL.lowercased().hasPrefix("srt://"))
        appendLog("✓ Encoder: \(codec.label) · \(config.resolution.rawValue) · \(outputFPS) fps · \(bitrate).", to: id)
        let args = buildArgs(for: config, recordingURL: recordingURL,
                             bitrateOverride: bitrate, snapshotURL: snapURL,
                             overlayTextURL: overlayURL, captureFPS: captureFramerate[id],
                             outputFPS: outputFPS, muted: mutedStreams.contains(id),
                             destination: destinationOverride[id],
                             pktSize: tailnetRuns.contains(id) ? 1200 : 1316)

        if let rec = recordingURL {
            appendLog("● Safety recording → \(rec.path)", to: id)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments     = args
        // stdin stays open as a pipe so we can send runtime filter commands (mute/unmute).
        let stdinPipe = Pipe()
        process.standardInput = stdinPipe
        stdinPipes[id] = stdinPipe

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

        // ── Hang watchdog: if no video frames arrive for `hangTimeout`, the input
        // is stalled (capture unplugged, source frozen, RTMP stuck) — kill it so the
        // reconnect loop relaunches and re-acquires the device. Process-matched so a
        // stale watchdog can never kill a freshly-relaunched successor.
        let watchdog = Task { @MainActor [weak self, weak process] in
            guard let self, let process else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                if Task.isCancelled { break }
                let last = self.lastProgressAt[id] ?? Date()
                if Date().timeIntervalSince(last) > self.hangTimeout {
                    self.appendLog("⏱ No frames for \(Int(self.hangTimeout)) s — input stalled. Restarting…", to: id)
                    self.registry.terminate(id: id, ifMatches: process)   // → terminationHandler → reconnect
                    break
                }
            }
        }

        return await withCheckedContinuation { continuation in

            // Drain stdout+stderr ONLY through the readability handler. The termination
            // handler must never do a blocking read on the same handle (that races the
            // handler → crash, and can block forever → hang). An empty Data == EOF.
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty,
                      let text = String(data: data, encoding: .utf8) else { return }
                Task { @MainActor [weak self] in
                    self?.appendLog(text, to: id)
                }
            }

            process.terminationHandler = { [registry] p in
                watchdog.cancel()
                p.terminationHandler = nil
                pipe.fileHandleForReading.readabilityHandler = nil   // release the dispatch source / FD
                registry.remove(id: id, ifMatches: p)
                continuation.resume(returning: p.terminationStatus)
            }

            do {
                try process.run()
            } catch {
                watchdog.cancel()
                pipe.fileHandleForReading.readabilityHandler = nil
                registry.remove(id: id, ifMatches: process)
                Task { @MainActor [weak self] in
                    self?.appendLog("✗ Failed to launch ffmpeg: \(error.localizedDescription)", to: id)
                }
                continuation.resume(returning: -2)
            }
        }
    }

    private func makeRecordingURL(for config: StreamConfig) -> URL {
        let docs = baseDirectory(.documentDirectory)
        let dir  = docs.appendingPathComponent("TurboStreamer Recordings")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let safe = config.name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return dir.appendingPathComponent("\(fmt.string(from: Date()))_\(safe).ts")
    }

    // MARK: - Private: fallback slate

    /// Streams the configured fallback media (looped) to the primary destination,
    /// keeping the channel on-air while the live input is down.
    private func startSlate(for record: RunningStreamRecord, bitrate: String) {
        let id = record.id
        guard slateProcesses[id] == nil else { return }

        // Resolve what to show, in priority order:
        //   1. a custom card the user picked
        //   2. the most recent frame captured from the live feed
        //   3. solid black (so the channel is never dead air)
        let custom = record.config.fallbackMediaPath
        let snap   = snapshotPath(for: id).path
        let source: String?
        if !custom.isEmpty, FileManager.default.fileExists(atPath: custom) {
            source = custom
        } else if FileManager.default.fileExists(atPath: snap) {
            source = snap
        } else {
            source = nil   // black
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        let slateFPS = resolvedOutputFPS(for: record.config, captureFPS: captureFramerate[record.id])
        process.arguments     = buildSlateArgs(for: record.config, bitrate: bitrate, sourcePath: source, outputFPS: slateFPS, destination: destinationOverride[record.id], pktSize: tailnetRuns.contains(record.id) ? 1200 : 1316)
        process.standardInput = FileHandle.nullDevice

        let libDir = URL(fileURLWithPath: ffmpegPath)
            .deletingLastPathComponent().appendingPathComponent("lib").path
        if FileManager.default.fileExists(atPath: libDir) {
            var env = ProcessInfo.processInfo.environment
            let existing = env["DYLD_LIBRARY_PATH"] ?? ""
            env["DYLD_LIBRARY_PATH"] = existing.isEmpty ? libDir : "\(libDir):\(existing)"
            process.environment = env
        }

        let sink = Pipe()
        process.standardOutput = sink
        process.standardError  = sink
        sink.fileHandleForReading.readabilityHandler = { h in _ = h.availableData }   // drain & discard

        do {
            try process.run()
            slateProcesses[id] = process
            slatePipes[id]     = sink
        } catch {
            appendLog("⚠ Could not start fallback slate: \(error.localizedDescription)", to: id)
        }
    }

    /// Stops the slate and waits (bounded) for it to release the RTMP connection,
    /// escalating to SIGKILL so a wedged slate can never park the reconnect loop.
    private func stopSlate(id: UUID) async {
        guard let process = slateProcesses[id] else { return }
        slateProcesses[id] = nil
        let pipe = slatePipes.removeValue(forKey: id)

        if process.isRunning { process.terminate() }
        let pid = process.processIdentifier

        // Wait up to ~3s for clean exit, then force-kill.
        for _ in 0 ..< 30 {
            if !process.isRunning { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        if process.isRunning { kill(pid, SIGKILL) }

        pipe?.fileHandleForReading.readabilityHandler = nil   // release dispatch source / FD
    }

    private func buildSlateArgs(for config: StreamConfig, bitrate: String, sourcePath: String?, outputFPS: String? = nil, destination: (url: String, key: String)? = nil, pktSize: Int = 1316) -> [String] {
        let (w, h) = config.resolution.outputDimensions
        let fps    = outputFPS ?? config.fps
        let kbps   = Self.kbps(bitrate)

        var args = ["-hide_banner", "-y", "-loglevel", "error"]
        let videoFilter: String

        if let path = sourcePath {
            let ext = (path as NSString).pathExtension.lowercased()
            let isImage = ["png", "jpg", "jpeg", "gif", "bmp", "heic", "tiff", "webp"].contains(ext)
            if isImage {
                args += ["-loop", "1", "-framerate", fps, "-i", path]
            } else {
                args += ["-stream_loop", "-1", "-re", "-i", path]
            }
            videoFilter = "[0:v]scale=\(w):\(h):force_original_aspect_ratio=decrease,pad=\(w):\(h):(ow-iw)/2:(oh-ih)/2,fps=\(fps),format=yuv420p[v]"
        } else {
            args += ["-f", "lavfi", "-i", "color=c=black:s=\(w)x\(h):rate=\(fps)"]
            videoFilter = "[0:v]format=yuv420p[v]"
        }

        args += ["-f", "lavfi", "-i", "anullsrc=channel_layout=stereo:sample_rate=48000"]
        args += [
            "-filter_complex", videoFilter,
            "-map", "[v]", "-map", "1:a",
            "-c:v", "libx264", "-preset", "veryfast", "-profile:v", "high", "-pix_fmt", "yuv420p",
            "-b:v", bitrate, "-maxrate", bitrate, "-bufsize", "\(kbps * 2)k",
            "-g", "\((Int(fps) ?? 30) * 2)", "-tune", "zerolatency",
            "-c:a", "aac", "-b:a", "128k", "-ar", "48000", "-ac", "2",
        ]
        args += primaryOutputArgs(url: destination?.url ?? config.rtmpURL,
                                  key: destination?.key ?? config.streamKey,
                                  latencyMs: config.srtLatencyMs, pktSize: pktSize)
        return args
    }

    /// host and port of an srt:// URL (default port 8890), nil for anything else.
    static func srtHostPort(_ url: String) -> (String, Int)? {
        guard url.lowercased().hasPrefix("srt://"),
              let c = URLComponents(string: url.trimmingCharacters(in: .whitespaces)),
              let h = c.host, !h.isEmpty else { return nil }
        return (h, c.port ?? 8890)
    }

    /// The output half of a command line, for the main stream and the slate alike. An SRT
    /// destination needs MPEG-TS and the path in `-srt_streamid` (ffmpeg ignores a streamid
    /// in the URL query); everything else is FLV to "url/key".
    private func primaryOutputArgs(url: String, key: String, latencyMs: Int, pktSize: Int = 1316) -> [String] {
        guard url.lowercased().hasPrefix("srt://") else {
            return ["-f", "flv", "\(url)/\(key)"]
        }
        return ["-f", "mpegts",
                "-srt_streamid", "publish:\(key)",
                "-pkt_size", "\(pktSize)",
                "-latency", "\(max(20, latencyMs) * 1000)",
                url]
    }

    /// Tee slaves. The primary keeps the default onfail=abort (a primary drop ends ffmpeg
    /// and triggers reconnect); backup and recording use onfail=ignore.
    private func teeTargets(dest: String, backup: String, recordingURL: URL?, local: String? = nil) -> [String] {
        var targets = ["[f=flv]\(dest)"]
        if !backup.isEmpty        { targets.append("[f=flv:onfail=ignore]\(backup)") }
        if let local              { targets.append("[f=flv:onfail=ignore]\(local)") }
        if let rec = recordingURL { targets.append("[f=mpegts:onfail=ignore]\(rec.path)") }
        return targets
    }

    /// Stable per-stream path where the live feed's most recent frame is dumped.
    private func snapshotPath(for id: UUID) -> URL {
        let dir = baseDirectory(.cachesDirectory)
            .appendingPathComponent("TurboStreamer")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("latest_\(id.uuidString).jpg")
    }

    // MARK: - Text overlay

    /// Per-stream text file that drawtext re-reads live (reload=1).
    private func overlayTextURL(for id: UUID) -> URL {
        let dir = baseDirectory(.cachesDirectory).appendingPathComponent("TurboStreamer")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("overlay_\(id.uuidString).txt")
    }

    /// Resolve an overlay's font to an absolute file path (bundled or custom).
    func fontPath(for overlay: TextOverlay) -> String? {
        if overlay.fontChoice == TextOverlay.customFontLabel {
            let p = overlay.customFontPath
            return (!p.isEmpty && FileManager.default.fileExists(atPath: p)) ? p : nil
        }
        guard let match = TextOverlay.bundledFonts.first(where: { $0.name == overlay.fontChoice })
            ?? TextOverlay.bundledFonts.first else { return nil }
        let p = Bundle.main.bundlePath + "/Contents/Resources/Fonts/" + match.file
        return FileManager.default.fileExists(atPath: p) ? p : nil
    }

    /// Build the drawtext filter from overlay settings, reading text from `textPath`.
    private func drawtextFilter(for overlay: TextOverlay, textPath: String) -> String? {
        guard overlay.enabled, let font = fontPath(for: overlay) else { return nil }
        let size  = max(8, overlay.fontSize)
        let hex   = overlay.colorHex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var f = "drawtext=textfile='\(textPath)':reload=1"
        f += ":fontfile='\(font)'"
        f += ":fontcolor=0x\(hex.isEmpty ? "FFFFFF" : hex)"
        f += ":fontsize=\(size)"
        f += ":x=(w-text_w)/2:y=\(overlay.position.yExpr)"
        f += ":line_spacing=10"
        if overlay.boxEnabled {
            let op = String(format: "%.2f", min(max(overlay.boxOpacity, 0), 1))
            f += ":box=1:boxcolor=black@\(op):boxborderw=28"
        }
        return f
    }

    /// Update the on-air overlay text live (drawtext picks it up within a frame).
    // MARK: - Live audio mute

    /// Toggles the outgoing audio of a live stream, live and gap-free: ffmpeg accepts
    /// runtime filter commands on stdin, so this just gives the `volume` filter a new
    /// value — nothing is restarted and the video is untouched. `mutedStreams` also seeds
    /// the filter's initial value in buildArgs, so a reconnect comes back muted if it was.
    func toggleMute(id: UUID) {
        guard statuses[id]?.phase.isActive == true else { return }
        if let c = runningStreams.first(where: { $0.id == id })?.config,
           c.inputType == .network, c.networkPassthrough {
            appendLog("🔇 Mute isn't available in passthrough — nothing is re-encoded here. Mute at the source.", to: id)
            return
        }
        let nowMuted = !mutedStreams.contains(id)
        if nowMuted { mutedStreams.insert(id) } else { mutedStreams.remove(id) }
        sendFilterCommand("volume -1 volume \(nowMuted ? "0" : "1")", to: id)
        appendLog(nowMuted ? "🔇 Audio muted." : "🔊 Audio unmuted.", to: id)
    }

    /// Sends one runtime filter command to a running ffmpeg over its stdin.
    /// Format: `c<target> <time|-1> <command> <argument>` (ffmpeg interactive mode).
    private func sendFilterCommand(_ command: String, to id: UUID) {
        guard let handle = stdinPipes[id]?.fileHandleForWriting,
              let data = "c\(command)\n".data(using: .utf8) else { return }
        try? handle.write(contentsOf: data)   // SIGPIPE ignored; a dead pipe just fails
    }

    func setOverlayText(_ text: String, for id: UUID) {
        overlayText[id] = text
        try? text.write(to: overlayTextURL(for: id), atomically: true, encoding: .utf8)
    }

    // MARK: - Debug logging

    private static let dbgFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f
    }()
    private func debugLogURL() -> URL { logsDirectory().appendingPathComponent("preview-debug.log") }
    func dlog(_ msg: String) {
        let line = "[\(Self.dbgFmt.string(from: Date()))] \(msg)\n"
        guard let data = line.data(using: .utf8) else { return }
        let url = debugLogURL()
        if let fh = try? FileHandle(forWritingTo: url) {
            fh.seekToEndOfFile(); fh.write(data); try? fh.close()
        } else {
            try? data.write(to: url)
        }
    }

    // MARK: - Live preview (local, never streamed)

    /// Where each config's running preview frames are written (overwritten ~12×/sec).
    func previewImageURL(for configID: UUID) -> URL {
        baseDirectory(.cachesDirectory)
            .appendingPathComponent("TurboStreamer", isDirectory: true)
            .appendingPathComponent("preview_\(configID.uuidString).jpg")
    }
    private func previewOverlayURL(for configID: UUID) -> URL {
        baseDirectory(.cachesDirectory)
            .appendingPathComponent("TurboStreamer", isDirectory: true)
            .appendingPathComponent("previewovl_\(configID.uuidString).txt")
    }

    func isPreviewing(_ id: UUID) -> Bool { previewing.contains(id) }
    var anyPreviewing: Bool { !previewing.isEmpty }

    /// Start a live local preview of the composed output (source + overlay), no RTMP.
    func startPreview(for config: StreamConfig) async {
        let id = config.id
        let short = String(id.uuidString.prefix(8))
        guard previewProcesses[id] == nil else {
            dlog("startPreview[\(short)] SKIPPED — process already exists")
            return
        }
        dlog("startPreview[\(short)] BEGIN  input=\(config.inputType.rawValue) overlay=\(config.overlay.enabled) size=\(config.overlay.fontSize) color=\(config.overlay.colorHex)")

        try? FileManager.default.createDirectory(
            at: baseDirectory(.cachesDirectory).appendingPathComponent("TurboStreamer"),
            withIntermediateDirectories: true)
        try? config.overlay.text.write(to: previewOverlayURL(for: id), atomically: true, encoding: .utf8)

        var camFps = captureFramerate[id] ?? "30"
        if config.inputType == .capture, captureFramerate[id] == nil {
            await ensureCameraAccess()
            camFps = await probeCaptureFramerate(deviceIndex: config.videoDeviceIndex, target: Int(config.fps) ?? 30, preferMax: config.fpsMatchSource)
            captureFramerate[id] = camFps
            dlog("startPreview[\(short)] probed camFps=\(camFps)")
        }
        if previewProcesses[id] != nil {
            dlog("startPreview[\(short)] ABORT after await — process appeared")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        let pargs = buildPreviewArgs(for: config, captureFPS: camFps)
        process.arguments     = pargs
        process.standardInput = FileHandle.nullDevice
        if let env = subprocessEnvironment() { process.environment = env }
        dlog("startPreview[\(short)] ARGS: \(pargs.joined(separator: " "))")

        let sink = Pipe()
        process.standardOutput = sink
        process.standardError  = sink
        sink.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, let self else { return }
            Task { @MainActor in self.dlog("  preview[\(short)] ffmpeg: \(t)") }
        }
        process.terminationHandler = { [weak self] p in
            let code = p.terminationStatus
            guard let self else { return }
            Task { @MainActor in self.dlog("  preview[\(short)] EXITED code=\(code)") }
        }

        do {
            try process.run()
            previewProcesses[id] = process
            previewPipes[id]     = sink
            previewing.insert(id)
            dlog("startPreview[\(short)] LAUNCHED pid=\(process.processIdentifier)")
        } catch {
            dlog("startPreview[\(short)] LAUNCH FAILED: \(error.localizedDescription)")
        }
    }

    func stopPreview(_ id: UUID) {
        let short = String(id.uuidString.prefix(8))
        dlog("stopPreview[\(short)]")
        previewRestartTasks[id]?.cancel(); previewRestartTasks[id] = nil
        if let p = previewProcesses[id] {
            previewProcesses[id] = nil
            if p.isRunning { p.terminate() }
        }
        previewPipes.removeValue(forKey: id)?.fileHandleForReading.readabilityHandler = nil
        previewing.remove(id)
        captureFramerate[id] = nil
        try? FileManager.default.removeItem(at: previewImageURL(for: id))
    }

    func stopAllPreviews() {
        for id in Array(previewing) { stopPreview(id) }
    }

    /// Re-render the running preview (debounced) when something baked into the filter
    /// changes — font/size/colour/position/resolution/source. Keeps the preview "live".
    func restartPreviewDebounced(for config: StreamConfig) {
        let id = config.id
        let short = String(id.uuidString.prefix(8))
        guard previewing.contains(id) else {
            dlog("restartDebounced[\(short)] IGNORED — not previewing")
            return
        }
        dlog("restartDebounced[\(short)] scheduled (size=\(config.overlay.fontSize) color=\(config.overlay.colorHex))")
        previewRestartTasks[id]?.cancel()
        previewRestartTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard let self else { return }
            if Task.isCancelled { self.dlog("restart[\(short)] cancelled before kill"); return }
            guard self.previewing.contains(id) else { self.dlog("restart[\(short)] not previewing"); return }
            if let p = self.previewProcesses[id] {
                self.previewProcesses[id] = nil
                self.dlog("restart[\(short)] terminating old pid=\(p.processIdentifier) running=\(p.isRunning)")
                if p.isRunning { p.terminate() }
                var waited = 0
                for _ in 0 ..< 60 {
                    if !p.isRunning { break }
                    try? await Task.sleep(for: .milliseconds(50)); waited += 50
                }
                self.dlog("restart[\(short)] old exited after \(waited)ms, running=\(p.isRunning)")
            } else {
                self.dlog("restart[\(short)] no old process tracked")
            }
            self.previewPipes.removeValue(forKey: id)?.fileHandleForReading.readabilityHandler = nil
            self.captureFramerate[id] = nil
            if Task.isCancelled { self.dlog("restart[\(short)] cancelled before relaunch"); return }
            guard self.previewing.contains(id) else { self.dlog("restart[\(short)] not previewing before relaunch"); return }
            self.dlog("restart[\(short)] relaunching…")
            await self.startPreview(for: config)
        }
    }

    /// Live-update the preview's overlay text (drawtext reload picks it up).
    func updatePreviewOverlayText(_ text: String, for configID: UUID) {
        guard previewing.contains(configID) else { return }
        try? text.write(to: previewOverlayURL(for: configID), atomically: true, encoding: .utf8)
    }

    /// Everything baked into the preview render (excludes overlay text, which reloads live).
    private func previewStyleSignature(_ c: StreamConfig?) -> String {
        guard let c else { return "" }
        let o = c.overlay
        return [c.resolution.rawValue, c.inputType.rawValue, c.filePath, c.networkURL, c.videoDeviceIndex,
                c.deckLinkDeviceName, "\(o.enabled)", o.fontChoice, o.customFontPath, "\(o.fontSize)",
                o.colorHex, o.position.rawValue, "\(o.boxEnabled)", String(format: "%.2f", o.boxOpacity)]
            .joined(separator: "|")
    }

    /// Whenever a config is edited, push the change into its running preview:
    /// text reloads instantly; anything baked into the filter triggers a re-render.
    /// Driven from configs.didSet so it fires reliably on every edit.
    private func syncPreviewsToConfigChanges(old: [StreamConfig]) {
        guard !previewing.isEmpty else { return }
        dlog("configs.didSet — previewing=\(previewing.map { String($0.uuidString.prefix(8)) })")
        for id in previewing {
            let short = String(id.uuidString.prefix(8))
            guard let newC = configs.first(where: { $0.id == id }) else {
                dlog("  sync[\(short)]: config gone"); continue
            }
            let oldC = old.first(where: { $0.id == id })
            let textChanged = newC.overlay.text != (oldC?.overlay.text ?? "")
            let oldSig = previewStyleSignature(oldC)
            let newSig = previewStyleSignature(newC)
            let styleChanged = oldSig != newSig
            dlog("  sync[\(short)]: textChanged=\(textChanged) styleChanged=\(styleChanged)")
            // Text applies live (drawtext reload). Style/source changes apply only when
            // the user clicks "Refresh Preview" — avoids re-opening the camera on every tweak.
            if textChanged { updatePreviewOverlayText(newC.overlay.text, for: id) }
            _ = (oldSig, newSig, styleChanged)
        }
    }

    /// Re-render every running preview with the latest settings (the Refresh Preview button).
    func refreshAllPreviews() {
        for id in Array(previewing) {
            guard let config = configs.first(where: { $0.id == id }) else { continue }
            dlog("refreshAllPreviews → restart \(String(id.uuidString.prefix(8)))")
            restartPreviewDebounced(for: config)
        }
    }

    private func buildPreviewArgs(for config: StreamConfig, captureFPS: String) -> [String] {
        // -y: overwrite the preview JPEG without prompting. Without it, a restart finds
        // the file already there, ffmpeg asks "Overwrite? [y/N]", answers no, and exits
        // immediately → frozen preview.
        var a = ["-hide_banner", "-y", "-loglevel", "error"]
        switch config.inputType {
        case .file where !config.filePath.isEmpty:
            a += ["-re", "-stream_loop", "-1", "-i", config.filePath]
        case .decklink where !config.deckLinkDeviceName.isEmpty:
            a += deckLinkInputOptions(for: config) + ["-i", config.deckLinkDeviceName]
        case .capture:
            a += ["-f", "avfoundation", "-framerate", captureFPS, "-i", "\(config.videoDeviceIndex):none"]
        case .network where !config.networkURL.isEmpty:
            a += networkInputArgs(for: config)
        default:
            let (w, h) = config.resolution.outputDimensions
            a += ["-f", "lavfi", "-i", "color=c=0x1a1a1a:s=\(w)x\(h):rate=12"]
        }
        var vf = config.resolution.scaleFilter
        if config.overlay.enabled,
           let dt = drawtextFilter(for: config.overlay, textPath: previewOverlayURL(for: config.id).path) {
            vf += ",\(dt)"
        }
        vf += ",fps=12,scale=960:-2"   // downscale: previews stay light
        a += ["-an", "-vf", vf, "-q:v", "6", "-update", "1", "-f", "image2", previewImageURL(for: config.id).path]
        return a
    }

    /// DYLD env so the bundled ffmpeg finds its dylibs (shared by all spawns).
    private func subprocessEnvironment() -> [String: String]? {
        let libDir = URL(fileURLWithPath: ffmpegPath)
            .deletingLastPathComponent().appendingPathComponent("lib").path
        guard FileManager.default.fileExists(atPath: libDir) else { return nil }
        var env = ProcessInfo.processInfo.environment
        let existing = env["DYLD_LIBRARY_PATH"] ?? ""
        env["DYLD_LIBRARY_PATH"] = existing.isEmpty ? libDir : "\(libDir):\(existing)"
        return env
    }

    // MARK: - Private: argument builder

    /// The numeric framerate to encode at. With "Match source", this is the source's
    /// native rate, pre-resolved into `captureFPS` during pre-flight (capture: probed
    /// device rate; file: parsed from the media). Falls back to the user's `fps` value.
    /// Automatic pairing: run the transport ladder best-first (direct SRT → relay SRT →
    /// relay RTMP), pick the first that works, set the destination, and report the choice to
    /// the rendezvous so the receiver aligns. Every fallback is announced and badged.
    private func resolveAutoTransport(_ record: RunningStreamRecord) async {
        let id = record.id, c = record.config
        destinationOverride[id] = nil
        tailnetRuns.remove(id)
        turboNet.close(id: id.uuidString)

        func report(_ mode: String, _ detail: String) async {
            guard !c.pairCode.isEmpty, !c.pairSecret.isEmpty else { return }
            await LinkClient.reportTransport(code: c.pairCode, secret: c.pairSecret, mode: mode, detail: detail)
        }

        // 1. Direct to the receiver (best: low latency, HEVC). Tunnel a 100.x through the
        //    Turbo network; probe reachability before committing.
        if !c.pairDirectURL.isEmpty, let (host, port) = Self.srtHostPort(c.pairDirectURL) {
            var probeURL = c.pairDirectURL
            var tunnelLocal: String? = nil
            if TurboNet.isTailnetAddress(host) {
                if let local = await turboNet.dial(id: id.uuidString, to: "\(host):\(port)") {
                    tunnelLocal = local; probeURL = "srt://\(local)"
                }
            }
            if await probeSRT(probeURL) {
                destinationOverride[id] = (tunnelLocal.map { "srt://\($0)" } ?? c.pairDirectURL, c.pairDirectKey)
                if tunnelLocal != nil { tailnetRuns.insert(id) }
                statuses[id]?.transportWarning = nil
                appendLog("✓ Direct path to the receiver is open — best quality (SRT\(tunnelLocal != nil ? " over the Turbo network" : "")).", to: id)
                await report("direct", tunnelLocal != nil ? "direct (Turbo network)" : "direct")
                return
            }
            if tunnelLocal != nil { turboNet.close(id: id.uuidString); tailnetRuns.remove(id) }
            appendLog("• Direct path not reachable — trying the relay.", to: id)
        }

        // 2. Relay over SRT (still low latency, HEVC).
        if !c.pairRelaySRTURL.isEmpty, await probeSRT(c.pairRelaySRTURL) {
            destinationOverride[id] = (c.pairRelaySRTURL, c.pairRelaySRTKey)
            statuses[id]?.transportWarning = nil
            appendLog("✓ Relay over SRT (low latency).", to: id)
            await report("relay-srt", "relay SRT")
            return
        }

        // 3. Relay over RTMP (last resort: TCP, gets through firewalls; higher latency, H.264 only).
        if !c.pairRelayRTMPURL.isEmpty {
            destinationOverride[id] = (c.pairRelayRTMPURL, c.pairRelayRTMPKey)
            statuses[id]?.transportWarning = "On RTMP relay fallback — higher latency, H.264 only"
            appendLog("⚠️ Direct and relay-SRT are unreachable (UDP blocked). Falling back to RTMP over TCP through the relay.", to: id)
            await report("relay-rtmp", "relay RTMP (UDP blocked)")
            return
        }
        appendLog("✗ Auto-pairing has no usable transport configured — re-link the receiver.", to: id)
    }

    /// SRT reachability. Connects with a deliberately wrong streamid: a rejection means the
    /// server answered (the UDP path is open); the 3 s timeout means blocked or closed.
    /// Nothing is published either way.
    func probeSRT(_ url: String) async -> Bool {
        let out = await runFFmpegCapturingOutput(args: [
            "-hide_banner", "-loglevel", "warning",
            "-f", "lavfi", "-i", "nullsrc=s=16x16:r=1", "-t", "0.5",
            "-c:v", "libx264", "-preset", "ultrafast", "-f", "mpegts",
            "-srt_streamid", "publish:__probe:x:x", "-timeout", "3000000", url]).lowercased()
        return out.contains("rejected") || !out.contains("connection to")
    }

    /// Input options for a live network source. RTSP goes over TCP (far more reliable than
    /// the UDP default on a busy LAN). An SRT source URL may carry its streamid in the
    /// query, which is how Turbo Receiver, the relay and VLC write it; ffmpeg ignores it
    /// there, so it is lifted into -srt_streamid, with the configured SRT latency.
    private func networkInputArgs(for config: StreamConfig) -> [String] {
        var url = config.networkURL.trimmingCharacters(in: .whitespacesAndNewlines)
        var a: [String] = []
        let lower = url.lowercased()
        if lower.hasPrefix("rtsp") { a += ["-rtsp_transport", "tcp"] }
        if lower.hasPrefix("srt://") {
            if let q = url.firstIndex(of: "?") {
                for pair in url[url.index(after: q)...].split(separator: "&") {
                    let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                    if kv.count == 2, kv[0] == "streamid" { a += ["-srt_streamid", kv[1]] }
                }
                url = String(url[..<q])
            }
            a += ["-latency", "\(max(20, config.srtLatencyMs) * 1000)"]
        }
        return a + ["-i", url]
    }

    /// A stable, MediaMTX-safe path name for a stream on the local server: a slug of its
    /// name plus a short id, so it reads well and never collides.
    func localPathName(for config: StreamConfig) -> String {
        let slug = config.name.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let id = String(config.id.uuidString.prefix(8)).lowercased()
        return (slug.isEmpty ? "stream" : String(slug.prefix(24))) + "-" + id
    }

    /// The RTMP URL the app publishes a stream to on the embedded server.
    private func localDestination(for config: StreamConfig) -> String {
        "rtmp://127.0.0.1:\(LocalPorts.rtmp)/\(localPathName(for: config))"
    }

    /// Turns LAN publishing on/off. Starts/stops the embedded server, registers the paths,
    /// and restarts any running streams so they (stop) publishing to it.
    func setLocalPublish(_ on: Bool) {
        guard on != localPublishEnabled else { return }
        localPublishEnabled = on
        let liveConfigs = runningStreams.filter { statuses[$0.id]?.phase.isActive == true }.map { $0.config }
        if on {
            localServer.setPaths(configs.map { (localPathName(for: $0), $0.name) })
            localServer.start()
        }
        // Restart live streams to pick up (or drop) the local destination.
        for c in liveConfigs { stopStream(id: c.id) }
        if !liveConfigs.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self else { return }
                for c in liveConfigs { self.launch(c) }
            }
        }
        if !on { localServer.stop() }
    }

    private func resolvedOutputFPS(for config: StreamConfig, captureFPS: String?) -> String {
        guard config.fpsMatchSource else { return config.fps }
        // DeckLink: the rate is known only when a format is chosen explicitly.
        if config.inputType == .decklink { return config.deckLinkFormat.fps ?? config.fps }
        return captureFPS ?? config.fps
    }

    /// The concrete encoder for a stream. Auto follows what was measured on an M2 Pro with a
    /// synthetic 4K60 source: h264_videotoolbox 0.88× (cannot keep up), hevc_videotoolbox
    /// 1.31×, libx264 veryfast 1.54×; at 4K30 h264_videotoolbox 1.54×. So Auto keeps the
    /// proven picks (x264 ≤1080p, hardware H.264 at 4K ≤30 fps) and, above 30 fps at 4K,
    /// goes HEVC to Turbo Receiver (SRT) or x264 to platforms, which mostly reject HEVC.
    func resolveCodec(for config: StreamConfig, fps: Int, isSRT: Bool) -> VideoCodec {
        guard config.videoCodec == .auto else { return config.videoCodec }
        guard config.resolution == .uhd else { return .h264Software }
        if fps <= 30 { return .h264Hardware }
        return isSRT ? .hevcHardware : .h264Software
    }

    /// `-f decklink` plus the card options. Without -format_code the card auto-detects the
    /// signal; an explicit code forces a mode. 8-bit UYVY is what the encoders want; 10-bit
    /// (yuv422p10) only pays off with HEVC main10 — see encoderArgs.
    private func deckLinkInputOptions(for config: StreamConfig) -> [String] {
        var o = ["-f", "decklink"]
        if config.deckLinkFormat != .auto    { o += ["-format_code", config.deckLinkFormat.rawValue] }
        if config.deckLinkConnector != .auto { o += ["-video_input", config.deckLinkConnector.rawValue] }
        o += ["-raw_format", config.deckLinkTenBit ? "yuv422p10" : "uyvy422"]
        return o
    }

    private func buildArgs(for config: StreamConfig, recordingURL: URL?, bitrateOverride: String? = nil, snapshotURL: URL? = nil, overlayTextURL: URL? = nil, captureFPS: String? = nil, outputFPS: String? = nil, muted: Bool = false, destination: (url: String, key: String)? = nil, pktSize: Int = 1316) -> [String] {
        let videoBitrate = bitrateOverride ?? config.videoBitrate
        let bitrateNum = Int(videoBitrate.replacingOccurrences(of: "k", with: "")) ?? 4500
        let bufsize    = "\(bitrateNum * 2)k"
        let outFPS     = outputFPS ?? config.fps
        let fpsInt     = Int((Double(outFPS) ?? 30).rounded())
        // Pre-flight may have swapped the destination (SRT blocked → the relay's RTMP door).
        // LAN publishing serves the feed locally; when on, the local server is a target too.
        let platformURL = destination?.url ?? config.rtmpURL
        let platformKey = destination?.key ?? config.streamKey
        let platformSRT = platformURL.lowercased().hasPrefix("srt://")
        let localTarget = localPublishEnabled ? localDestination(for: config) : nil
        // With an SRT platform we can't tee, so LAN publishing takes over the primary
        // (the all-local case). With an RTMP platform, LAN is added as an extra tee branch.
        let destURL: String, destKey: String, isSRT: Bool
        if let lt = localTarget, platformSRT {
            destURL = lt; destKey = ""; isSRT = false
        } else {
            destURL = platformURL; destKey = platformKey; isSRT = platformSRT
        }
        let dest       = destKey.isEmpty ? destURL : "\(destURL)/\(destKey)"
        let backup     = config.backupRTMPURL.trimmingCharacters(in: .whitespaces)
        let localTee   = (localTarget != nil && !platformSRT && destURL != localTarget) ? localTarget : nil

        var args: [String]

        // ── Input ──────────────────────────────────────────────────────────
        if config.inputType == .file {
            args = [
                "-hide_banner", "-loglevel", "info",
                "-hwaccel", "videotoolbox",
                "-re", "-stream_loop", "-1",
                "-i", config.filePath
            ]
        } else if config.inputType == .decklink {
            args = ["-hide_banner", "-loglevel", "info"]
                + deckLinkInputOptions(for: config)
                + ["-thread_queue_size", "1024", "-i", config.deckLinkDeviceName]
        } else if config.inputType == .network {
            // Live network source (Turbo Receiver, the relay, a camera): no -re and no
            // -stream_loop — the sender already paces it.
            args = ["-hide_banner", "-loglevel", "info", "-thread_queue_size", "1024"]
                + networkInputArgs(for: config)
        } else {
            // AVFoundation capture: don't force a resolution, and use a framerate the
            // device actually supports (probed). The default (29.97) and the app's 25
            // are rejected by cameras like the FaceTime camera (15/30 only). The scale
            // filter + output -r normalize to the chosen resolution/fps.
            let audio = config.audioDeviceIndex.isEmpty ? "none" : config.audioDeviceIndex
            args = [
                "-hide_banner", "-loglevel", "info",
                "-f", "avfoundation",
                "-framerate", captureFPS ?? "30",
                "-thread_queue_size", "1024",
                "-i", "\(config.videoDeviceIndex):\(audio)"
            ]
        }

        // -y: overwrite file outputs (the snapshot JPEG) without prompting — otherwise a
        // reconnect finds the previous snapshot and ffmpeg refuses to open the output.
        args.insert("-y", at: 1)

        // ── Network passthrough: relay the incoming stream untouched ───────────
        // No decode, no filters, no encoder: what arrives is what leaves, so this hop
        // adds zero loss. Overlay, scaling, fps, mute, adaptive bitrate and the
        // freeze/black detectors don't apply; backup and recording still do.
        if config.inputType == .network && config.networkPassthrough {
            args += ["-map", "0:v:0", "-map", "0:a:0?", "-c", "copy"]
            if !isSRT && (!backup.isEmpty || recordingURL != nil) {
                args += ["-f", "tee", teeTargets(dest: dest, backup: backup, recordingURL: recordingURL).joined(separator: "|")]
            } else {
                args += primaryOutputArgs(url: destURL, key: destKey, latencyMs: config.srtLatencyMs, pktSize: pktSize)
            }
            return args
        }

        // ── Encoder ────────────────────────────────────────────────────────
        // 10-bit survives only into HEVC main10; every other encoder gets 8-bit yuv420p.
        var codec  = resolveCodec(for: config, fps: fpsInt, isSRT: isSRT)
        // HEVC cannot travel over RTMP/FLV (the relay's TCP door, and every RTMP platform):
        // ffmpeg's flv muxer rejects it. Only SRT/MPEG-TS carries HEVC, so clamp to
        // hardware H.264 whenever the actual output isn't SRT.
        if codec == .hevcHardware, !isSRT { codec = .h264Hardware }
        let tenBit = codec == .hevcHardware && config.inputType == .decklink && config.deckLinkTenBit
        func encoderArgs() -> [String] {
            let gop = "\(fpsInt * 2)"   // keyframe every 2 s (platform ABR expects it)
            switch codec {
            case .h264Hardware, .auto:
                return [
                    "-c:v", "h264_videotoolbox", "-profile:v", "high",
                    "-b:v", videoBitrate, "-g", gop,
                    "-realtime", "1", "-prio_speed", "1", "-bf", "0", "-allow_sw", "1"
                ]
            case .hevcHardware:
                return [
                    "-c:v", "hevc_videotoolbox", "-profile:v", tenBit ? "main10" : "main",
                    "-b:v", videoBitrate, "-g", gop,
                    "-realtime", "1", "-prio_speed", "1", "-bf", "0", "-allow_sw", "1"
                ]
            case .h264Software:
                return [
                    "-c:v", "libx264", "-preset", "veryfast",
                    "-profile:v", "high", "-pix_fmt", "yuv420p",
                    "-b:v", videoBitrate, "-maxrate", videoBitrate,
                    "-bufsize", bufsize, "-g", gop,
                    "-keyint_min", gop, "-sc_threshold", "0",
                    "-tune", "zerolatency"
                ]
            }
        }

        // ── Video filter: scale + content detectors (freeze / black) + overlay ──
        let detectors   = "freezedetect=n=-60dB:d=3,blackdetect=d=3"
        var videoFilter = "\(tenBit ? config.resolution.scaleOnly : config.resolution.scaleFilter),\(detectors)"
        if let textURL = overlayTextURL,
           let dt = drawtextFilter(for: config.overlay, textPath: textURL.path) {
            videoFilter += ",\(dt)"   // text overlay drawn last, on top of everything
        }
        if tenBit { videoFilter += ",format=p010le" }   // conversion last — see ResolutionPreset.scaleOnly
        // The volume filter is ALWAYS in the chain so mute/unmute can be toggled live via a
        // runtime command on ffmpeg's stdin (no restart, no gap). Its initial value carries
        // the current mute state, so a reconnect comes back muted if it was muted.
        let audioArgs = ["-af", "volume=\(muted ? "0" : "1")"]
            + ["-c:a", "aac", "-b:a", config.audioBitrate, "-ar", "48000", "-ac", "2"]

        // ── Output ──────────────────────────────────────────────────────────
        // Simplest proven path (single dest, no snapshot) → plain -vf + flv.
        // Otherwise → filter_complex so we can fan out: tee (backup/recording)
        // and/or a 1 fps snapshot branch (most-recent-frame fallback).
        // SRT destination: the path travels in the SRT streamid, not in the URL, and
        // ffmpeg ignores it in the query string — it needs the dedicated option.
        // MPEG-TS is the container; tee is not used because per-target streamid
        // cannot be expressed, so backup/recording are skipped on SRT.
        func primaryOutput() -> [String] { primaryOutputArgs(url: destURL, key: destKey, latencyMs: config.srtLatencyMs, pktSize: pktSize) }

        let useTee = !isSRT && (!backup.isEmpty || recordingURL != nil || localTee != nil)
        let snapshot = snapshotURL != nil

        if useTee || snapshot {
            // Build the filtergraph, splitting off a low-fps snapshot branch if needed.
            var fc = "[0:v]\(videoFilter),fps=\(outFPS)"
            if snapshot {
                fc += ",split=2[vmain][vtmp];[vtmp]fps=1,scale=640:-2[vsnap]"
            } else {
                fc += "[vmain]"
            }
            args += ["-filter_complex", fc, "-map", "[vmain]", "-map", "0:a?"]
            args += encoderArgs()
            args += audioArgs

            // Primary uses default onfail=abort → a primary drop ends ffmpeg and
            // triggers reconnect. Backup & recording use onfail=ignore.
            if useTee {
                args += ["-f", "tee", teeTargets(dest: dest, backup: backup, recordingURL: recordingURL, local: localTee).joined(separator: "|")]
            } else {
                args += primaryOutput()
            }

            // Snapshot output: overwrite one JPEG ~1×/sec with a recent frame.
            if let snap = snapshotURL {
                args += ["-map", "[vsnap]", "-c:v", "mjpeg", "-update", "1", "-q:v", "4",
                         "-f", "image2", snap.path]
            }
        } else {
            args += ["-vf", videoFilter, "-r", outFPS]
            args += encoderArgs()
            args += audioArgs
            args += primaryOutput()
        }

        return args
    }
}
