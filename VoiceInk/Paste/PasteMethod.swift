import Foundation

/// How transcribed text is delivered into whatever app has focus.
///
/// The two clipboard-based options (`standard`, `appleScript`) briefly hijack
/// the clipboard to run a Cmd+V. `type` bypasses the clipboard entirely by
/// synthesizing Unicode key events directly — no clipboard pollution.
enum PasteMethod: String, CaseIterable, Identifiable {
    /// Clipboard + Cmd+V via CGEvent. Fastest and most reliable in most apps.
    case standard = "default"
    /// Clipboard + AppleScript keystroke. Fallback for QWERTY-remap layouts.
    case appleScript = "appleScript"
    /// Direct Unicode key events, no clipboard touch. Slower on very long text
    /// but leaves your clipboard alone — clipboard managers stay clean.
    case type = "type"

    static let userDefaultsKey = "pasteMethod"
    static let legacyAppleScriptPasteKey = "useAppleScriptPaste"

    var id: String { rawValue }

    /// Whether this method touches `NSPasteboard.general`. Used by
    /// `CursorPaster` to skip clipboard snapshot/restore for `.type`.
    var usesClipboard: Bool {
        switch self {
        case .standard, .appleScript: return true
        case .type: return false
        }
    }

    var displayName: String {
        switch self {
        case .standard:
            return String(localized: "Default (Clipboard + ⌘V)")
        case .appleScript:
            return String(localized: "AppleScript (Clipboard)")
        case .type:
            return String(localized: "Type Directly (No Clipboard)")
        }
    }

    static func current(in defaults: UserDefaults = .standard) -> PasteMethod {
        if let rawValue = defaults.string(forKey: userDefaultsKey),
           let method = PasteMethod(rawValue: rawValue) {
            return method
        }

        return defaults.bool(forKey: legacyAppleScriptPasteKey) ? .appleScript : .standard
    }

    static func setCurrent(_ method: PasteMethod, in defaults: UserDefaults = .standard) {
        defaults.set(method.rawValue, forKey: userDefaultsKey)
        defaults.set(method == .appleScript, forKey: legacyAppleScriptPasteKey)
    }

    static func migrateLegacyUserDefaultIfNeeded(in defaults: UserDefaults = .standard) {
        if let rawValue = defaults.string(forKey: userDefaultsKey),
           PasteMethod(rawValue: rawValue) != nil {
            return
        }

        setCurrent(defaults.bool(forKey: legacyAppleScriptPasteKey) ? .appleScript : .standard, in: defaults)
    }
}
