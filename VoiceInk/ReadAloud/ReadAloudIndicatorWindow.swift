import AppKit
import Combine
import QuartzCore

/// Tiny floating indicator that shows while a read-aloud session is active.
///
/// Built with AppKit controls (not SwiftUI `Button`) because SwiftUI button
/// gestures inside a `nonactivatingPanel` crash on macOS 26 via
/// `MainActor.assumeIsolated` during click dispatch.
@MainActor
final class ReadAloudIndicatorWindow {
    private var panel: IndicatorPanel?
    private weak var manager: ReadAloudManager?
    private var contentView: ReadAloudIndicatorContentView?

    init(manager: ReadAloudManager) {
        self.manager = manager
    }

    func show() {
        if panel == nil { initialize() }
        contentView?.refresh()
        panel?.show()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    /// Called on high-frequency playback ticks. Updates the AppKit bar only —
    /// never goes through SwiftUI observation.
    func progressDidChange() {
        contentView?.refreshLiveData()
    }

    private func initialize() {
        guard let manager else { return }
        let rect = IndicatorPanel.metrics()
        let newPanel = IndicatorPanel(contentRect: rect)
        let content = ReadAloudIndicatorContentView(frame: rect, manager: manager)
        newPanel.contentView = content
        contentView = content
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
        let width: CGFloat = 420
        let height: CGFloat = 44
        guard let screen = NSScreen.main else {
            return NSRect(x: 40, y: 40, width: width, height: height)
        }
        let visible = screen.visibleFrame
        let x = visible.maxX - width - 20
        let y = visible.maxY - height - 12
        return NSRect(x: x, y: y, width: width, height: height)
    }

    func show() {
        setFrame(IndicatorPanel.metrics(), display: true)
        orderFrontRegardless()
    }
}

// MARK: - AppKit content (crash-safe clicks)

private final class ReadAloudIndicatorContentView: NSView {
    private weak var manager: ReadAloudManager?
    private var cancellables = Set<AnyCancellable>()

    private let effectView = NSVisualEffectView()
    private let statusImage = NSImageView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let rateLabel = NSTextField(labelWithString: "1.0×")
    private let slowerButton = NSButton()
    private let fasterButton = NSButton()
    private let rewindButton = NSButton()
    private let playPauseButton = NSButton()
    private let forwardButton = NSButton()
    private let nextButton = NSButton()
    private let stopButton = NSButton()
    private let progressLayer = CALayer()

