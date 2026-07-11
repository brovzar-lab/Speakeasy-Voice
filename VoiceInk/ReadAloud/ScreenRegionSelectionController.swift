import Foundation
import AppKit
import ScreenCaptureKit
import Vision
import OSLog

/// Result of a region-selection interaction.
enum ScreenRegionSelectionResult {
    case cancelled
    case succeeded(String)
    case failed(String)
}

/// Coordinates the full-screen drag-to-select overlay and returns the OCR'd
/// text from whatever rectangle the user drew.
///
/// Owns a single overlay window across all screens so multi-monitor setups can
/// draw a rectangle on any display without stealing focus from the frontmost app.
@MainActor
final class ScreenRegionSelectionController {
    static let shared = ScreenRegionSelectionController()

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "ReadAloud.RegionSelect")
    private var overlayWindows: [RegionOverlayWindow] = []
    private var continuation: CheckedContinuation<ScreenRegionSelectionResult, Never>?

    private init() {}

    /// Present the overlay and await the user's selection.
    /// Returns `.cancelled` if the user hits Escape or right-clicks.
    func selectRegion() async -> ScreenRegionSelectionResult {
        // Guarantee only one active session at a time.
        if continuation != nil {
            return .cancelled
        }

        return await withCheckedContinuation { (cont: CheckedContinuation<ScreenRegionSelectionResult, Never>) in
            self.continuation = cont
            self.presentOverlays()
        }
    }

    // MARK: - Overlay lifecycle

    private func presentOverlays() {
        dismissOverlays()

        // Create one borderless full-screen panel per display.
        for screen in NSScreen.screens {
            let window = RegionOverlayWindow(contentRect: screen.frame, screen: screen)
            window.onSelectionComplete = { [weak self] rect, screen in
                Task { @MainActor in
                    await self?.handleSelection(rect: rect, screen: screen)
                }
            }
            window.onCancel = { [weak self] in
                Task { @MainActor in
                    self?.finish(with: .cancelled)
                }
            }
            overlayWindows.append(window)
            window.orderFrontRegardless()
        }
    }

    private func dismissOverlays() {
        for window in overlayWindows {
            window.orderOut(nil)
        }
        overlayWindows.removeAll()
    }

    private func finish(with result: ScreenRegionSelectionResult) {
        dismissOverlays()
        continuation?.resume(returning: result)
        continuation = nil
    }

    // MARK: - Selection handling

    private func handleSelection(rect: NSRect, screen: NSScreen) async {
        // Hide overlays before we capture, or they'll be in the screenshot.
        dismissOverlays()

        // Give the WindowServer a beat to actually paint the overlays hidden.
        try? await Task.sleep(nanoseconds: 120_000_000)

        do {
            let image = try await captureRegion(rect: rect, screen: screen)
            let text = await Self.recognizeText(from: image)
            finish(with: .succeeded(text))
        } catch {
            logger.error("region capture failed: \(error.localizedDescription, privacy: .public)")
            finish(with: .failed(error.localizedDescription))
        }
    }

    /// Capture the selected rect using ScreenCaptureKit. `rect` is in AppKit
    /// window coordinates for the given screen; we translate to top-left origin
    /// pixel coordinates expected by SCContentFilter/SCStreamConfiguration.
    private nonisolated func captureRegion(rect: NSRect, screen: NSScreen) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { NSNumber(value: $0.displayID).intValue == (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue }) ?? content.displays.first else {
            throw NSError(domain: "ReadAloudRegion", code: 1, userInfo: [NSLocalizedDescriptionKey: "No display available"])
        }

        // Translate AppKit rect (origin at bottom-left of the screen) to a rect
        // relative to the display's top-left origin, in points, then convert to
        // pixel coordinates using the backing scale.
        let screenFrame = screen.frame
        let scale = screen.backingScaleFactor
        let relX = rect.origin.x - screenFrame.origin.x
        let relY = screenFrame.height - (rect.origin.y - screenFrame.origin.y) - rect.height

        let sourcePoints = CGRect(x: relX, y: relY, width: rect.width, height: rect.height)
            .integral

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.sourceRect = sourcePoints
        config.width = max(1, Int(sourcePoints.width * scale))
        config.height = max(1, Int(sourcePoints.height * scale))
        config.showsCursor = false

        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// Run Vision OCR against the captured image and return joined text.
    private nonisolated static func recognizeText(from image: CGImage) async -> String {
        await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            let request = VNRecognizeTextRequest { req, _ in
                let observations = req.results as? [VNRecognizedTextObservation] ?? []
                let text = observations
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: " ")
                cont.resume(returning: text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true

            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                cont.resume(returning: "")
            }
        }
    }
}

