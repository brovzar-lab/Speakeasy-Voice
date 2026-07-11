import Foundation
import ApplicationServices
import AppKit
import Carbon
import os
import SelectedTextKit

@MainActor
final class SelectedTextService {
    private static let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "SelectedTextService")
    private static let textManager = SelectedTextManager.shared
    private static let selectedTextStrategies: [TextStrategy] = [
        .accessibility,
        .menuAction,
        .appleScript
    ]

    static func fetchSelectedText() async -> String? {
        guard AXIsProcessTrusted() else {
            logger.debug("Accessibility is not trusted; selected text capture skipped")
            return nil
        }

        do {
            return normalized(try await textManager.getSelectedText(strategies: selectedTextStrategies))
        } catch {
            logger.debug("SelectedTextKit failed to capture selected text: \(error, privacy: .public)")
            return nil
        }
    }

    /// Read Aloud must NOT use SelectedTextKit / AXUIElement queries.
    ///
    /// On macOS 26 those calls frequently throw into HIServices, which swallows
    /// the exception (`SOME_OTHER_THREAD_SWALLOWED_AT_LEAST_ONE_EXCEPTION`) and
    /// leaves Swift's MainActor executor check corrupted. The next SwiftUI
    /// `Button` click then dies in `MainActor.assumeIsolated`.
    ///
    /// Instead we synthesize Cmd+C via CGEvent, read the pasteboard, and restore
    /// whatever was there before — same permission gate as paste, no AX tree walk.
    static func fetchSelectedTextForReadAloud() async -> String? {
        await fetchSelectedTextViaCommandC()
    }

    private static func fetchSelectedTextViaCommandC() async -> String? {
        guard AXIsProcessTrusted() else {
            logger.debug("Accessibility is not trusted; Cmd+C selection capture skipped")
            return nil
        }

        let pasteboard = NSPasteboard.general
        let previousString = pasteboard.string(forType: .string)
        let previousChangeCount = pasteboard.changeCount

        guard postCommandC() else {
            logger.error("Failed to post Cmd+C for Read Aloud selection capture")
            return nil
        }

        // Wait briefly for the frontmost app to update the pasteboard.
        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 25_000_000) // 25ms
            if pasteboard.changeCount != previousChangeCount { break }
        }

        let copied = normalized(pasteboard.string(forType: .string))

        // Restore prior clipboard contents when we can.
        if pasteboard.changeCount != previousChangeCount {
            pasteboard.clearContents()
            if let previousString {
                pasteboard.setString(previousString, forType: .string)
            }
        }

        return copied
    }

    private static func postCommandC() -> Bool {
        let source = CGEventSource(stateID: .privateState)
        let keyC = CGKeyCode(kVK_ANSI_C) // 0x08
        let keyCmd = CGKeyCode(kVK_Command) // 0x37

        guard let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: keyCmd, keyDown: true),
              let cDown = CGEvent(keyboardEventSource: source, virtualKey: keyC, keyDown: true),
              let cUp = CGEvent(keyboardEventSource: source, virtualKey: keyC, keyDown: false),
              let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: keyCmd, keyDown: false) else {
            return false
        }

        cmdDown.flags = .maskCommand
        cDown.flags = .maskCommand
        cUp.flags = .maskCommand

        cmdDown.post(tap: .cghidEventTap)
        cDown.post(tap: .cghidEventTap)
        cUp.post(tap: .cghidEventTap)
        cmdUp.post(tap: .cghidEventTap)
        return true
    }

    private static func normalized(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
