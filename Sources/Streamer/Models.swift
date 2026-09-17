import Foundation

// MARK: - Enums

enum InputType: String, CaseIterable, Identifiable, Codable {
    case file     = "File"
    case capture  = "Capture Card"
    case decklink = "Blackmagic"
    case network  = "Network"
    var id: String { rawValue }
}

/// Blackmagic input format (`-format_code`). `auto` asks the card to detect the incoming
/// signal, which every current DeckLink/UltraStudio supports. An explicit code is
/// deterministic — use it when detection fails or to force a mode — and it also tells the
/// app the source frame rate up front, which is what lets "Match source" follow it.
enum DeckLinkFormat: String, CaseIterable, Identifiable, Codable {
    case auto = "auto"
    case hd1080p2398 = "23ps", hd1080p24 = "24ps", hd1080p25 = "Hp25", hd1080p2997 = "Hp29", hd1080p30 = "Hp30"
    case hd1080p50 = "Hp50", hd1080p5994 = "Hp59", hd1080p60 = "Hp60"
    case hd1080i50 = "Hi50", hd1080i5994 = "Hi59", hd1080i60 = "Hi60"
    case hd720p50 = "hp50", hd720p5994 = "hp59", hd720p60 = "hp60"
    case uhd2160p2398 = "4k23", uhd2160p24 = "4k24", uhd2160p25 = "4k25", uhd2160p2997 = "4k29", uhd2160p30 = "4k30"
    case uhd2160p50 = "4k50", uhd2160p5994 = "4k59", uhd2160p60 = "4k60"

    var id: String { rawValue }

    /// (menu label, frame rate as the app's fps string). Interlaced modes list the frame
    /// rate, i.e. half the field rate, which is what ffmpeg delivers.
    private static let table: [DeckLinkFormat: (label: String, fps: String?)] = [
        .auto:         ("Auto-detect", nil),
        .hd1080p2398:  ("1080p23.98", "23.98"), .hd1080p24: ("1080p24", "24"),
        .hd1080p25:    ("1080p25", "25"),       .hd1080p2997: ("1080p29.97", "29.97"), .hd1080p30: ("1080p30", "30"),
        .hd1080p50:    ("1080p50", "50"),       .hd1080p5994: ("1080p59.94", "59.94"), .hd1080p60: ("1080p60", "60"),
        .hd1080i50:    ("1080i50", "25"),       .hd1080i5994: ("1080i59.94", "29.97"), .hd1080i60: ("1080i60", "30"),
        .hd720p50:     ("720p50", "50"),        .hd720p5994:  ("720p59.94", "59.94"),  .hd720p60:  ("720p60", "60"),
        .uhd2160p2398: ("2160p23.98", "23.98"), .uhd2160p24:  ("2160p24", "24"),
        .uhd2160p25:   ("2160p25", "25"),       .uhd2160p2997: ("2160p29.97", "29.97"), .uhd2160p30: ("2160p30", "30"),
        .uhd2160p50:   ("2160p50", "50"),       .uhd2160p5994: ("2160p59.94", "59.94"), .uhd2160p60: ("2160p60", "60"),
    ]
    var label: String { Self.table[self]?.label ?? rawValue }
    /// The signal's frame rate, nil for auto-detect (unknown until the card reports it).
    var fps: String? { Self.table[self]?.fps }
}

/// Which physical input the card should listen on (`-video_input`). `auto` leaves the
/// card's own setting (Desktop Video Setup) in charge.
enum DeckLinkConnector: String, CaseIterable, Identifiable, Codable {
    case auto = "auto", sdi, hdmi, opticalSDI = "optical_sdi", component, composite
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto:       return "Card default"
        case .sdi:        return "SDI"
        case .hdmi:       return "HDMI"
        case .opticalSDI: return "Optical SDI"
        case .component:  return "Component"
        case .composite:  return "Composite"
        }
    }
}

