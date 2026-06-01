import Foundation

// MARK: - Enums

enum InputType: String, CaseIterable, Identifiable, Codable {
    case file     = "File"
    case capture  = "Capture Card"
    case decklink = "Blackmagic"
    var id: String { rawValue }
}

enum ResolutionPreset: String, CaseIterable, Identifiable, Codable {
    case hd       = "1920×1080 (16:9)"
    case uhd      = "3840×2160 (4K)"
    case vertical = "1080×1920 (9:16)"

    var id: String { rawValue }

    var scaleFilter: String {
        // format=yuv420p converts 10-bit sources (e.g. ProRes) to 8-bit for H.264
        switch self {
        case .hd:       return "scale=1920:1080,format=yuv420p"
        case .uhd:      return "scale=3840:2160,format=yuv420p"
        case .vertical: return "crop=ih*9/16:ih:(iw-ih*9/16)/2:0,scale=1080:1920,format=yuv420p"
        }
    }

    var captureSize: String {
        switch self {
        case .hd, .vertical: return "1920x1080"
        case .uhd:            return "3840x2160"
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
    var resolution: ResolutionPreset  = .hd
    var inputType: InputType          = .file
    var filePath: String              = ""
    var videoDeviceIndex: String      = "0"
    var audioDeviceIndex: String      = ""
    var deckLinkDeviceName: String    = ""   // device name as reported by ffmpeg -f decklink -list_devices

    // Failsafe options
    var backupRTMPURL: String         = ""   // full backup destination (url/key); empty = none
    var safetyRecording: Bool         = false // record program to disk while streaming

    init(index: Int = 1) {
        self.id   = UUID()
        self.name = "Stream \(index)"
    }
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
    var inputWarning: String?     // "Frozen" / "Black" / nil — content issue, not a disconnect

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
        for line in incoming {
            if line.contains("frame=") && line.contains("fps=") {
                sawProgress = true
                if let v = Self.value(after: "fps=",     in: line) { liveFPS     = v }
                if let v = Self.value(after: "bitrate=", in: line) { liveBitrate = v }
                if let v = Self.value(after: "speed=",   in: line) { liveSpeed   = v }
                if let v = Self.value(after: "drop=",    in: line) { liveDrop    = v }
            }
            // Content-quality detectors (passthrough filters that only log)
            if line.contains("freeze_start") { inputWarning = "Frozen" }
            if line.contains("freeze_end")   { if inputWarning == "Frozen" { inputWarning = nil } }
            if line.contains("black_start")  { inputWarning = "Black screen" }
            if line.contains("black_end")    { if inputWarning == "Black screen" { inputWarning = nil } }
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
