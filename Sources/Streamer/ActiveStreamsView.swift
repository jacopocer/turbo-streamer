import SwiftUI

struct ActiveStreamsView: View {
    @EnvironmentObject var manager: StreamManager

    var body: some View {
        VStack(spacing: 0) {

            // ── Sub-header ───────────────────────────────────────────────────
            HStack {
                Text(manager.runningStreams.isEmpty
                     ? "No streams started yet."
                     : "\(manager.runningStreams.count) stream\(manager.runningStreams.count == 1 ? "" : "s") launched.")
                    .font(.custom("SofiaPro", size: 13))
                    .foregroundStyle(Color.white.opacity(0.45))
                Spacer()
                if !manager.runningStreams.isEmpty && manager.allStopped {
                    Button {
                        manager.clearStopped()
                    } label: {
                        Label("Clear Stopped", systemImage: "trash")
                            .font(.custom("SofiaPro", size: 12))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Color(red: 0.07, green: 0.07, blue: 0.07))

            Divider().background(Color.white.opacity(0.08))

            // ── Stream cards ─────────────────────────────────────────────────
            if manager.runningStreams.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(manager.runningStreams) { record in
                            let status = manager.statuses[record.id] ?? StreamStatus()
                            StreamStatusCard(
                                record: record,
                                status: status,
                                onStop: { manager.stopStream(id: record.id) }
                            )
                        }
                    }
                    .padding(20)
                }
                .background(Color(red: 0.04, green: 0.04, blue: 0.04))
            }

            Divider().background(Color.white.opacity(0.08))

            // ── Footer ───────────────────────────────────────────────────────
            HStack {
                Spacer()
                Button {
                    manager.stopAll()
                } label: {
                    Label("Stop All", systemImage: "stop.fill")
                        .font(.custom("SofiaPro-SemiBold", size: 14))
                        .frame(minWidth: 130)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
                .disabled(!manager.hasActiveStreams)
                .keyboardShortcut(".", modifiers: .command)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(Color(red: 0.07, green: 0.07, blue: 0.07))
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 48))
                .foregroundStyle(Color.white.opacity(0.15))
            Text("No active streams")
                .font(.custom("SofiaPro-SemiBold", size: 16))
                .foregroundStyle(Color.white.opacity(0.3))
            Text("Go to Configure and press Start Streams.")
                .font(.custom("SofiaPro", size: 13))
                .foregroundStyle(Color.white.opacity(0.2))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(60)
        .background(Color(red: 0.04, green: 0.04, blue: 0.04))
    }
}