/// Video encoder. `auto` is resolved in StreamManager by resolution, frame rate and
/// destination (measurements in `buildArgs`). HEVC is for Turbo Receiver (SRT) or the few
/// platforms that ingest it (YouTube); most RTMP platforms take H.264 only.
enum VideoCodec: String, CaseIterable, Identifiable, Codable {
    case auto
    case h264Hardware = "h264_videotoolbox"
    case h264Software = "libx264"
    case hevcHardware = "hevc_videotoolbox"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto:         return "Auto"
        case .h264Hardware: return "H.264 · hardware"
        case .h264Software: return "H.264 · x264 (software)"
        case .hevcHardware: return "HEVC · hardware"
        }
    }
}

enum ResolutionPreset: String, CaseIterable, Identifiable, Codable {
    case hd       = "1920×1080 (16:9)"
    case uhd      = "3840×2160 (4K)"
    case vertical = "1080×1920 (9:16)"

    var id: String { rawValue }

    /// 8-bit output: format=yuv420p converts 10-bit sources (e.g. ProRes) for H.264.
    var scaleFilter: String { "\(scaleOnly),format=yuv420p" }

    /// Geometry only. A 10-bit chain puts its pixel-format conversion LAST — after the
    /// detectors and drawtext — or ffmpeg auto-inserts two extra conversions per frame
    /// (measured at 4K60: 1.09× vs 1.36× real-time).
    var scaleOnly: String {
        switch self {
        case .hd:       return "scale=1920:1080"
        case .uhd:      return "scale=3840:2160"
        case .vertical: return "crop=ih*9/16:ih:(iw-ih*9/16)/2:0,scale=1080:1920"
        }
    }

    var captureSize: String {
        switch self {
        case .hd, .vertical: return "1920x1080"
        case .uhd:            return "3840x2160"
        }
    }

    /// Final output dimensions (w, h) — used to letterbox the fallback slate.
    var outputDimensions: (w: Int, h: Int) {
        switch self {
        case .hd:       return (1920, 1080)
        case .uhd:      return (3840, 2160)
        case .vertical: return (1080, 1920)
        }
    }

    /// Sensible streaming bitrate for each resolution (used to auto-fill the field).
    var defaultBitrate: String {
        switch self {
        case .hd:       return "5872k"
        case .uhd:      return "16000k"   // 4K H.264 — VideoToolbox handles it
        case .vertical: return "5872k"
        }
    }
}

enum RTMPPreset: String, CaseIterable, Identifiable, Codable {
    case mux     = "Mux"
    case youtube = "YouTube"
    case vimeo   = "Vimeo"
    case custom  = "Custom"

    var id: String { rawValue }

    var defaultURL: String {
        switch self {
        case .mux:     return "rtmp://global-live.mux.com/app"
        case .youtube: return "rtmp://a.rtmp.youtube.com/live2"
        case .vimeo:   return "rtmp://rtmp-global.cloud.vimeo.com/live"
        case .custom:  return ""
        }
    }
}

// MARK: - Text overlay

enum OverlayPosition: String, CaseIterable, Identifiable, Codable {
    case top    = "Top"
    case center = "Center"
    case bottom = "Bottom"
    var id: String { rawValue }

    /// ffmpeg drawtext `y` expression (text is horizontally centered separately).
    var yExpr: String {
        switch self {
        case .top:    return "h*0.08"
        case .center: return "(h-text_h)/2"
        case .bottom: return "h-text_h-(h*0.08)"
        }
    }
}

struct TextOverlay: Codable, Equatable {
    var enabled: Bool          = false
    var text: String           = ""
    var fontChoice: String     = "Sofia Pro Bold"   // a bundled name or "Custom"
    var customFontPath: String = ""
    var fontSize: Int          = 54
    var colorHex: String       = "FFFFFF"
    var position: OverlayPosition = .bottom
    var boxEnabled: Bool       = true
    var boxOpacity: Double     = 0.55

