import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Configure the text overlay. The result shows up in the live preview
/// (started with "Preview Streams") and on-air when streaming.
struct OverlayEditor: View {
    @Binding var config: StreamConfig
    @EnvironmentObject var manager: StreamManager

    private let swatches: [(name: String, hex: String)] = [
        ("White", "FFFFFF"), ("Black", "000000"), ("Yellow", "FFD400"),
        ("Red", "FF3B30"), ("Cyan", "33D6FF"), ("Green", "34C759"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header("Text Overlay")

            Toggle(isOn: $config.overlay.enabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Enable text overlay")
                        .font(.custom("SofiaPro", size: 12)).foregroundStyle(.white)
                    Text("Shows in the live preview and on-air. Editable live from the Live tab while streaming.")
                        .font(.custom("SofiaPro", size: 10)).foregroundStyle(Color.white.opacity(0.4))
                }
            }

            if config.overlay.enabled {
                // ── Text ─────────────────────────────────────────────────────
                label("Text (multiple lines = paragraphs)")
                TextEditor(text: $config.overlay.text)
                    .font(.custom("SofiaPro", size: 12))
                    .foregroundStyle(.white)
                    .scrollContentBackground(.hidden)
                    .frame(height: 56)
                    .padding(6)
                    .background(Color.black.opacity(0.4))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.12), lineWidth: 1))

                // ── Font ─────────────────────────────────────────────────────
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        label("Font")
                        Picker("", selection: $config.overlay.fontChoice) {
                            ForEach(TextOverlay.bundledFonts, id: \.name) { Text($0.name).tag($0.name) }
                            Text(TextOverlay.customFontLabel).tag(TextOverlay.customFontLabel)
                        }
                        .labelsHidden()
                        .frame(width: 180)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        label("Size")
                        Stepper("\(config.overlay.fontSize) pt", value: $config.overlay.fontSize, in: 12...240, step: 2)
                            .font(.custom("SofiaPro", size: 12))
                    }
                    Spacer()
                }

                if config.overlay.fontChoice == TextOverlay.customFontLabel {
                    HStack(spacing: 8) {
                        Button("Choose Font…") { pickFont() }.buttonStyle(.bordered).controlSize(.small)
                        Text(config.overlay.customFontPath.isEmpty
                             ? "No font chosen (.otf / .ttf)"
                             : URL(fileURLWithPath: config.overlay.customFontPath).lastPathComponent)
                            .font(.custom("SofiaPro", size: 11))
                            .foregroundStyle(Color.white.opacity(config.overlay.customFontPath.isEmpty ? 0.3 : 0.6))
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                    }
                }

                // ── Color ────────────────────────────────────────────────────
                label("Colour")
                HStack(spacing: 6) {
                    ForEach(swatches, id: \.hex) { sw in
                        Circle()
                            .fill(Color(hex: sw.hex))
                            .frame(width: 20, height: 20)
                            .overlay(Circle().stroke(Color.white.opacity(config.overlay.colorHex == sw.hex ? 0.9 : 0.2),
                                                     lineWidth: config.overlay.colorHex == sw.hex ? 2 : 1))
                            .onTapGesture { config.overlay.colorHex = sw.hex }
                    }
                    Text("#")
                        .font(.custom("SofiaPro", size: 11)).foregroundStyle(Color.white.opacity(0.4))
                    TextField("FFFFFF", text: $config.overlay.colorHex)
                        .textFieldStyle(.roundedBorder).frame(width: 80)
                    Spacer()
                }

                // ── Position + box ───────────────────────────────────────────
                label("Position")
                Picker("", selection: $config.overlay.position) {
                    ForEach(OverlayPosition.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()

                Toggle(isOn: $config.overlay.boxEnabled) {
                    Text("Background box (improves legibility)")
                        .font(.custom("SofiaPro", size: 12)).foregroundStyle(.white)
                }
                if config.overlay.boxEnabled {
                    HStack(spacing: 8) {
                        Text("Box opacity").font(.custom("SofiaPro", size: 11)).foregroundStyle(Color.white.opacity(0.4))
                        Slider(value: $config.overlay.boxOpacity, in: 0...1)
                        Text(String(format: "%.0f%%", config.overlay.boxOpacity * 100))
                            .font(.custom("SofiaPro", size: 11)).foregroundStyle(Color.white.opacity(0.5))
                            .frame(width: 38, alignment: .trailing)
                    }
                }

                if manager.isPreviewing(config.id) {
                    Text("Tip: text updates live in the preview. Font/size/colour changes apply when you restart the preview.")
                        .font(.custom("SofiaPro", size: 10)).foregroundStyle(Color.white.opacity(0.35))
                }
            }
        }
    }

    // MARK: - Helpers

    private func pickFont() {
        let panel = NSOpenPanel()
        panel.title = "Choose a font"
        panel.allowedContentTypes = ["otf", "ttf", "ttc"].compactMap { UTType(filenameExtension: $0) }
        panel.allowsOtherFileTypes    = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            config.overlay.customFontPath = url.path
        }
    }

    @ViewBuilder private func header(_ t: String) -> some View {
        Text(t.uppercased())
            .font(.custom("SofiaPro-SemiBold", size: 10))
            .foregroundStyle(Color.white.opacity(0.3)).kerning(1.2)
    }
    @ViewBuilder private func label(_ t: String) -> some View {
        Text(t).font(.custom("SofiaPro", size: 11)).foregroundStyle(Color.white.opacity(0.4))
    }
}

// MARK: - Color from hex

extension Color {
    init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")).uppercased()
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        let r = Double((v >> 16) & 0xFF) / 255
        let g = Double((v >> 8) & 0xFF) / 255
        let b = Double(v & 0xFF) / 255
        self = Color(red: r, green: g, blue: b)
    }
}
