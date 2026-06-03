import SwiftUI
import AppKit

/// A live, running preview of a stream's composed output (source + overlay).
/// The box is vertically resizable by dragging the handle at the bottom.
struct LivePreviewBox: View {
    let configID: UUID
    @EnvironmentObject var manager: StreamManager

    @State private var image: NSImage?
    @State private var boxHeight: CGFloat = 260
    @State private var heightAtDragStart: CGFloat?

    // ~12 fps refresh of the latest preview frame written by ffmpeg.
    private let ticker = Timer.publish(every: 1.0 / 12.0, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Rectangle().fill(Color.black)
                if let image {
                    Image(nsImage: image).resizable().scaledToFit()
                } else {
                    VStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Starting preview…")
                            .font(.custom("SofiaPro", size: 11)).foregroundStyle(Color.white.opacity(0.4))
                    }
                }
                // LIVE PREVIEW badge
                VStack {
                    HStack {
                        HStack(spacing: 4) {
                            Circle().fill(Color.green).frame(width: 6, height: 6)
                            Text("PREVIEW").font(.custom("SofiaPro-SemiBold", size: 9)).foregroundStyle(.green)
                        }
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Color.black.opacity(0.5)).clipShape(Capsule())
                        Spacer()
                    }
                    Spacer()
                }
                .padding(8)
            }
            .frame(height: boxHeight)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.12), lineWidth: 1))

            resizeHandle
        }
        .onReceive(ticker) { _ in
            // Read fresh bytes each tick (NSImage(contentsOfFile:) would cache).
            let url = manager.previewImageURL(for: configID)
            if let data = try? Data(contentsOf: url), let img = NSImage(data: data) {
                image = img
            }
        }
    }

    private var resizeHandle: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.white.opacity(0.18))
                .frame(width: 44, height: 5)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 16)
        .contentShape(Rectangle())
        .help("Drag to resize the preview")
        .gesture(
            DragGesture()
                .onChanged { v in
                    let start = heightAtDragStart ?? boxHeight
                    if heightAtDragStart == nil { heightAtDragStart = boxHeight }
                    boxHeight = min(720, max(140, start + v.translation.height))
                }
                .onEnded { _ in heightAtDragStart = nil }
        )
        .onHover { inside in
            if inside { NSCursor.resizeUpDown.set() } else { NSCursor.arrow.set() }
        }
    }
}