    /// Built-in fonts (display name → bundled file in Contents/Resources/Fonts).
    static let bundledFonts: [(name: String, file: String)] = [
        ("Sofia Pro Regular", "Sofia Pro Regular Az.otf"),
        ("Sofia Pro Medium",  "Sofia Pro Medium Az.otf"),
        ("Sofia Pro Bold",    "Sofia Pro Bold Az.otf"),
        ("Bello Pro (script)", "bellopro.otf"),
    ]
    static let customFontLabel = "Custom…"
}

// MARK: - Stream configuration (struct so SwiftUI bindings work cleanly)

struct StreamConfig: Identifiable, Codable {
    let id: UUID
    var name: String
    var rtmpPreset: RTMPPreset        = .mux
    var rtmpURL: String               = RTMPPreset.mux.defaultURL
    var streamKey: String             = ""
    var videoBitrate: String          = "5872k"
    var audioBitrate: String          = "128k"
    var fps: String                   = "25"
    var fpsMatchSource: Bool          = false  // encode at the source's native rate; `fps` is the fallback
    var resolution: ResolutionPreset  = .hd
    var inputType: InputType          = .file
    var filePath: String              = ""
    var videoDeviceIndex: String      = "0"
    var audioDeviceIndex: String      = ""
    var deckLinkDeviceName: String    = ""   // device name as reported by ffmpeg -f decklink -list_devices
    var deckLinkFormat: DeckLinkFormat       = .auto   // -format_code; auto = the card detects the signal
    var deckLinkConnector: DeckLinkConnector = .auto   // -video_input; auto = the card's own setting
    var deckLinkTenBit: Bool                 = false   // capture 10-bit 4:2:2 (kept only with HEVC hardware)
    var videoCodec: VideoCodec               = .auto   // encoder; auto picks by resolution/fps/destination
    var networkURL: String            = ""   // live RTSP/RTMP/SRT/HTTP source (e.g. from Turbo Receiver)
    var networkPassthrough: Bool      = false // Network input: relay the stream as-is, no decode/re-encode
    var srtLatencyMs: Int             = 120  // SRT receiver buffer; the latency/robustness trade-off
    var altRTMPURL: String            = ""   // relay's RTMP door: pre-flight switches to it when SRT (UDP) is blocked
    var altStreamKey: String          = ""

    // Failsafe options
    var backupRTMPURL: String         = ""    // full backup destination (url/key); empty = none
    var safetyRecording: Bool         = false // record program to disk while streaming
    var fallbackEnabled: Bool         = false // show a fallback on-air when the input dies
    var fallbackMediaPath: String     = ""    // optional custom card; empty = use most recent captured frame
    var adaptiveBitrate: Bool         = false // step bitrate down on instability, back up when stable

    // Text overlay (lower-third / standby messaging, editable live)
    var overlay: TextOverlay          = TextOverlay()

    init(index: Int = 1) {
        self.id   = UUID()
        self.name = "Stream \(index)"
    }