    init(frame: NSRect, manager: ReadAloudManager) {
        self.manager = manager
        super.init(frame: frame)
        wantsLayer = true
        buildUI()
        bind(manager)
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func buildUI() {
        effectView.material = .hudWindow
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 12
        effectView.layer?.masksToBounds = true
        effectView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(effectView)

        statusImage.imageScaling = .scaleProportionallyDown
        statusImage.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        statusLabel.textColor = .labelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        configureIconButton(slowerButton, symbol: "tortoise.fill", size: 10, action: #selector(slowerTapped))
        configureIconButton(fasterButton, symbol: "hare.fill", size: 10, action: #selector(fasterTapped))
        configureIconButton(rewindButton, symbol: "gobackward.5", size: 11, action: #selector(rewindTapped))
        configureIconButton(playPauseButton, symbol: "pause.fill", size: 11, action: #selector(playPauseTapped))
        configureIconButton(forwardButton, symbol: "goforward.5", size: 11, action: #selector(forwardTapped))
        configureIconButton(nextButton, symbol: "forward.end.fill", size: 10, action: #selector(nextTapped))
        configureIconButton(stopButton, symbol: "stop.fill", size: 10, action: #selector(stopTapped))
        stopButton.contentTintColor = .white
        stopButton.wantsLayer = true
        stopButton.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.75).cgColor
        stopButton.layer?.cornerRadius = 11

        rateLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        rateLabel.textColor = .secondaryLabelColor
        rateLabel.alignment = .center
        rateLabel.translatesAutoresizingMaskIntoConstraints = false

        let rateStack = NSStackView(views: [slowerButton, rateLabel, fasterButton])
        rateStack.orientation = .horizontal
        rateStack.spacing = 2
        rateStack.alignment = .centerY
        rateStack.wantsLayer = true
        rateStack.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
        rateStack.layer?.cornerRadius = 11
        rateStack.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 4)
        rateStack.translatesAutoresizingMaskIntoConstraints = false

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let root = NSStackView(views: [
            statusImage,
            statusLabel,
            spacer,
            rateStack,
            rewindButton,
            playPauseButton,
            forwardButton,
            nextButton,
            stopButton
        ])
        root.orientation = .horizontal
        root.spacing = 8
        root.alignment = .centerY
        root.translatesAutoresizingMaskIntoConstraints = false
        root.setHuggingPriority(.defaultLow, for: .horizontal)

        effectView.addSubview(root)

        progressLayer.backgroundColor = NSColor.controlAccentColor.cgColor
        progressLayer.frame = CGRect(x: 0, y: 0, width: 2, height: 2)
        effectView.layer?.addSublayer(progressLayer)

        NSLayoutConstraint.activate([
            effectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: trailingAnchor),
            effectView.topAnchor.constraint(equalTo: topAnchor),
            effectView.bottomAnchor.constraint(equalTo: bottomAnchor),

            root.leadingAnchor.constraint(equalTo: effectView.leadingAnchor, constant: 9),
            root.trailingAnchor.constraint(equalTo: effectView.trailingAnchor, constant: -9),
            root.topAnchor.constraint(equalTo: effectView.topAnchor),
            root.bottomAnchor.constraint(equalTo: effectView.bottomAnchor),

            statusImage.widthAnchor.constraint(equalToConstant: 18),
            statusImage.heightAnchor.constraint(equalToConstant: 18),
            slowerButton.widthAnchor.constraint(equalToConstant: 20),
            slowerButton.heightAnchor.constraint(equalToConstant: 22),
            fasterButton.widthAnchor.constraint(equalToConstant: 20),
            fasterButton.heightAnchor.constraint(equalToConstant: 22),
            rateLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 30),
            rewindButton.widthAnchor.constraint(equalToConstant: 22),
            rewindButton.heightAnchor.constraint(equalToConstant: 22),
            playPauseButton.widthAnchor.constraint(equalToConstant: 22),
            playPauseButton.heightAnchor.constraint(equalToConstant: 22),
            forwardButton.widthAnchor.constraint(equalToConstant: 22),
            forwardButton.heightAnchor.constraint(equalToConstant: 22),
            nextButton.widthAnchor.constraint(equalToConstant: 22),
            nextButton.heightAnchor.constraint(equalToConstant: 22),
            stopButton.widthAnchor.constraint(equalToConstant: 22),
            stopButton.heightAnchor.constraint(equalToConstant: 22)
        ])

        toolTip = nil
        slowerButton.toolTip = String(localized: "Slower")
        fasterButton.toolTip = String(localized: "Faster")
        rewindButton.toolTip = String(localized: "Rewind 5 seconds")
        forwardButton.toolTip = String(localized: "Forward 5 seconds")
        nextButton.toolTip = String(localized: "Skip to next queued selection")
        stopButton.toolTip = String(localized: "Stop reading")
    }

    private func configureIconButton(_ button: NSButton, symbol: String, size: CGFloat, action: Selector) {
        button.bezelStyle = .inline
        button.isBordered = false
        button.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(.init(pointSize: size, weight: .semibold))
        button.imagePosition = .imageOnly
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        button.focusRingType = .none
    }

    private func bind(_ manager: ReadAloudManager) {
        // Only react to coarse state / settings changes — not progress ticks.
        manager.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.refresh() }
            }
            .store(in: &cancellables)

        ReadAloudSettings.shared.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.refresh() }
            }
            .store(in: &cancellables)

        Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.refreshLiveData() }
            .store(in: &cancellables)
    }

