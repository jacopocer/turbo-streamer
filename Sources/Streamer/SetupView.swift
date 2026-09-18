import SwiftUI

struct SetupView: View {
    @EnvironmentObject var manager: StreamManager
    @EnvironmentObject var updater: Updater
    @State private var streamCount: Int = 1
    @State private var showSaveProfile = false
    @State private var newProfileName  = ""
    @State private var showAlerts      = false
    @State private var showNetwork     = false

    var body: some View {
        VStack(spacing: 0) {

            // ── Sub-header ───────────────────────────────────────────────────
            HStack {
                Text("Configure your streams, then press Start.")
                    .font(.custom("SofiaPro", size: 13))
                    .foregroundStyle(Color.white.opacity(0.45))
                Spacer()

                networkButton

                alertsButton

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
                Text(updater.displayVersion)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.3))
                    .help("Version and build. Click to check for updates.")
                    .onTapGesture { Task { await updater.check(silent: false) } }
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
    private var networkButton: some View {
        let net = manager.turboNet
        let (icon, tint, text): (String, Color, String) = {
            switch net.state {
            case .up:             return ("point.3.connected.trianglepath.dotted", Color.green, net.ip)
            case .starting:       return ("point.3.connected.trianglepath.dotted", Color.secondary, "joining…")
            case .needsLogin:     return ("person.crop.circle.badge.exclamationmark", Color.orange, "login needed")
            case .failed:         return ("point.3.connected.trianglepath.dotted", Color.orange, "off")
            case .off:            return ("point.3.connected.trianglepath.dotted", Color.white.opacity(0.35), "off")
            }
        }()
        Button {
            showNetwork.toggle()
        } label: {
            Label(text, systemImage: icon)
                .font(.custom("SofiaPro", size: 12))
                .foregroundStyle(tint)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help("Turbo network: this app's own Tailscale node. Receivers on it are reachable from anywhere.")
        .popover(isPresented: $showNetwork, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Turbo network")
                    .font(.custom("SofiaPro-SemiBold", size: 13))
                Text("A private network between the Turbo apps, built into the app (Tailscale, no install). A Turbo Receiver that shows a 100.x address is reachable from any network; the stream still goes straight to it, encrypted.")
                    .font(.custom("SofiaPro", size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    switch net.state {
                    case .up:
                        Text("Connected as \(net.ip) · \(net.hostname)").font(.system(size: 11, design: .monospaced))
                        Spacer()
                        Button("Unlink account") { Task { await net.unlinkAccount() } }
                            .buttonStyle(.bordered).controlSize(.small)
                            .help("Forget this login and get a fresh login link (e.g. wrong account)")
                    case .needsLogin:
                        Button("Open login page") { net.openLogin() }.buttonStyle(.borderedProminent).controlSize(.small)
                        Text("One time, then it remembers.").font(.custom("SofiaPro", size: 11)).foregroundStyle(.secondary)
                    case .starting:
                        ProgressView().controlSize(.small); Text("Joining…").font(.custom("SofiaPro", size: 11))
                    case .failed(let m):
                        Text(m).font(.custom("SofiaPro", size: 11)).foregroundStyle(.orange)
                        Button("Retry") { Task { await net.start() } }.buttonStyle(.bordered).controlSize(.small)
                    case .off:
                        Button("Connect") { Task { await net.start() } }.buttonStyle(.borderedProminent).controlSize(.small)
                    }
                    Spacer()
                }
                if !manager.networkLog.isEmpty {
                    Divider()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(manager.networkLog.suffix(12).enumerated()), id: \.offset) { _, l in
                                Text(l).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .frame(maxHeight: 140)
                }
            }
            .padding(16)
            .frame(width: 400)
        }
    }

    @ViewBuilder
    private var alertsButton: some View {
        Button {
            showAlerts.toggle()
        } label: {
            Label("Alerts", systemImage: manager.alertWebhookURL.isEmpty ? "bell.slash" : "bell.badge.fill")
                .font(.custom("SofiaPro", size: 12))
                .foregroundStyle(manager.alertWebhookURL.isEmpty ? Color.white.opacity(0.7) : Color.accentColor)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .popover(isPresented: $showAlerts, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Drop / recover alerts")
                    .font(.custom("SofiaPro-SemiBold", size: 13))
                Text("When a stream drops or comes back, the app sends a small JSON POST — {app, event, stream, message, time} — to this URL. Point it at a Zapier / Make / Slack / Telegram webhook to reach WhatsApp, email, or SMS.")
                    .font(.custom("SofiaPro", size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("https://hooks.zapier.com/…", text: $manager.alertWebhookURL)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Send test") { manager.sendTestAlert() }
                        .buttonStyle(.bordered).controlSize(.small)
                        .disabled(manager.alertWebhookURL.isEmpty)
                    Spacer()
                    Text(manager.alertWebhookURL.isEmpty ? "Off" : "On")
                        .font(.custom("SofiaPro", size: 11))
                        .foregroundStyle(manager.alertWebhookURL.isEmpty ? Color.secondary : .green)
                }
                if let result = manager.alertTestResult {
                    Text(result)
                        .font(.custom("SofiaPro", size: 11))
                        .foregroundStyle(result.hasPrefix("✓") ? Color.green
                                         : result.hasPrefix("⏳") ? Color.secondary : Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
            .frame(width: 380)
        }
    }

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
            if config.inputType == .network && config.networkURL.trimmingCharacters(in: .whitespaces).isEmpty {
                return "\(config.name): no source URL."
            }
            if config.inputType == .file && config.filePath.isEmpty {
                return "\(config.name): no video file selected."
            }
        }
        return nil
    }
}
