import SwiftUI

struct SetupView: View {
    @EnvironmentObject var manager: StreamManager
    @State private var streamCount: Int = 1
    @State private var showSaveProfile = false
    @State private var newProfileName  = ""

    var body: some View {
        VStack(spacing: 0) {

            // ── Sub-header ───────────────────────────────────────────────────
            HStack {
                Text("Configure your streams, then press Start.")
                    .font(.custom("SofiaPro", size: 13))
                    .foregroundStyle(Color.white.opacity(0.45))
                Spacer()

                profilesMenu

                // Stream count controls
                HStack(spacing: 6) {
                    Text("Streams:")
                        .font(.custom("SofiaPro", size: 12))
                        .foregroundStyle(Color.white.opacity(0.45))
                    ForEach(1...4, id: \.self) { n in
                        countButton(n)
                    }
                    Menu {
                        ForEach(5...8, id: \.self) { n in
                            Button("\(n)") { setCount(n) }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .foregroundStyle(streamCount > 4 ? Color.accentColor : Color.white.opacity(0.35))
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 28)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Color(red: 0.07, green: 0.07, blue: 0.07))

            Divider().background(Color.white.opacity(0.08))

            // ── Stream cards ─────────────────────────────────────────────────
            ScrollView {
                VStack(spacing: 12) {
                    ForEach($manager.configs) { $config in
                        StreamConfigCard(config: $config)
                    }
                }
                .padding(20)
            }
            .background(Color(red: 0.04, green: 0.04, blue: 0.04))

            // ── Pinned live preview (stays put while settings scroll above) ──
            if manager.anyPreviewing {
                Divider().background(Color.white.opacity(0.08))
                PreviewPanel()
            }

            Divider().background(Color.white.opacity(0.08))

            // ── Footer ───────────────────────────────────────────────────────
            HStack {
                if let hint = validationHint {
                    Label(hint, systemImage: "exclamationmark.triangle.fill")
                        .font(.custom("SofiaPro", size: 12))
                        .foregroundStyle(.orange)
                }
                Spacer()
                Button {
                    if manager.anyPreviewing {
                        manager.stopAllPreviews()
                    } else {
                        for config in manager.configs {
                            Task { await manager.startPreview(for: config) }
                        }
                    }
                } label: {
                    Label(manager.anyPreviewing ? "Stop Preview" : "Preview Streams",
                          systemImage: manager.anyPreviewing ? "eye.slash" : "eye")
                        .font(.custom("SofiaPro-SemiBold", size: 14))
                        .frame(minWidth: 150)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button {
                    manager.startStreams()
                } label: {
                    Label("Start Streams", systemImage: "play.fill")
                        .font(.custom("SofiaPro-SemiBold", size: 14))
                        .frame(minWidth: 150)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(validationHint != nil)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(Color(red: 0.07, green: 0.07, blue: 0.07))
        }
        .alert("Save profile", isPresented: $showSaveProfile) {
            TextField("Profile name", text: $newProfileName)
            Button("Save") {
                manager.saveProfile(named: newProfileName)
                newProfileName = ""
            }
            Button("Cancel", role: .cancel) { newProfileName = "" }
        } message: {
            Text("Save the current stream setup to reuse later.")
        }
        .onChange(of: streamCount) { n in
            manager.setCount(n)
        }
        .onChange(of: manager.configs.count) { n in
            streamCount = n
        }
        .onAppear {
            streamCount = manager.configs.count
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private var profilesMenu: some View {
        Menu {
            Button {
                showSaveProfile = true
            } label: {
                Label("Save current as…", systemImage: "square.and.arrow.down")
            }
            if !manager.savedProfileNames.isEmpty {
                Divider()
                Menu("Load") {
                    ForEach(manager.savedProfileNames, id: \.self) { name in
                        Button(name) { manager.loadProfile(named: name) }
                    }
                }
                Menu("Delete") {
                    ForEach(manager.savedProfileNames, id: \.self) { name in
                        Button(name, role: .destructive) { manager.deleteProfile(named: name) }
                    }
                }
            }
        } label: {
            Label("Profiles", systemImage: "square.stack.3d.up")
                .font(.custom("SofiaPro", size: 12))
                .foregroundStyle(Color.white.opacity(0.7))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func setCount(_ n: Int) {
        streamCount = n
        manager.setCount(n)
    }

    @ViewBuilder
    private func countButton(_ n: Int) -> some View {
        Button("\(n)") { setCount(n) }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .background(streamCount == n ? Color.accentColor.opacity(0.2) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private var validationHint: String? {
        for config in manager.configs {
            if config.streamKey.trimmingCharacters(in: .whitespaces).isEmpty {
                return "\(config.name): stream key is required."
            }
            if config.inputType == .file && config.filePath.isEmpty {
                return "\(config.name): no video file selected."
            }
        }
        return nil
    }
}