    // Resilient decoding: missing keys fall back to defaults, so adding fields
    // in future versions never wipes previously-saved configs.
    enum CodingKeys: String, CodingKey {
        case id, name, rtmpPreset, rtmpURL, streamKey, videoBitrate, audioBitrate, fps,
             fpsMatchSource, resolution, inputType, filePath, videoDeviceIndex, audioDeviceIndex,
             deckLinkDeviceName, deckLinkFormat, deckLinkConnector, deckLinkTenBit, videoCodec,
             networkURL, networkPassthrough, srtLatencyMs, altRTMPURL, altStreamKey,
             backupRTMPURL, safetyRecording, fallbackEnabled,
             fallbackMediaPath, adaptiveBitrate, overlay
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id                 = (try? c.decode(UUID.self,            forKey: .id)) ?? UUID()
        name               = (try? c.decode(String.self,          forKey: .name)) ?? "Stream"
        rtmpPreset         = (try? c.decode(RTMPPreset.self,      forKey: .rtmpPreset)) ?? .mux
        rtmpURL            = (try? c.decode(String.self,          forKey: .rtmpURL)) ?? RTMPPreset.mux.defaultURL
        streamKey          = (try? c.decode(String.self,          forKey: .streamKey)) ?? ""
        videoBitrate       = (try? c.decode(String.self,          forKey: .videoBitrate)) ?? "5872k"
        audioBitrate       = (try? c.decode(String.self,          forKey: .audioBitrate)) ?? "128k"
        fps                = (try? c.decode(String.self,          forKey: .fps)) ?? "25"
        fpsMatchSource     = (try? c.decode(Bool.self,            forKey: .fpsMatchSource)) ?? false
        resolution         = (try? c.decode(ResolutionPreset.self, forKey: .resolution)) ?? .hd
        inputType          = (try? c.decode(InputType.self,       forKey: .inputType)) ?? .file
        filePath           = (try? c.decode(String.self,          forKey: .filePath)) ?? ""
        videoDeviceIndex   = (try? c.decode(String.self,          forKey: .videoDeviceIndex)) ?? "0"
        audioDeviceIndex   = (try? c.decode(String.self,          forKey: .audioDeviceIndex)) ?? ""
        deckLinkDeviceName = (try? c.decode(String.self,          forKey: .deckLinkDeviceName)) ?? ""
        deckLinkFormat     = (try? c.decode(DeckLinkFormat.self,  forKey: .deckLinkFormat)) ?? .auto
        deckLinkConnector  = (try? c.decode(DeckLinkConnector.self, forKey: .deckLinkConnector)) ?? .auto
        deckLinkTenBit     = (try? c.decode(Bool.self,            forKey: .deckLinkTenBit)) ?? false
        videoCodec         = (try? c.decode(VideoCodec.self,      forKey: .videoCodec)) ?? .auto
        networkURL         = (try? c.decode(String.self,          forKey: .networkURL)) ?? ""
        networkPassthrough = (try? c.decode(Bool.self,            forKey: .networkPassthrough)) ?? false
        srtLatencyMs       = (try? c.decode(Int.self,             forKey: .srtLatencyMs)) ?? 120
        altRTMPURL         = (try? c.decode(String.self,          forKey: .altRTMPURL)) ?? ""
        altStreamKey       = (try? c.decode(String.self,          forKey: .altStreamKey)) ?? ""
        backupRTMPURL      = (try? c.decode(String.self,          forKey: .backupRTMPURL)) ?? ""
        safetyRecording    = (try? c.decode(Bool.self,            forKey: .safetyRecording)) ?? false
        fallbackEnabled    = (try? c.decode(Bool.self,            forKey: .fallbackEnabled)) ?? false
        fallbackMediaPath  = (try? c.decode(String.self,          forKey: .fallbackMediaPath)) ?? ""
        adaptiveBitrate    = (try? c.decode(Bool.self,            forKey: .adaptiveBitrate)) ?? false
        overlay            = (try? c.decode(TextOverlay.self,     forKey: .overlay)) ?? TextOverlay()
    }
}

// MARK: - RTMP URL helper

extension StreamConfig {
    /// Splits a combined "rtmp(s)://host/app/streamkey" into (base URL, stream key).
    /// Returns nil unless it's an rtmp/rtmps URL with at least an app path + a key,
    /// so a plain "rtmp://host/app" (no key) is left alone rather than mis-split.
    static func splitRTMPURL(_ raw: String) -> (base: String, key: String)? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = s.lowercased()
        let scheme: String
        if lower.hasPrefix("rtmps://")     { scheme = "rtmps://" }
        else if lower.hasPrefix("rtmp://") { scheme = "rtmp://" }
        else { return nil }
        // parts[0] = host[:port]; the rest are path segments. Need host + app + key.
        var parts = s.dropFirst(scheme.count).split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3 else { return nil }
        let key = parts.removeLast()
        guard !key.isEmpty, !parts.contains(where: { $0.isEmpty }) else { return nil }
        return (scheme + parts.joined(separator: "/"), key)
    }
}

