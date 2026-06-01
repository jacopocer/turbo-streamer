import SwiftUI
import AppKit

struct StreamConfigCard: View {
    @Binding var config: StreamConfig
    @EnvironmentObject var manager: StreamManager

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
                    if preset != .custom { config.rtmpURL = preset.defaultURL }
                }

                labeled("RTMP URL") {
                    TextField("rtmps://…", text: $config.rtmpURL)
                        .textFieldStyle(.roundedBorder)
                        .disabled(config.rtmpPreset != .custom)
                        .foregroundStyle(config.rtmpPreset == .custom ? .white : Color.white.opacity(0.4))
                }

                labeled("Stream Key") {
                    TextField("Your stream key", text: $config.streamKey)
                        .textFieldStyle(.roundedBorder)
                }
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

                if config.inputType == .file {
                    fileInputSection
                } else if config.inputType == .decklink {
                    deckLinkInputSection
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

            HStack(spacing: 4) {
                Image(systemName: "info.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.white.opacity(0.25))
                Text("Audio is captured automatically with the selected device.")
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
        panel.allowedContentTypes = [.movie, .video, .audio, .mpeg4Movie,
                                     .quickTimeMovie,
                                     .init(filenameExtension: "mov")!,
                                     .init(filenameExtension: "mp4")!,
                                     .init(filenameExtension: "mkv")!]
        panel.allowsOtherFileTypes    = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            config.filePath = url.path
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
