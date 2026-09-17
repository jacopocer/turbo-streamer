import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var server: ServerManager
    @State private var newKeyName = ""
    @State private var showLog = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Color.white.opacity(0.08))

            ScrollView {
                VStack(spacing: 12) {
                    ForEach(server.keys) { key in feedCard(key) }
                }
                .padding(16)
            }
            .background(Color(red: 0.05, green: 0.05, blue: 0.05))

            Divider().background(Color.white.opacity(0.08))
            footer

            if showLog {
                Divider().background(Color.white.opacity(0.08))
                logPanel
            }
        }
        .background(Color(red: 0.08, green: 0.08, blue: 0.08))
        .onAppear { server.refreshAddresses() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(server.isRunning ? Color.green : Color.white.opacity(0.25))
                .frame(width: 9, height: 9)
            Text("Turbo Receiver")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
            Text(server.isRunning ? "running" : "stopped")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Spacer()

            Picker("", selection: $server.selectedAddress) {
                ForEach(server.addresses, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .frame(width: 150)
            .help("Address the senders and readers should use. 100.x = Tailscale.")

            Button { server.refreshAddresses() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help("Re-scan network interfaces")

            Button(server.isRunning ? "Stop" : "Start") {
                server.isRunning ? server.stop() : server.start()
            }
            .buttonStyle(.borderedProminent)
            .tint(server.isRunning ? .red : .accentColor)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(red: 0.10, green: 0.10, blue: 0.10))
    }

    // MARK: - Feed card

    @ViewBuilder
    private func feedCard(_ key: IngestKey) -> some View {
        let st = server.statuses[key.key]
        let live = st?.ready == true

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(live ? Color.green : Color.orange.opacity(0.6))
                    .frame(width: 8, height: 8)
                Text(key.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Text(live ? "LIVE" : "waiting for publisher")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(live ? .green : .secondary)

                Spacer()

                if live, let st {
                    metric("\(st.kbps) kbps")
                    metric(st.trackSummary)
                    metric("\(st.readers) reader\(st.readers == 1 ? "" : "s")")
                }

                Button {
                    server.toggleNDI(key)
                } label: {
                    let on = server.ndiEnabled.contains(key.key)
                    Label("NDI", systemImage: on ? "antenna.radiowaves.left.and.right"
                                                 : "antenna.radiowaves.left.and.right.slash")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(on ? Color.accentColor : Color.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .disabled(!server.ndiAvailable || (!live && !server.ndiEnabled.contains(key.key)))
                .help(server.ndiAvailable
                      ? "Publish this feed as an NDI source on the LAN (for the BirdDog decoders)"
                      : "NDI unavailable — needs NDI Tools installed and ndi-sender bundled")

                Menu {
                    Button("Regenerate key") { server.regenerateKey(key) }
                    Divider()
                    Button("Remove", role: .destructive) { server.removeKey(key) }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton)
                .frame(width: 28)
            }

            urlRow("Publish here (Turbo Streamer)", server.ingestURL(key))
            urlRow("Publish low-latency (SRT)",      server.srtURL(key))
            urlRow("OBS · Turbo Streamer (RTSP)",   server.rtspURL(key))
            urlRow("TV · browser (HLS)",            server.hlsURL(key))
        }
        .padding(14)
        .background(Color(red: 0.12, green: 0.12, blue: 0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.08), lineWidth: 1))
    }

    private func metric(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color.white.opacity(0.06))
            .clipShape(Capsule())
    }

    private func urlRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 190, alignment: .leading)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
            } label: { Image(systemName: "doc.on.doc") }
            .buttonStyle(.borderless)
            .help("Copy")
        }
    }

    // MARK: - Footer / log

    private var footer: some View {
        HStack(spacing: 8) {
            TextField("New feed name", text: $newKeyName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
                .onSubmit { addKey() }
            Button("Add feed") { addKey() }
                .buttonStyle(.bordered)

            Spacer()

            Button(showLog ? "Hide log" : "Show log") { showLog.toggle() }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(red: 0.10, green: 0.10, blue: 0.10))
    }

    private var logPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(server.logLines.suffix(120).enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.55))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(10)
        }
        .frame(height: 150)
        .background(Color.black.opacity(0.4))
    }

    private func addKey() {
        server.addKey(named: newKeyName.trimmingCharacters(in: .whitespaces))
        newKeyName = ""
    }
}