// MARK: - Plain-language diagnostics

enum DiagnosticSeverity: Equatable { case error, warning, info }

/// A human-readable translation of a known failure signature in the ffmpeg / app log.
extension Diagnostic {
    /// Raised from measured progress (speed < 1x for a few seconds), not from a log line.
    static let encoderBehind = Diagnostic(
        id: "encoder_behind", severity: .warning,
        title: "Archimede non sta dietro",
        meaning: "The encoder runs slower than real time (speed under 1x): frames get dropped and the stream stutters. This Mac can't sustain this resolution, frame rate and codec together.",
        fix: "Change Codec (HEVC hardware for 4K60 to Turbo Receiver; hardware H.264 instead of x264 on a slower Mac), or lower the frame rate or resolution.",
        match: [])
}

/// The catalog is plain data — add entries freely; matchers are lowercase substrings.
struct Diagnostic: Identifiable, Equatable {
    let id: String
    let severity: DiagnosticSeverity
    let title: String     // plain, glanceable headline
    let meaning: String   // one line: what it means
    let fix: String       // one line: what to try
    let match: [String]   // case-insensitive substrings; ANY hit triggers

    static func == (a: Diagnostic, b: Diagnostic) -> Bool { a.id == b.id }

    /// First catalog entry whose any matcher appears in `line` (case-insensitive).
    static func diagnose(_ line: String) -> Diagnostic? {
        let l = line.lowercased()
        return catalog.first { d in d.match.contains { l.contains($0) } }
    }

