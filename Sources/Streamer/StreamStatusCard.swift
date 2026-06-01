import SwiftUI

struct StreamStatusCard: View {
    let record: RunningStreamRecord
    let status: StreamStatus
    let onStop: () -> Void

    @State private var showLog = false

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── Top row ──────────────────────────────────────────────────────
            HStack(spacing: 10) {
                phaseIndicator

                VStack(alignment: .leading, spacing: 3) {
                    Text(record.config.name)
                        .font(.custom("SofiaPro-SemiBold", size: 14))
                        .foregroundStyle(.white)
                    HStack(spacing: 6) {
                        Text(status.phase.label)
                            .font(.custom("SofiaPro", size: 11))
                            .foregroundStyle(phaseColor)
                        Text("·")
                            .foregroundStyle(Color.white.opacity(0.2))
                        Text("Started \(Self.timeFormatter.string(from: record.startedAt))")
                            .font(.custom("SofiaPro", size: 11))
                            .foregroundStyle(Color.white.opacity(0.3))
                    }
                    if status.phase.isActive { metricsLine }
                    if status.phase.isActive, let warning = status.inputWarning {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 9))
                            Text(warning)
                                .font(.custom("SofiaPro-SemiBold", size: 10))
                        }
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.14))
                        .clipShape(Capsule())
                    }
                }

                Spacer()

                // Log toggle
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { showLog.toggle() }
                } label: {
                    Label(showLog ? "Hide Log" : "Show Log",
                          systemImage: showLog ? "chevron.up" : "text.alignleft")
                        .font(.custom("SofiaPro", size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                // Stop button
                Button { onStop() } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .font(.custom("SofiaPro-SemiBold", size: 11))
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.small)
                .disabled(!status.phase.isActive)
            }
            .padding(14)

            // ── Log file path ─────────────────────────────────────────────────
            HStack(spacing: 4) {
                Image(systemName: "doc.text")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.white.opacity(0.2))
                Text(record.logFileURL.lastPathComponent)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.2))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, showLog ? 0 : 10)

            // ── Log panel ─────────────────────────────────────────────────────
            if showLog {
                Divider().background(Color.white.opacity(0.07))
                logView
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(Color(red: 0.10, green: 0.10, blue: 0.10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(phaseColor.opacity(0.25), lineWidth: 1)
        )
    }

    // MARK: - Sub-views

    @ViewBuilder
    private var phaseIndicator: some View {
        ZStack {
            Circle()
                .fill(phaseColor.opacity(0.15))
                .frame(width: 34, height: 34)
            Image(systemName: phaseIcon)
                .foregroundStyle(phaseColor)
                .font(.system(size: 14, weight: .semibold))
        }
    }

    @ViewBuilder
    private var metricsLine: some View {
        HStack(spacing: 10) {
            TimelineView(.periodic(from: record.startedAt, by: 1)) { context in
                metric("timer", Self.hms(Int(context.date.timeIntervalSince(record.startedAt))))
            }
            if let fps = status.liveFPS, fps != "0.0" {
                metric("speedometer", "\(fps) fps")
            }
            if let br = status.liveBitrate, br != "N/A" {
                metric("antenna.radiowaves.left.and.right", br)
            }
            if let sp = status.liveSpeed {
                metric("gauge.with.dots.needle.67percent", sp)
            }
        }
    }

    @ViewBuilder
    private func metric(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 9))
            Text(text)
                .font(.custom("SofiaPro", size: 10))
        }
        .foregroundStyle(Color.white.opacity(0.45))
    }

    private static func hms(_ seconds: Int) -> String {
        let s = max(0, seconds)
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, sec)
            : String(format: "%02d:%02d", m, sec)
    }

    @ViewBuilder
    private var logView: some View {
        VStack(spacing: 0) {
            HStack {
                Text("LOG")
                    .font(.custom("SofiaPro-SemiBold", size: 10))
                    .foregroundStyle(Color.white.opacity(0.25))
                Spacer()
                Button {
                    let text = status.logLines.joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .font(.custom("SofiaPro", size: 10))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)

                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([record.logFileURL])
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                        .font(.custom("SofiaPro", size: 10))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(status.logLines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(Color.white.opacity(0.7))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        Color.clear
                            .frame(height: 1)
                            .id("bottom")
                    }
                    .padding(10)
                }
                .frame(height: 160)
                .background(Color.black.opacity(0.4))
                .onChange(of: status.logLines.count) { _ in
                    withAnimation { proxy.scrollTo("bottom") }
                }
            }
        }
        .padding(.bottom, 4)
    }

    // MARK: - Helpers

    private var phaseColor: Color {
        switch status.phase {
        case .running:      return .green
        case .reconnecting: return .orange
        case .stopped:      return .red
        case .idle:         return Color.white.opacity(0.3)
        }
    }

    private var phaseIcon: String {
        switch status.phase {
        case .running:      return "dot.radiowaves.left.and.right"
        case .reconnecting: return "arrow.trianglehead.2.clockwise"
        case .stopped:      return "stop.fill"
        case .idle:         return "clock"
        }
    }
}
