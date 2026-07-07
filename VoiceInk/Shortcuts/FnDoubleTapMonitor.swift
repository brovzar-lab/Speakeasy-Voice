import AppKit
import CoreGraphics
import Foundation
import os

/// Detects a quick double-tap of the Fn / Globe key and fires a callback, the way
/// macOS native dictation is triggered. Listen-only: the Fn key still passes through,
/// so nothing else that uses Fn is blocked.
final class FnDoubleTapMonitor {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var lastFnDownTime: TimeInterval = 0
    private var fnWasDown = false
    private var onDoubleTap: (() -> Void)?
    private let doubleTapWindow: TimeInterval = 0.4
    private static let fnKeyCode: UInt16 = 63  // kVK_Function (Globe / Fn)
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "FnDoubleTapMonitor")

    deinit { stop() }

    @discardableResult
    func start(onDoubleTap: @escaping () -> Void) -> Bool {
        stop()
        self.onDoubleTap = onDoubleTap

        let mask = CGEventMask(1) << Int(CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<FnDoubleTapMonitor>.fromOpaque(userInfo).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = monitor.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            monitor.handle(event: event)
            return Unmanaged.passUnretained(event)  // never suppress
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            logger.error("Failed to install Fn double-tap event tap")
            return false
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            logger.error("Failed to create Fn double-tap run loop source")
            return false
        }

        self.eventTap = tap
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            self.runLoopSource = nil
        }
        if let eventTap {
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
        }
        onDoubleTap = nil
        fnWasDown = false
        lastFnDownTime = 0
    }

    private func handle(event: CGEvent) {
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        guard keyCode == Self.fnKeyCode else { return }

        let fnDown = event.flags.contains(.maskSecondaryFn)
        // Only react to the press (down) transition, ignore the release.
        if fnDown && !fnWasDown {
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastFnDownTime <= doubleTapWindow {
                lastFnDownTime = 0
                let callback = onDoubleTap
                DispatchQueue.main.async { callback?() }
            } else {
                lastFnDownTime = now
            }
        }
        fnWasDown = fnDown
    }
}
