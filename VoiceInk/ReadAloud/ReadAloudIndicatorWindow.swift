import SwiftUI
import AppKit

/// Tiny floating indicator that shows while a read-aloud session is active.
///
/// Sits above the menu bar as a `nonactivatingPanel` so it never steals focus.
/// Left-click toggles pause/resume; right-click (or the "×" affordance) stops.
@MainActor
final class ReadAloudIndicatorWindow {
    private var panel: IndicatorPanel?
    private weak var manager: ReadAloudManager?

    init(manager: ReadAloudManager) {
        self.manager = manager
    }

    func show() {
        if panel == nil { initialize() }
        panel?.show()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func initialize() {
        guard let manager else { return }
        let rect = IndicatorPanel.metrics()
        let newPanel = IndicatorPanel(contentRect: rect)
        let view = ReadAloudIndicatorView(manager: manager)
        newPanel.contentView = NSHostingView(rootView: view)
        panel = newPanel
    }
}

// MARK: - Panel host

private final class IndicatorPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .statusBar
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        titleVisibility = .hidden
    }

    static func metrics() -> NSRect {
        let width: CGFloat = 280
        let height: CGFloat = 44
        guard let screen = NSScreen.main else {
            return NSRect(x: 40, y: 40, width: width, height: height)
        }
        let visible = screen.visibleFrame
        // Top-right corner, just under the menu bar.
        let x = visible.maxX - width - 20
        let y = visible.maxY - height - 12
        return NSRect(x: x, y: y, width: width, height: height)
    }

    func show() {
        setFrame(IndicatorPanel.metrics(), display: true)
        orderFrontRegardless()
    }
}

// MARK: - SwiftUI content

private struct ReadAloudIndicatorView: View {
    @ObservedObject var manager: ReadAloudManager
    @ObservedObject private var settings = ReadAloudSettings.shared

    var body: some View {
        HStack(spacing: 8) {
            statusIcon
                .frame(width: 18, height: 18)

            Text(statusText)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            Spacer(minLength: 4)

            // Rate controls: slower / current rate / faster
            HStack(spacing: 2) {
                Button(action: { manager.slower() }) {
                    Image(systemName: "tortoise.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 20, height: 22)
                        .foregroundStyle(canSlowDown ? Color.primary : Color.secondary.opacity(0.4))
                }
                .buttonStyle(.plain)
                .disabled(!canSlowDown)
                .help(Text("Slower"))

                Text(String(format: "%.1f×", settings.rate))
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 30)
                    .contentTransition(.numericText(value: Double(settings.rate)))

                Button(action: { manager.faster() }) {
                    Image(systemName: "hare.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 20, height: 22)
                        .foregroundStyle(canSpeedUp ? Color.primary : Color.secondary.opacity(0.4))
                }
                .buttonStyle(.plain)
                .disabled(!canSpeedUp)
                .help(Text("Faster"))
            }
            .padding(.horizontal, 2)
            .background(
                Capsule().fill(Color.primary.opacity(0.08))
            )

            Button(action: { manager.togglePlayback() }) {
                Image(systemName: playPauseIcon)
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.primary.opacity(0.12)))
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
            .help(Text(playPauseHelp))

            Button(action: { manager.stop() }) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.red.opacity(0.75)))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .help(Text("Stop reading"))
        }
        .padding(.horizontal, 9)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
                )
        )
        .overlay(alignment: .bottom) {
            GeometryReader { geo in
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: max(2, geo.size.width * CGFloat(manager.progress)), height: 2)
                    .animation(.linear(duration: 0.15), value: manager.progress)
            }
            .frame(height: 2)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private var canSlowDown: Bool {
        settings.rate > ReadAloudManager.minimumRate + 0.001
    }

    private var canSpeedUp: Bool {
        settings.rate < ReadAloudManager.maximumRate - 0.001
    }

    private var statusIcon: some View {
        Group {
            switch manager.state {
            case .idle:
                Image(systemName: "speaker.slash")
                    .foregroundStyle(.secondary)
            case .capturing, .loading:
                ProgressView()
                    .controlSize(.small)
            case .speaking:
                AnimatedSpeakerIcon()
            case .paused:
                Image(systemName: "pause.circle.fill")
                    .foregroundStyle(.orange)
            }
        }
        .font(.system(size: 14, weight: .semibold))
    }

    private var statusText: String {
        switch manager.state {
        case .idle: return String(localized: "Idle")
        case .capturing: return String(localized: "Capturing…")
        case .loading: return String(localized: "Loading…")
        case .speaking: return String(localized: "Reading")
        case .paused: return String(localized: "Paused")
        }
    }

    private var playPauseIcon: String {
        switch manager.state {
        case .paused: return "play.fill"
        default: return "pause.fill"
        }
    }

    private var playPauseHelp: String {
        switch manager.state {
        case .paused: return String(localized: "Resume")
        default: return String(localized: "Pause")
        }
    }
}

private struct AnimatedSpeakerIcon: View {
    @State private var pulse = false

    var body: some View {
        Image(systemName: "speaker.wave.2.fill")
            .foregroundStyle(Color.accentColor)
            .scaleEffect(pulse ? 1.08 : 0.94)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
    }
}