// MARK: - Overlay window + view

private final class RegionOverlayWindow: NSPanel {
    var onSelectionComplete: ((NSRect, NSScreen) -> Void)?
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    init(contentRect: NSRect, screen: NSScreen) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .screenSaver
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = false
        self.setFrame(contentRect, display: false)

        let view = RegionOverlayView(frame: NSRect(origin: .zero, size: contentRect.size))
        view.owningScreen = screen
        view.onSelectionComplete = { [weak self] rect in
            guard let self, let screen = view.owningScreen else { return }
            // Translate the view-local rect back into screen coordinates for the caller.
            let screenRect = NSRect(
                x: screen.frame.origin.x + rect.origin.x,
                y: screen.frame.origin.y + rect.origin.y,
                width: rect.width,
                height: rect.height
            )
            self.onSelectionComplete?(screenRect, screen)
        }
        view.onCancel = { [weak self] in
            self?.onCancel?()
        }
        contentView = view
        // Make the panel key so it can receive key events (Escape to cancel).
        makeKey()
    }

    override func keyDown(with event: NSEvent) {
        // Escape (keyCode 53) cancels the selection.
        if event.keyCode == 53 {
            onCancel?()
            return
        }
        super.keyDown(with: event)
    }
}

private final class RegionOverlayView: NSView {
    weak var owningScreen: NSScreen?
    var onSelectionComplete: ((NSRect) -> Void)?
    var onCancel: (() -> Void)?

    private var startPoint: NSPoint?
    private var currentRect: NSRect = .zero

    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func draw(_ dirtyRect: NSRect) {
        // Dim veil.
        NSColor.black.withAlphaComponent(0.28).setFill()
        bounds.fill()

        if currentRect.width > 0 && currentRect.height > 0 {
            // Cut a hole so the selected region shows the desktop clearly.
            NSGraphicsContext.saveGraphicsState()
            let clip = NSBezierPath(rect: bounds)
            clip.append(NSBezierPath(rect: currentRect))
            clip.windingRule = .evenOdd
            clip.setClip()
            NSColor.black.withAlphaComponent(0.28).setFill()
            bounds.fill()
            NSGraphicsContext.restoreGraphicsState()

            // Border around the selection.
            NSColor.white.withAlphaComponent(0.9).setStroke()
            let border = NSBezierPath(rect: currentRect.insetBy(dx: -0.5, dy: -0.5))
            border.lineWidth = 1
            border.stroke()

            // Dimension label above the selection.
            let text = "\(Int(currentRect.width)) × \(Int(currentRect.height))"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.white
            ]
            let ns = NSAttributedString(string: text, attributes: attrs)
            let size = ns.size()
            let labelOrigin = NSPoint(
                x: currentRect.origin.x,
                y: currentRect.origin.y + currentRect.height + 4
            )
            let bgRect = NSRect(
                origin: NSPoint(x: labelOrigin.x - 4, y: labelOrigin.y - 2),
                size: NSSize(width: size.width + 8, height: size.height + 4)
            )
            NSColor.black.withAlphaComponent(0.65).setFill()
            NSBezierPath(roundedRect: bgRect, xRadius: 3, yRadius: 3).fill()
            ns.draw(at: labelOrigin)
        }

        // Hint text at the center of the screen when no selection yet.
        if currentRect.width == 0 || currentRect.height == 0 {
            let hint = String(localized: "Drag to select text — Esc to cancel")
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 14, weight: .medium),
                .foregroundColor: NSColor.white
            ]
            let ns = NSAttributedString(string: hint, attributes: attrs)
            let size = ns.size()
            let origin = NSPoint(x: (bounds.width - size.width) / 2, y: bounds.height - size.height - 60)
            let bg = NSRect(x: origin.x - 12, y: origin.y - 6, width: size.width + 24, height: size.height + 12)
            NSColor.black.withAlphaComponent(0.55).setFill()
            NSBezierPath(roundedRect: bg, xRadius: 6, yRadius: 6).fill()
            ns.draw(at: origin)
        }
    }

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        currentRect = .zero
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = startPoint else { return }
        let current = convert(event.locationInWindow, from: nil)
        currentRect = NSRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        )
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { startPoint = nil }
        let rect = currentRect
        // Ignore trivially small selections (accidental clicks).
        if rect.width < 8 || rect.height < 8 {
            onCancel?()
            return
        }
        onSelectionComplete?(rect)
    }

    override func rightMouseDown(with event: NSEvent) {
        onCancel?()
    }
}
