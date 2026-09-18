import SwiftUI

/// Wraps the app: the main UI, a self-update banner, and a first-run wizard that
/// gets the operator onto the Turbo network with the right account.
struct RootView: View {
    @EnvironmentObject var server: ServerManager
    @StateObject private var updater = Updater(appKey: "receiver", appBundleName: "Turbo Receiver.app")
    @AppStorage("TurboReceiver.didOnboard") private var didOnboard = false
    @State private var showOnboard = false

    var body: some View {
        VStack(spacing: 0) {
            if case .available(let r) = updater.state {
                UpdateBanner(release: r, updater: updater)
            }
            ContentView()
                .environmentObject(server)
        }
        .sheet(isPresented: $showOnboard) {
            OnboardingView(net: server.turboNet, appTitle: "Turbo Receiver",
                           blurb: "Receive a Turbo Streamer feed and share it on your network — OBS, browsers, and NDI to TVs.") {
                didOnboard = true; showOnboard = false
            }
        }
        .onAppear {
            if !didOnboard { showOnboard = true }
            Task { await updater.check(silent: true) }
        }
        .environmentObject(updater)
    }
}

struct UpdateBanner: View {
    let release: Updater.Release
    @ObservedObject var updater: Updater

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 1) {
                Text("Update available — v\(release.version) (build \(release.build))")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                if !release.notes.isEmpty {
                    Text(release.notes).font(.system(size: 11)).foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                }
            }
            Spacer()
            switch updater.state {
            case .downloading:
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Downloading…").font(.system(size: 11)).foregroundStyle(.white) }
            case .installing:
                Text("Installing…").font(.system(size: 11)).foregroundStyle(.white)
            default:
                Button("Update & Relaunch") { Task { await updater.downloadAndInstall(release) } }
                    .buttonStyle(.borderedProminent).controlSize(.small).tint(.white)
                    .foregroundStyle(.black)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Color.accentColor)
    }
}

/// First-run wizard. Two steps: what the app is, then join the Turbo network with the
/// reference account. Kept deliberately short.
struct OnboardingView: View {
    @ObservedObject var net: TurboNet
    let appTitle: String
    let blurb: String
    let done: () -> Void

    /// The account both apps must sign in to — same tailnet on every machine.
    private let account = "garibaldi@indigital.tv"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 22)).foregroundStyle(Color.accentColor)
                Text("Welcome to \(appTitle)").font(.system(size: 18, weight: .bold))
            }
            Text(blurb).font(.system(size: 13)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Text("Join the Turbo network").font(.system(size: 14, weight: .semibold))
            Text("This connects the Turbo apps privately, so a Receiver is reachable from anywhere. It's built in — no separate install.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                Image(systemName: "person.crop.circle").foregroundStyle(.orange)
                Text("Sign in with this account, on every machine:").font(.system(size: 12))
                Text(account).font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .textSelection(.enabled).foregroundStyle(.orange)
            }
            .padding(10)
            .background(Color.orange.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            statusRow

            Spacer(minLength: 0)

            HStack {
                Button("Skip for now") { done() }.buttonStyle(.bordered)
                Spacer()
                switch net.state {
                case .up:
                    Button("Done") { done() }.buttonStyle(.borderedProminent)
                case .needsLogin:
                    Button("Open login page") { net.openLogin() }.buttonStyle(.borderedProminent)
                default:
                    Button("Connect") { Task { await net.start() } }.buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(24)
        .frame(width: 460, height: 400)
        .onAppear { Task { await net.start() } }
    }

    @ViewBuilder private var statusRow: some View {
        HStack(spacing: 8) {
            switch net.state {
            case .off:
                Image(systemName: "circle").foregroundStyle(.secondary)
                Text("Not connected yet.").font(.system(size: 12)).foregroundStyle(.secondary)
            case .starting:
                ProgressView().controlSize(.small)
                Text("Connecting…").font(.system(size: 12)).foregroundStyle(.secondary)
            case .needsLogin:
                Image(systemName: "person.crop.circle.badge.exclamationmark").foregroundStyle(.orange)
                Text("Click “Open login page”, then sign in with \(account). It's remembered afterwards.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .up:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Connected as \(net.ip). You're on the Turbo network.")
                    .font(.system(size: 12)).foregroundStyle(.green)
            case .failed(let m):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(m).font(.system(size: 12)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