    /// Focused, high-frequency catalog. Order = priority (specific before generic).
    static let catalog: [Diagnostic] = [
        // ── Connection / destination ──
        Diagnostic(id: "dns", severity: .error,
                   title: "Pippo ha perso la mappa",
                   meaning: "The server address can't be found: the hostname in your RTMP URL doesn't exist online — usually a typo, or no internet.",
                   fix: "Double-check the RTMP URL and that this Mac is online.",
                   match: ["failed to resolve hostname"]),
        Diagnostic(id: "refused", severity: .error,
                   title: "La security non ti fa entrare",
                   meaning: "The server refused the connection: reachable but won't accept the stream — wrong URL/port, or the platform's ingest is down.",
                   fix: "Verify the RTMP URL; if it's right, the platform may be down.",
                   match: ["connection refused"]),
        Diagnostic(id: "timeout", severity: .error,
                   title: "Nessuno risponde, Pluto aspetta alla porta",
                   meaning: "The server never replied in time — often a firewall blocking RTMP port 1935, or a very slow network.",
                   fix: "Try another network or check the firewall.",
                   match: ["connection timed out", "operation timed out"]),
        Diagnostic(id: "dropped", severity: .warning,
                   title: "Oh no, Pippo è inciampato nel cavo!",
                   meaning: "You were live, then the platform dropped the connection — a network blip or not enough upload speed.",
                   fix: "Reconnecting now; if it repeats, check upload bandwidth and the chiave (stream key).",
                   match: ["connection reset by peer", "broken pipe", "error writing trailer"]),
        Diagnostic(id: "rejected", severity: .error,
                   title: "Paperoga respinto: chiave sbagliata",
                   meaning: "The platform actively rejected the broadcast — almost always a wrong or expired stream key.",
                   fix: "Re-copy the chiave from the platform and start again.",
                   match: ["rtmp server sent error", "unauthorized", "forbidden"]),
        // ── Input / source ──
        Diagnostic(id: "nofile", severity: .error,
                   title: "Il nastro è sparito a Topolinia",
                   meaning: "The video file isn't where it was — moved, renamed, or deleted.",
                   fix: "Pick the file again.",
                   match: ["error opening input: no such file"]),
        Diagnostic(id: "stalled", severity: .warning,
                   title: "Pippo si è addormentato",
                   meaning: "No new video for 10s: the camera/capture card was unplugged, lost power, or froze.",
                   fix: "Check the cavo (cable)/device — auto-restarting.",
                   match: ["no frames for", "input stalled"]),
        Diagnostic(id: "camera_denied", severity: .error,
                   title: "Il Mac non dà la telecamera a Topolino",
                   meaning: "macOS privacy is blocking the app from the camera.",
                   fix: "System Settings → Privacy & Security → Camera, enable Streamer, then restart.",
                   match: ["camera access denied", "not authorized to use"]),
        Diagnostic(id: "device_busy", severity: .error,
                   title: "I Bassotti hanno ciulato la telecamera",
                   meaning: "Another app already has the camera open (Zoom, OBS, a browser).",
                   fix: "Quit the other app, then restart.",
                   match: ["device or resource busy"]),
        // ── Device / disk / engine ──
        Diagnostic(id: "decklink", severity: .error,
                   title: "Blackmagic fa impazzire Pippo",
                   meaning: "The DeckLink device couldn't open — not connected, off, or the Desktop Video driver is too old.",
                   fix: "Check it's connected, install Desktop Video 16+, then re-scan.",
                   match: ["cannot open decklink", "no decklink devices", "could not open decklink",
                           "could not open input device", "could not create decklink iterator"]),
        Diagnostic(id: "decklink_signal", severity: .warning,
                   title: "Pippo non vede nessun segnale",
                   meaning: "The DeckLink opened but there's no signal on its input — nothing plugged in, the wrong connector (SDI vs HDMI), or the card can't auto-detect this format.",
                   fix: "Check the cable and the Connector setting, or pick the exact Format instead of Auto-detect.",
                   match: ["cannot autodetect input stream", "no input signal detected"]),
        Diagnostic(id: "decklink_format", severity: .error,
                   title: "Pippo ha sbagliato formato",
                   meaning: "The card refused the chosen DeckLink format or pixel depth — the signal or the card doesn't support it.",
                   fix: "Pick the format that matches the source (or Auto-detect), and try 8-bit.",
                   match: ["could not set format code", "raw format", "unsupported video size"]),
        Diagnostic(id: "disk_full", severity: .error,
                   title: "Il deposito di Paperone è pieno",
                   meaning: "The disk has no free space for the safety recording.",
                   fix: "Free up space, or turn off Safety recording.",
                   match: ["no space left on device"]),
        Diagnostic(id: "launch_fail", severity: .error,
                   title: "Archimede non riesce ad avviare il motore",
                   meaning: "The streaming engine (ffmpeg) failed to launch — a rare glitch.",
                   fix: "Restart the app; if it persists, rebuild with build.sh.",
                   match: ["failed to launch ffmpeg"]),
    ]
}

// MARK: - Runtime status

struct StreamStatus {
    var phase: StreamPhase = .idle
    var logLines: [String] = []

    // Live metrics parsed from ffmpeg progress lines
    var liveFPS: String?
    var liveBitrate: String?
    var liveSpeed: String?
    var liveDrop: String?
    var inputWarning: String?     // themed freeze/black badge text, or nil — content issue, not a disconnect
    var currentDiagnostic: Diagnostic?   // plain-language translation of the latest failure (nil = all good)
    var slowSamples = 0           // consecutive progress lines with speed < 0.95x (encoder falling behind)

    // Themed badge text for the freeze / black content detectors (Topolino voice).
    static let frozenBadge = "Pippo si è freezato, prova a dargli una botta!"
    static let blackBadge  = "Non si vede niente, stai forse rubando lo stipendio?"

