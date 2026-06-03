import SwiftUI
import AppKit

/// Displays one stream's live preview frame, refreshing ~12 fps. Fills the space it's given.
struct LivePreviewBox: View {
    let configID: UUID
    @EnvironmentObject var manager: StreamManager
    @State private var image: NSImage?

    private let ticker = Timer.publish(every: 1.0 / 12.0, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(Color.black)
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                VStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Starting preview…")
                        .font(.custom("SofiaPro", size: 11)).foregroundStyle(Color.white.opacity(0.4))
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.12), lineWidth: 1))
        .onReceive(ticker) { _ in
            let url = manager.previewImageURL(for: configID)
            if let data = try? Data(contentsOf: url), let img = NSImage(data: data) { image = img }
        }
    }
}

/// Pinned, vertically-resizable panel that holds the live previews of all
/// currently-previewing streams. Stays put while the settings scroll above it.
struct PreviewPanel: View {
    @EnvironmentObject var manager: StreamManager
    @State private var panelHeight: CGFloat = 280
    @State private var heightAtDragStart: CGFloat?

    var body: some View {
        let configs = manager.configs.filter { manager.isPreviewing($0.id) }
        VStack(spacing: 0) {
            resizeHandle
            HStack(alignment: .top, spacing: 10) {
                ForEach(configs) { cfg in
                    VStack(spacing: 4) {
                        HStack(spacing: 5) {
                            Circle().fill(Color.green).frame(width: 6, height: 6)
                            Text("PREVIEW · \(cfg.name)")
                                .font(.custom("SofiaPro-SemiBold", size: 10))
                                .foregroundStyle(Color.white.opacity(0.55))
                        }
                        LivePreviewBox(configID: cfg.id)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            .frame(height: panelHeight)
            .frame(maxWidth: .infinity)
        }
        .background(Color.black)
    }

    private var resizeHandle: some View {
        ZStack {
            Rectangle().fill(Color(red: 0.07, green: 0.07, blue: 0.07))
            RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.22)).frame(width: 46, height: 5)
        }
        .frame(height: 14)
        .contentShape(Rectangle())
        .help("Drag to resize the preview")
        .gesture(
            DragGesture()
                .onChanged { v in
                    let start = heightAtDragStart ?? panelHeight
                    if heightAtDragStart == nil { heightAtDragStart = panelHeight }
                    // panel is anchored at the bottom: dragging up grows it
                    panelHeight = min(640, max(160, start - v.translation.height))
                }
                .onEnded { _ in heightAtDragStart = nil }
        )
        .onHover { inside in
            if inside { NSCursor.resizeUpDown.set() } else { NSCursor.arrow.set() }
        }
    }
}
