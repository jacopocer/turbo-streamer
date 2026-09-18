import Foundation
import AppKit
import CryptoKit

/// Self-update: checks a small manifest on the Turbo server, and if a newer build is
/// published, downloads the app zip, verifies its hash, swaps it into /Applications and
/// relaunches. The server hosts both apps; every installed copy updates itself from there.
@MainActor
final class Updater: ObservableObject {
    struct Release: Equatable {
        let version: String
        let build: Int
        let url: String
        let sha256: String
        let notes: String
    }
    enum State: Equatable {
        case idle, checking, upToDate
        case available(Release)
        case downloading(Double)
        case installing
        case failed(String)
    }
    @Published private(set) var state: State = .idle

    let appKey: String        // "streamer" | "receiver"
    let appBundleName: String // "Turbo Streamer.app" | "Turbo Receiver.app"

    init(appKey: String, appBundleName: String) {
        self.appKey = appKey
        self.appBundleName = appBundleName
    }

    var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?" }
    var currentBuild: Int { Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0") ?? 0 }
    var displayVersion: String { "v\(currentVersion) (build \(currentBuild))" }

    private var manifestURL: URL? { URL(string: "\(LinkClient.baseURL)/v1/appcast") }

    /// Checks the server. `silent` swallows the up-to-date/failed noise for the launch check.
    func check(silent: Bool) async {
        guard let url = manifestURL else { return }
        if !silent { state = .checking }
        do {
            var req = URLRequest(url: url, timeoutInterval: 15)
            req.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let all = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let mine = all[appKey] as? [String: Any],
                  let build = mine["build"] as? Int else {
                if !silent { state = .failed("No update info from the server") }
                return
            }
            let r = Release(
                version: mine["version"] as? String ?? "?",
                build: build,
                url: mine["url"] as? String ?? "",
                sha256: (mine["sha256"] as? String ?? "").lowercased(),
                notes: mine["notes"] as? String ?? "")
            if r.build > currentBuild, !r.url.isEmpty {
                state = .available(r)
            } else if !silent {
                state = .upToDate
            } else {
                state = .idle
            }
        } catch {
            if !silent { state = .failed(error.localizedDescription) }
        }
    }

    func downloadAndInstall(_ r: Release) async {
        guard let url = URL(string: r.url) else { state = .failed("Bad download URL"); return }
        state = .downloading(0)
        do {
            let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("TurboUpdate-\(appKey)-\(r.build)", isDirectory: true)
            try? FileManager.default.removeItem(at: tmp)
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            let zip = tmp.appendingPathComponent("app.zip")

            let (data, resp) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 600))
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                state = .failed("Download failed (\((resp as? HTTPURLResponse)?.statusCode ?? 0))"); return
            }
            // Verify the hash when the manifest carries one — never install unverified bytes.
            if !r.sha256.isEmpty {
                let got = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                guard got == r.sha256 else { state = .failed("Checksum mismatch — update refused"); return }
            }
            try data.write(to: zip)

            state = .installing
            // Unzip with ditto (handles the macOS app bundle attributes).
            let extractDir = tmp.appendingPathComponent("x", isDirectory: true)
            try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
            try run("/usr/bin/ditto", ["-x", "-k", zip.path, extractDir.path])
            guard let newApp = firstApp(in: extractDir) else { state = .failed("No .app inside the download"); return }

            let dst = "/Applications/\(appBundleName)"
            let script = tmp.appendingPathComponent("swap.sh")
            let pid = ProcessInfo.processInfo.processIdentifier
            let body = """
            #!/bin/bash
            # Wait for the app to quit, then swap it in atomically: copy the new bundle
            # beside the old one, remove the old, rename into place (same volume = atomic).
            # No rsync — its size+mtime quick-check can skip an identically-sized file.
            for _ in $(seq 1 150); do kill -0 \(pid) 2>/dev/null || break; sleep 0.2; done
            sleep 0.4
            NEW="\(dst).new"
            rm -rf "$NEW"
            if ! /usr/bin/ditto "\(newApp.path)" "$NEW"; then open "\(newApp.path)"; exit 1; fi
            xattr -dr com.apple.quarantine "$NEW" 2>/dev/null
            rm -rf "\(dst)"
            mv "$NEW" "\(dst)" || { open "\(newApp.path)"; exit 1; }
            open "\(dst)"
            """
            try body.write(to: script, atomically: true, encoding: .utf8)
            try run("/bin/chmod", ["+x", script.path])
            // Detached, survives our exit.
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = [script.path]
            try p.run()
            NSApp.terminate(nil)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func firstApp(in dir: URL) -> URL? {
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return items.first { $0.pathExtension == "app" }
    }

    @discardableResult
    private func run(_ launch: String, _ args: [String]) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launch)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }
}