    /// True if a progress line was seen in this batch (used by the hang watchdog).
    @discardableResult
    mutating func appendLog(_ text: String) -> Bool {
        let incoming = text
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .init(charactersIn: "\r ")) }
            .filter { !$0.isEmpty }
        logLines.append(contentsOf: incoming)
        if logLines.count > 500 { logLines.removeFirst(logLines.count - 500) }

        var sawProgress = false
        var firstIssue: Diagnostic? = nil
        for line in incoming {
            if line.contains("frame=") && line.contains("fps=") {
                sawProgress = true
                if let v = Self.value(after: "fps=",     in: line) { liveFPS     = v }
                if let v = Self.value(after: "bitrate=", in: line) { liveBitrate = v }
                if let v = Self.value(after: "speed=",   in: line) { liveSpeed   = v }
                if let v = Self.value(after: "drop=",    in: line) { liveDrop    = v }
            } else if firstIssue == nil {
                firstIssue = Diagnostic.diagnose(line)   // ffmpeg logs the root cause first
            }
            // Content-quality detectors (passthrough filters that only log)
            if line.contains("freeze_start") { inputWarning = Self.frozenBadge }
            if line.contains("freeze_end")   { if inputWarning == Self.frozenBadge { inputWarning = nil } }
            if line.contains("black_start")  { inputWarning = Self.blackBadge }
            if line.contains("black_end")    { if inputWarning == Self.blackBadge { inputWarning = nil } }
        }
        // Frames flowing ⇒ any earlier connection/input error is resolved; otherwise
        // surface the first matched failure for the Live card's plain-language panel.
        if sawProgress { currentDiagnostic = nil }
        else if let issue = firstIssue { currentDiagnostic = issue }
        // Encoder slower than real time is not an error line, so it is measured here: ~3 s
        // of consecutive progress under 0.95x (the first seconds of a run read low while
        // buffers fill, which the streak absorbs). Machine-independent: whatever Mac this
        // runs on, a codec it can't sustain shows up here within seconds.
        if sawProgress {
            if let s = liveSpeed, let v = Double(s.replacingOccurrences(of: "x", with: "")) {
                slowSamples = v < 0.95 ? slowSamples + 1 : 0
            }
            if slowSamples >= 6 { currentDiagnostic = Diagnostic.encoderBehind }
        }
        return sawProgress
    }

    /// Extracts the whitespace-delimited token following `key` (e.g. "fps= 25" → "25").
    private static func value(after key: String, in line: String) -> String? {
        guard let r = line.range(of: key) else { return nil }
        let rest  = line[r.upperBound...].drop(while: { $0 == " " })
        let token = rest.prefix(while: { $0 != " " })
        return token.isEmpty ? nil : String(token)
    }
}

enum StreamPhase: Equatable {
    case idle
    case running
    case reconnecting(attempt: Int)
    case stopped

    var label: String {
        switch self {
        case .idle:                return "Ready"
        case .running:             return "Live"
        case .reconnecting(let n): return "Reconnecting (\(n))"
        case .stopped:             return "Stopped"
        }
    }

    var isActive: Bool {
        switch self {
        case .running, .reconnecting: return true
        default:                      return false
        }
    }

    static func == (lhs: StreamPhase, rhs: StreamPhase) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.running, .running), (.stopped, .stopped): return true
        case (.reconnecting(let a), .reconnecting(let b)):               return a == b
        default:                                                          return false
        }
    }
}

// MARK: - Capture device (for dropdowns)

struct CaptureDevice: Identifiable, Hashable {
    let id = UUID()
    let index: String   // AVFoundation device index; empty for DeckLink
    let name: String
}

// MARK: - Running stream record (shown in Live tab)

struct RunningStreamRecord: Identifiable {
    let id: UUID = UUID()   // fresh UUID per launch instance, independent of config.id
    let config: StreamConfig
    let startedAt: Date
    let logFileURL: URL
}

// MARK: - Saved profile (named snapshot of all stream configs)

struct Profile: Codable, Identifiable {
    var id: String { name }
    var name: String
    var configs: [StreamConfig]
}
