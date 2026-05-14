import SwiftUI
import AppKit

struct StreamConfigCard: View {
    @Binding var config: StreamConfig
    @State private var showDeviceSheet = false
    @State private var deviceOutput: String = ""
    @State private var isLoadingDevices = false
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

                Toggle(isOn: $config.useHardwareEncoding) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Hardware Encoding (VideoToolbox)")
                            .font(.custom("SofiaPro", size: 12))
                            .foregroundStyle(.white)
                        Text("Recommended for 4K/ProRes. Uses Apple's hardware H.264 encoder.")
                            .font(.custom("SofiaPro", size: 10))
                            .foregroundStyle(Color.white.opacity(0.4))
                    }
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
        .sheet(isPresented: $showDeviceSheet) {
            DeviceListSheet(output: deviceOutput, isLoading: isLoadingDevices)
                .preferredColorScheme(.dark)
        }
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

    // MARK: - Capture card input

    @ViewBuilder
    private var captureInputSection: some View {
        HStack(spacing: 12) {
            labeled("Video Device #") {
                TextField("0", text: $config.videoDeviceIndex)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 50)
            }
            labeled("Audio Device # (blank = none)") {
                TextField("1", text: $config.audioDeviceIndex)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 50)
            }
            Spacer()
            Button {
                Task {
                    isLoadingDevices = true
                    deviceOutput     = await manager.listDevices()
                    isLoadingDevices = false
                    showDeviceSheet  = true
                }
            } label: {
                Label("List Devices", systemImage: "camera.badge.ellipsis")
                    .font(.custom("SofiaPro", size: 12))
            }
            .buttonStyle(.bordered)
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

// MARK: - Device list sheet

struct DeviceListSheet: View {
    let output: String
    let isLoading: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Available AVFoundation Devices")
                    .font(.custom("SofiaPro-SemiBold", size: 15))
                    .foregroundStyle(.white)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.escape)
            }

            if isLoading {
                ProgressView("Scanning devices…")
                    .frame(maxWidth: .infinity, minHeight: 100)
            } else {
                ScrollView {
                    Text(output.isEmpty ? "No output — is ffmpeg installed?" : output)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.8))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(minHeight: 200, maxHeight: 400)
                .background(Color.black.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            Text("Use the [Video] / [Audio] numbers shown above in the device index fields.")
                .font(.custom("SofiaPro", size: 11))
                .foregroundStyle(Color.white.opacity(0.4))
        }
        .padding(20)
        .frame(width: 560)
        .background(Color(red: 0.10, green: 0.10, blue: 0.10))
    }
}
