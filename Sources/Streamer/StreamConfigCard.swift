import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct StreamConfigCard: View {
    @Binding var config: StreamConfig
    @EnvironmentObject var manager: StreamManager
    @State private var pasteHint: String? = nil
    @State private var showLink = false
    @State private var linkSession: LinkClient.Session? = nil
    @State private var linkReceivers: [LinkClient.Receiver] = []
    @State private var linkError: String? = nil
    @State private var linkBusy = false
    @State private var linkPoll: Task<Void, Never>? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── Name ─────────────────────────────────────────────────────────
            HStack {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .foregroundStyle(Color.accentColor)
                    .font(.system(size: 14))
                TextField("Stream name", text: $config.name)
                    .font(.custom("SofiaPro-SemiBold", size: 15))
                    .foregroundStyle(.white)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)

            divider

            // ── Destination ───────────────────────────────────────────────────
            sectionContent {
                sectionHeader("Destination")

                Picker("Platform", selection: $config.rtmpPreset) {
                    ForEach(RTMPPreset.allCases) { preset in
                        Text(preset.rawValue).tag(preset)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: config.rtmpPreset) { preset in
                    if preset != .custom { config.rtmpURL = preset.defaultURL; config.autoPair = false }
                }

                if config.autoPair {
                    HStack(spacing: 8) {
                        Label("Auto-pairing on — direct → relay-SRT → relay-RTMP, chosen at start",
                              systemImage: "wand.and.stars")
                            .font(.custom("SofiaPro", size: 11))
                            .foregroundStyle(Color.accentColor)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Off") { config.autoPair = false }
                            .buttonStyle(.bordered).controlSize(.small)
                            .help("Stop auto-pairing and send to the URL and key below as typed.")
                    }
                    .padding(8)
                    .background(Color.accentColor.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }

                labeled("RTMP URL") {
                    TextField("rtmps://…", text: $config.rtmpURL)
                        .textFieldStyle(.roundedBorder)
                        .disabled(config.rtmpPreset != .custom)
                        .foregroundStyle(config.rtmpPreset == .custom ? .white : Color.white.opacity(0.4))
                        .onChange(of: config.rtmpURL) { v in
                            if config.autoPair, v != config.pairDirectURL { config.autoPair = false }
                        }
                }

                if config.rtmpURL.lowercased().hasPrefix("srt://") {
                    labeled("SRT latency (ms)") {
                        TextField("120", value: $config.srtLatencyMs, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 70)
                    }
                    Text("Buffer for retransmission. Lower = less delay, less tolerance to packet loss. 80–200 ms is the usual range.")
                        .font(.custom("SofiaPro", size: 10))
                        .foregroundStyle(Color.white.opacity(0.4))
                }

                labeled("Stream Key") {
                    TextField("Your stream key", text: $config.streamKey)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: config.streamKey) { v in
                            if config.autoPair, v != config.pairDirectKey { config.autoPair = false }
                        }
                }

                HStack(spacing: 8) {
                    Button {
                        if let s = NSPasteboard.general.string(forType: .string),
                           let parts = StreamConfig.splitRTMPURL(s) {
                            config.rtmpPreset = .custom
                            config.autoPair   = false
                            config.rtmpURL    = parts.base
                            config.streamKey  = parts.key
                            pasteHint = nil
                        } else {
                            pasteHint = "Clipboard isn't a full rtmp:// URL with a key."
                        }
                    } label: {
                        Label("Paste full URL", systemImage: "doc.on.clipboard")
                            .font(.custom("SofiaPro", size: 11))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Paste a combined rtmp://host/app/streamkey and split it into the URL + key fields")

                    Button { showLink.toggle() } label: {
                        Label("Link receiver", systemImage: "link")
                            .font(.custom("SofiaPro", size: 11))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Show a code the receivers can use, instead of pasting URLs by hand")
                    .popover(isPresented: $showLink, arrowEdge: .bottom) { linkPopover }
                    if let hint = pasteHint {
                        Text(hint)
                            .font(.custom("SofiaPro", size: 10))
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                }
            }

            divider

            // ── Failsafe ──────────────────────────────────────────────────────
            sectionContent {
                sectionHeader("Failsafe")

                labeled("Backup destination (optional)") {
                    TextField("rtmp://backup…/key", text: $config.backupRTMPURL)
                        .textFieldStyle(.roundedBorder)
                }

                Toggle(isOn: $config.safetyRecording) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Safety recording")
                            .font(.custom("SofiaPro", size: 12))
                            .foregroundStyle(.white)
                        Text("Records the program to disk while streaming (~/Documents/TurboStreamer Recordings).")
                            .font(.custom("SofiaPro", size: 10))
                            .foregroundStyle(Color.white.opacity(0.4))
                    }
                }

                Toggle(isOn: $config.adaptiveBitrate) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Adaptive bitrate")
                            .font(.custom("SofiaPro", size: 12))
                            .foregroundStyle(.white)
                        Text("Lowers bitrate automatically when the connection is unstable, then steps back up.")
                            .font(.custom("SofiaPro", size: 10))
                            .foregroundStyle(Color.white.opacity(0.4))
                    }
                }

                Toggle(isOn: $config.fallbackEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Fallback on input loss")
                            .font(.custom("SofiaPro", size: 12))
                            .foregroundStyle(.white)
                        Text("Holds the most recent frame on-air if the input drops, so viewers see recent content instead of black.")
                            .font(.custom("SofiaPro", size: 10))
                            .foregroundStyle(Color.white.opacity(0.4))
                    }
                }

                if config.fallbackEnabled {
                    labeled("Custom card (optional — overrides the recent frame)") {
                        HStack(spacing: 8) {
                            Button("Choose…") { pickFallback() }
                                .buttonStyle(.bordered)
                            if config.fallbackMediaPath.isEmpty {
                                Text("Using most recent frame")
                                    .font(.custom("SofiaPro", size: 11))
                                    .foregroundStyle(Color.white.opacity(0.3))
                            } else {
                                Text(URL(fileURLWithPath: config.fallbackMediaPath).lastPathComponent)
                                    .font(.custom("SofiaPro", size: 11))
                                    .foregroundStyle(Color.white.opacity(0.55))
                                    .lineLimit(1).truncationMode(.middle)
                                    .help(config.fallbackMediaPath)
                                Button {
                                    config.fallbackMediaPath = ""
                                } label: { Image(systemName: "xmark.circle.fill") }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(Color.white.opacity(0.3))
                            }
                            Spacer()
                        }
                    }
                }

                HStack(spacing: 4) {
                    Image(systemName: "shield.lefthalf.filled")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.white.opacity(0.25))
                    Text("Auto-reconnect, hang/freeze detection, and pre-flight checks are always on.")
                        .font(.custom("SofiaPro", size: 10))
                        .foregroundStyle(Color.white.opacity(0.3))
                }
            }

            divider

            // ── Text overlay ───────────────────────────────────────────────────
            sectionContent {
                OverlayEditor(config: $config)
            }

            divider

            // ── Video ─────────────────────────────────────────────────────────
            sectionContent {
                sectionHeader("Video")

                labeled("Resolution") {
                    Picker("", selection: $config.resolution) {
                        ForEach(ResolutionPreset.allCases) { r in Text(r.rawValue).tag(r) }
                    }
                    .labelsHidden()
                    .onChange(of: config.resolution) { newResolution in
                        // Auto-fill a sensible bitrate for the chosen resolution
                        config.videoBitrate = newResolution.defaultBitrate
                    }
                }

                labeled("Codec") {
                    Picker("", selection: $config.videoCodec) {
                        ForEach(VideoCodec.allCases) { c in Text(c.label).tag(c) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 220)
                    .help("Auto: x264 up to 1080p; hardware H.264 at 4K up to 30 fps; at 4K above 30 fps, HEVC to Turbo Receiver (SRT) or x264 to platforms. Most platforms don't accept HEVC — pick it only for Turbo Receiver or YouTube.")
                }

                HStack(spacing: 12) {
                    labeled("Video Bitrate") {
                        TextField("5872k", text: $config.videoBitrate)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                    }
                    labeled("FPS") {
                        TextField("25", text: $config.fps)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 60)
                            .disabled(config.fpsMatchSource)
                            .opacity(config.fpsMatchSource ? 0.45 : 1)
                    }
                    if config.inputType != .decklink || config.deckLinkFormat != .auto {
                        Toggle("Match source", isOn: $config.fpsMatchSource)
                            .toggleStyle(.checkbox)
                            .help("Encode at the source's native frame rate (falls back to the value on the left if it can't be detected)")
                    }
                    labeled("Audio Bitrate") {
                        TextField("128k", text: $config.audioBitrate)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                    }
                    Spacer()
                }
            }

            divider

            // ── Input ─────────────────────────────────────────────────────────
            sectionContent {
                sectionHeader("Input")

                Picker("Source", selection: $config.inputType) {
                    ForEach(InputType.allCases) { t in Text(t.rawValue).tag(t) }
                }
                .pickerStyle(.segmented)
                .onChange(of: config.inputType) { newType in
                    // DeckLink can only match the source when its format is explicit.
                    if newType == .decklink && config.deckLinkFormat == .auto { config.fpsMatchSource = false }
                }

                if config.inputType == .file {
                    fileInputSection
                } else if config.inputType == .decklink {
                    deckLinkInputSection
                } else if config.inputType == .network {
                    networkInputSection
                } else {
                    captureInputSection
                }
            }
        }
        .background(Color(red: 0.10, green: 0.10, blue: 0.10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        )
        .onAppear { scanIfNeeded() }
        .onChange(of: config.inputType) { _ in scanIfNeeded() }
        // Live preview updates are driven centrally from StreamManager.configs.didSet.
    }

    // MARK: - File input

    @ViewBuilder
    private var fileInputSection: some View {
        HStack {
            Button("Choose File…") { pickFile() }
                .buttonStyle(.bordered)

            if config.filePath.isEmpty {
                Text("No file selected")
                    .font(.custom("SofiaPro", size: 11))
                    .foregroundStyle(Color.white.opacity(0.3))
            } else {
                Text(URL(fileURLWithPath: config.filePath).lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .font(.custom("SofiaPro", size: 11))
                    .foregroundStyle(Color.white.opacity(0.55))
                    .help(config.filePath)
            }
            Spacer()
        }
    }

    // MARK: - Blackmagic DeckLink input

    @ViewBuilder
    private var deckLinkInputSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            labeled("Device") {
                HStack(spacing: 8) {
                    Picker("", selection: $config.deckLinkDeviceName) {
                        if manager.deckLinkDevices.isEmpty {
                            Text(config.deckLinkDeviceName.isEmpty ? "No devices found" : config.deckLinkDeviceName)
                                .tag(config.deckLinkDeviceName)
                        }
                        ForEach(manager.deckLinkDevices) { d in
                            Text(d.name).tag(d.name)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 340)

                    RefreshButton(isSpinning: manager.isScanningDevices) {
                        await manager.refreshDeckLinkDevices()
                    }
                    Spacer()
                }
            }

            HStack(spacing: 12) {
                labeled("Format") {
                    Picker("", selection: $config.deckLinkFormat) {
                        ForEach(DeckLinkFormat.allCases) { f in Text(f.label).tag(f) }
                    }
                    .labelsHidden()
                    .frame(width: 140)
                    .onChange(of: config.deckLinkFormat) { f in
                        if f == .auto { config.fpsMatchSource = false }
                    }
                }
                labeled("Connector") {
                    Picker("", selection: $config.deckLinkConnector) {
                        ForEach(DeckLinkConnector.allCases) { c in Text(c.label).tag(c) }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                }
                labeled("Depth") {
                    Toggle("10-bit", isOn: $config.deckLinkTenBit)
                        .toggleStyle(.checkbox)
                        .help("Capture 10-bit 4:2:2. Kept through to the output only with the HEVC hardware encoder (main10); other encoders convert to 8-bit.")
                }
                Spacer()
            }

            HStack(spacing: 4) {
                Image(systemName: "info.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.white.opacity(0.25))
                Text("Audio is captured automatically with the selected device. Auto-detect needs a card with input format detection; pick the exact format if no picture arrives, or to use Match source.")
                    .font(.custom("SofiaPro", size: 10))
                    .foregroundStyle(Color.white.opacity(0.3))
            }
        }
    }

    // MARK: - Capture card input

    @ViewBuilder
    private var captureInputSection: some View {
        HStack(alignment: .bottom, spacing: 12) {
            labeled("Video Device") {
                Picker("", selection: $config.videoDeviceIndex) {
                    if manager.avVideoDevices.isEmpty {
                        Text("No devices").tag(config.videoDeviceIndex)
                    }
                    ForEach(manager.avVideoDevices) { d in
                        Text("\(d.index) · \(d.name)").tag(d.index)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 230)
            }
            labeled("Audio Device") {
                Picker("", selection: $config.audioDeviceIndex) {
                    Text("None").tag("")
                    ForEach(manager.avAudioDevices) { d in
                        Text("\(d.index) · \(d.name)").tag(d.index)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 230)
            }
            RefreshButton(isSpinning: manager.isScanningDevices) {
                await manager.refreshAVDevices()
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var linkPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Link receivers")
                .font(.custom("SofiaPro-SemiBold", size: 13))

            if let session = linkSession {
                Text("Type this code into each Turbo Receiver:")
                    .font(.custom("SofiaPro", size: 11))
                    .foregroundStyle(.secondary)
                Text(session.code)
                    .font(.system(size: 30, weight: .bold, design: .monospaced))
                    .textSelection(.enabled)

                Divider()

                if linkReceivers.isEmpty {
                    Text("Waiting for a receiver to join…")
                        .font(.custom("SofiaPro", size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(linkReceivers.count) receiver\(linkReceivers.count == 1 ? "" : "s") joined")
                        .font(.custom("SofiaPro", size: 11))
                        .foregroundStyle(.secondary)
                    ForEach(linkReceivers) { r in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(r.label).font(.custom("SofiaPro-SemiBold", size: 12))
                                Text("\(r.url) · key \(r.streamKey)")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                                if r.isLANOnly {
                                    Text("LAN address — only reachable from that receiver's own network. From anywhere else, use the relay below.")
                                        .font(.custom("SofiaPro", size: 10))
                                        .foregroundStyle(.orange.opacity(0.85))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            Spacer(minLength: 4)
                            if let relay = session.relay {
                                Button("Use (auto)") {
                                    config.rtmpPreset      = .custom
                                    config.autoPair        = true
                                    config.pairDirectURL   = r.url        // srt://<receiver>:8890
                                    config.pairDirectKey   = r.streamKey
                                    config.pairRelaySRTURL = relay.srtURL
                                    config.pairRelaySRTKey = relay.streamKey
                                    config.pairRelayRTMPURL = relay.rtmpURL
                                    config.pairRelayRTMPKey = relay.rtmpKey
                                    config.pairCode        = session.code
                                    config.pairSecret      = session.secret
                                    config.srtLatencyMs    = r.latencyMs
                                    // keep rtmpURL sane for the validation hint
                                    config.rtmpURL         = r.url
                                    config.streamKey       = r.streamKey
                                    showLink = false
                                }
                                .buttonStyle(.borderedProminent).controlSize(.small)
                                .help("Automatic: tries the direct path first, then the relay over SRT, then RTMP — falling back on its own and warning you which is live.")
                            }
                            Button("Direct only") {
                                config.rtmpPreset   = .custom
                                config.autoPair     = false
                                config.rtmpURL      = r.url
                                config.streamKey    = r.streamKey
                                config.srtLatencyMs = r.latencyMs
                                config.altRTMPURL   = ""
                                config.altStreamKey = ""
                                showLink = false
                            }
                            .buttonStyle(.bordered).controlSize(.small)
                        }
                    }
                    Text("With more than one receiver, use one per stream: add a stream and pick the next.")
                        .font(.custom("SofiaPro", size: 10))
                        .foregroundStyle(Color.white.opacity(0.4))
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let relay = session.relay {
                    Divider()
                    Text("Or go through the relay — works from anywhere, no port forwarding; every receiver pulls from it:")
                        .font(.custom("SofiaPro", size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Text("\(relay.srtURL) · path \(relay.path)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 4)
                        Button("Use relay") {
                            config.rtmpPreset   = .custom
                            config.rtmpURL      = relay.srtURL
                            config.streamKey    = relay.streamKey
                            config.srtLatencyMs = relay.latencyMs
                            config.altRTMPURL   = relay.rtmpURL
                            config.altStreamKey = relay.rtmpKey
                            showLink = false
                        }
                        .buttonStyle(.bordered).controlSize(.small)
                    }
                    Text("SRT over UDP, and if UDP is blocked where you are it switches to RTMP to the same relay by itself at start. On each Turbo Receiver: Link with this code, then set the feed to Relay.")
                        .font(.custom("SofiaPro", size: 10))
                        .foregroundStyle(Color.white.opacity(0.4))
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("Creates a short code. Each receiver enters it and tells this app where to send the stream, so no URL is typed by hand. Direct: the video never touches the server. Relay: it passes through our relay, for when there's no direct path.")
                    .font(.custom("SofiaPro", size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(linkBusy ? "Creating…" : "Create code") { createLinkSession() }
                    .buttonStyle(.borderedProminent)
                    .disabled(linkBusy)
            }

            if let e = linkError {
                Text(e).font(.custom("SofiaPro", size: 11)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(width: 400)
        .onDisappear { linkPoll?.cancel(); linkPoll = nil }
    }

    private func createLinkSession() {
        linkBusy = true; linkError = nil
        Task {
            do {
                let s = try await LinkClient.createSession(name: config.name)
                linkSession = s
                startLinkPolling(s)
            } catch {
                linkError = error.localizedDescription
            }
            linkBusy = false
        }
    }

    private func startLinkPolling(_ s: LinkClient.Session) {
        linkPoll?.cancel()
        linkPoll = Task {
            while !Task.isCancelled {
                do { linkReceivers = try await LinkClient.receivers(code: s.code, secret: s.secret) }
                catch { linkError = error.localizedDescription }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private var networkInputSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            labeled("Source URL") {
                TextField("rtsp://192.168.0.107:8554/streamkey", text: $config.networkURL)
                    .textFieldStyle(.roundedBorder)
            }
            Text("RTSP, RTMP, SRT or HTTP. From Turbo Receiver, copy the \u{201C}OBS · Turbo Streamer\u{201D} URL.")
                .font(.custom("SofiaPro", size: 10))
                .foregroundStyle(Color.white.opacity(0.4))
            Toggle("Relay as-is (no re-encode)", isOn: $config.networkPassthrough)
                .toggleStyle(.checkbox)
                .help("Forward the incoming stream untouched: zero added loss and almost no CPU. Resolution, fps, codec, bitrate, overlay, mute and the freeze/black detectors are ignored; the source must already be what the platform accepts (H.264/AAC, keyframe every 2 s). Backup and recording still work.")
            if config.networkPassthrough {
                Text("Passthrough: what arrives is what leaves. Video settings below don't apply.")
                    .font(.custom("SofiaPro", size: 10))
                    .foregroundStyle(.orange.opacity(0.8))
            }
        }
    }

    // MARK: - Device scanning

    private func scanIfNeeded() {
        switch config.inputType {
        case .capture where manager.avVideoDevices.isEmpty:
            Task { await manager.refreshAVDevices() }
        case .decklink where manager.deckLinkDevices.isEmpty:
            Task { await manager.refreshDeckLinkDevices() }
        default:
            break
        }
    }

    // MARK: - Layout helpers

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.07))
            .frame(height: 1)
    }

    @ViewBuilder
    private func sectionContent<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            content()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.custom("SofiaPro-SemiBold", size: 10))
            .foregroundStyle(Color.white.opacity(0.3))
            .kerning(1.2)
    }

    @ViewBuilder
    private func labeled<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.custom("SofiaPro", size: 11))
                .foregroundStyle(Color.white.opacity(0.4))
            content()
        }
    }

    // MARK: - File picker

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.title = "Choose a video file"
        // Build the type list safely — UTType(filenameExtension:) is failable and
        // force-unwrapping it crashes on systems where a UTI isn't registered.
        let extraTypes = ["mov", "mp4", "mkv", "m4v", "ts"].compactMap { UTType(filenameExtension: $0) }
        panel.allowedContentTypes = [.movie, .video, .audio, .mpeg4Movie, .quickTimeMovie] + extraTypes
        panel.allowsOtherFileTypes    = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            config.filePath = url.path
        }
    }

    private func pickFallback() {
        let panel = NSOpenPanel()
        panel.title = "Choose a fallback image or video"
        panel.allowedContentTypes = [.image, .movie, .video, .png, .jpeg,
                                     .mpeg4Movie, .quickTimeMovie]
        panel.allowsOtherFileTypes    = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            config.fallbackMediaPath = url.path
        }
    }
}

// MARK: - Animated refresh button

private struct RefreshButton: View {
    let isSpinning: Bool
    let action: () async -> Void
    @State private var angle: Double = 0

    var body: some View {
        Button {
            Task { await action() }
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 12, weight: .semibold))
                .rotationEffect(.degrees(angle))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help("Refresh device list")
        .onChange(of: isSpinning) { spinning in
            if spinning {
                angle = 0
                withAnimation(.linear(duration: 0.7).repeatForever(autoreverses: false)) {
                    angle = 360
                }
            } else {
                withAnimation(.linear(duration: 0.2)) { angle = 0 }
            }
        }
    }
}
