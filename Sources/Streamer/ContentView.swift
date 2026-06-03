import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var manager: StreamManager
    @State private var selectedTab = 0

    var body: some View {
        VStack(spacing: 0) {
            appHeader
            Divider().background(Color.white.opacity(0.08))
            tabBar
            Divider().background(Color.white.opacity(0.08))
            tabContent
        }
        .frame(minWidth: 860, maxWidth: 860, maxHeight: .infinity)  // 860-wide column, fills window height
        .frame(maxWidth: .infinity, maxHeight: .infinity)          // center the column; dark margins if wider
        .background(Color(red: 0.04, green: 0.04, blue: 0.04))
    }

    // MARK: - App header

    @ViewBuilder
    private var appHeader: some View {
        HStack(spacing: 12) {
            WobblingIcon(isActive: manager.hasActiveStreams, isTroubled: manager.isTroubled)

            Text("Turbo Streamer")
                .font(.custom("Bello-Pro", size: 28))
                .foregroundStyle(.white)

            Spacer()

            if manager.hasActiveStreams {
                liveBadge
            }

            // Indigital logo — top right
            if let path = Bundle.main.path(forResource: "indigital-logo", ofType: "png"),
               let img  = NSImage(contentsOfFile: path) {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(height: 14)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color.black)
    }

    @ViewBuilder
    private var liveBadge: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(Color.red)
                .frame(width: 7, height: 7)
            Text("LIVE")
                .font(.custom("SofiaPro-SemiBold", size: 11))
                .foregroundStyle(.red)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Color.red.opacity(0.14))
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Color.red.opacity(0.3), lineWidth: 1))
    }

    // MARK: - Custom tab bar

    @ViewBuilder
    private var tabBar: some View {
        HStack(spacing: 0) {
            tabBarButton(label: "Configure", icon: "slider.horizontal.3", tag: 0)
            tabBarButton(label: "Live", icon: "dot.radiowaves.left.and.right", tag: 1, badge: activeBadgeCount)
        }
        .background(Color(red: 0.07, green: 0.07, blue: 0.07))
    }

    @ViewBuilder
    private func tabBarButton(label: String, icon: String, tag: Int, badge: Int = 0) -> some View {
        let isSelected = selectedTab == tag
        Button {
            selectedTab = tag
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                Text(label)
                    .font(.custom("SofiaPro-SemiBold", size: 13))
                if badge > 0 {
                    Text("\(badge)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.red)
                        .clipShape(Capsule())
                }
            }
            .foregroundStyle(isSelected ? .white : Color.white.opacity(0.45))
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(
                isSelected
                    ? Color.white.opacity(0.07)
                    : Color.clear
            )
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                if isSelected {
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(height: 2)
                }
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case 0:  SetupView()
        default: ActiveStreamsView()
        }
    }

    private var activeBadgeCount: Int {
        manager.runningStreams.filter { manager.statuses[$0.id]?.phase.isActive == true }.count
    }
}

// MARK: - Wobbling app icon (rocks side-to-side while streaming)

struct WobblingIcon: View {
    let isActive: Bool
    let isTroubled: Bool

    var body: some View {
        if isActive {
            TimelineView(.animation) { context in
                rocked(at: context.date.timeIntervalSinceReferenceDate)
            }
        } else {
            baseIcon
        }
    }

    private var baseIcon: some View {
        Image(nsImage: NSApplication.shared.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: 36, height: 36)
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func rocked(at t: TimeInterval) -> some View {
        // Healthy: a calm ~1 Hz side-to-side rock.
        // Trouble: faster (~3.6 Hz), wider, with high-frequency jitter + positional shake.
        let freq: Double = isTroubled ? 3.6 : 1.0
        let amp:  Double = isTroubled ? 15  : 11

        let tilt = sin(t * 2 * .pi * freq) * amp
                 + (isTroubled ? sin(t * 41) * 4 : 0)
        let shakeX = isTroubled ? sin(t * 47) * 1.6 + sin(t * 89) * 0.9 : 0
        let shakeY = isTroubled ? sin(t * 53) * 1.2 : 0

        baseIcon
            .rotationEffect(.degrees(tilt), anchor: .bottom)
            .offset(x: shakeX, y: shakeY)
    }
}