    func refresh() {
        guard let manager else { return }
        let settings = ReadAloudSettings.shared

        statusLabel.stringValue = statusText(for: manager)
        statusImage.image = statusImage(for: manager.state)
        statusImage.contentTintColor = statusTint(for: manager.state)

        rateLabel.stringValue = String(format: "%.1f×", settings.rate)
        slowerButton.isEnabled = settings.rate > ReadAloudManager.minimumRate + 0.001
        fasterButton.isEnabled = settings.rate < ReadAloudManager.maximumRate - 0.001
        slowerButton.alphaValue = slowerButton.isEnabled ? 1.0 : 0.4
        fasterButton.alphaValue = fasterButton.isEnabled ? 1.0 : 0.4

        let playSymbol = manager.state == .paused ? "play.fill" : "pause.fill"
        playPauseButton.image = NSImage(
            systemSymbolName: playSymbol,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        playPauseButton.toolTip = manager.state == .paused
            ? String(localized: "Resume")
            : String(localized: "Pause")

        let canSeek = manager.state == .speaking
            || manager.state == .buffering
            || manager.state == .paused
        rewindButton.isEnabled = canSeek
        forwardButton.isEnabled = canSeek
        rewindButton.alphaValue = canSeek ? 1.0 : 0.35
        forwardButton.alphaValue = canSeek ? 1.0 : 0.35

        nextButton.isEnabled = manager.queueCount > 0
        nextButton.alphaValue = nextButton.isEnabled ? 1.0 : 0.35

        refreshLiveData()
    }

    /// Updates lightweight playback data without publishing SwiftUI state.
    func refreshLiveData() {
        guard let manager else { return }
        statusLabel.stringValue = statusText(for: manager)
        let totalWidth = effectView.bounds.width
        guard totalWidth > 0 else { return }
        let width = max(2, totalWidth * CGFloat(manager.progress))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        progressLayer.frame = CGRect(x: 0, y: 0, width: width, height: 2)
        CATransaction.commit()
    }

    private func statusText(for manager: ReadAloudManager) -> String {
        let stateText: String
        switch manager.state {
        case .idle: stateText = String(localized: "Idle")
        case .capturing: stateText = String(localized: "Capturing…")
        case .loading: stateText = String(localized: "Loading…")
        case .speaking: stateText = manager.activeProvider?.shortName ?? String(localized: "Reading")
        case .buffering: stateText = String(localized: "Buffering next section")
        case .paused: stateText = String(localized: "Paused")
        }

        guard manager.state == .speaking || manager.state == .buffering || manager.state == .paused else { return stateText }
        let seconds = Int(manager.elapsedSeconds)
        let elapsed = String(format: "%d:%02d", seconds / 60, seconds % 60)
        let queue = manager.queueCount > 0 ? "  •  +\(manager.queueCount)" : ""
        return "\(stateText)  •  \(elapsed)\(queue)"
    }

    private func statusImage(for state: ReadAloudState) -> NSImage? {
        let name: String
        switch state {
        case .idle: name = "speaker.slash"
        case .capturing, .loading: name = "ellipsis.circle"
        case .speaking: name = "speaker.wave.2.fill"
        case .buffering: name = "ellipsis"
        case .paused: name = "pause.circle.fill"
        }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        return image?.withSymbolConfiguration(.init(pointSize: 14, weight: .semibold))
    }

    private func statusTint(for state: ReadAloudState) -> NSColor {
        switch state {
        case .speaking: return .controlAccentColor
        case .buffering: return .systemYellow
        case .paused: return .systemOrange
        default: return .secondaryLabelColor
        }
    }

    @objc private func slowerTapped() { manager?.slower() }
    @objc private func fasterTapped() { manager?.faster() }
    @objc private func rewindTapped() { manager?.rewindFiveSeconds() }
    @objc private func playPauseTapped() { manager?.togglePlayback() }
    @objc private func forwardTapped() { manager?.forwardFiveSeconds() }
    @objc private func nextTapped() { manager?.skipToNext() }
    @objc private func stopTapped() { manager?.stop() }

    /// Allow clicks without first activating the panel (nonactivatingPanel).
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
