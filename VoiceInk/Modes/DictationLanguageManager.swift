import Foundation
import Combine

/// Global override for the dictation transcription language.
///
/// Lets the user force English or Spanish (or fall back to Auto / the per-mode
/// setting) from the menu bar or a global hotkey, independent of any single mode.
/// The chosen value flows into the transcription request context and is passed
/// straight to Parakeet / Whisper as a forced language.
@MainActor
final class DictationLanguageManager: ObservableObject {
    static let shared = DictationLanguageManager()

    private static let storageKey = "ForcedDictationLanguage"

    /// "en", "es", or nil for Auto (follow the active mode's language setting).
    @Published var forcedLanguage: String? {
        didSet {
            if let forcedLanguage {
                UserDefaults.standard.set(forcedLanguage, forKey: Self.storageKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.storageKey)
            }
        }
    }

    private init() {
        let stored = UserDefaults.standard.string(forKey: Self.storageKey)
        // Default to English so first-run dictation is predictable; the user
        // flips to Spanish with the menu bar switch or the toggle hotkey.
        self.forcedLanguage = stored ?? "en"
    }

    /// Flip between English and Spanish. Invoked by the global toggle hotkey.
    /// From Auto, this lands on Spanish (assumes the user is switching away from default English).
    func toggleEnglishSpanish() {
        forcedLanguage = (forcedLanguage == "es") ? "en" : "es"
    }

    /// Human-readable name of the current choice, for menus and status display.
    var displayName: String {
        switch forcedLanguage {
        case "en": return String(localized: "English")
        case "es": return String(localized: "Español")
        default: return String(localized: "Auto")
        }
    }

    /// Short code for compact display (menu bar), e.g. "EN" / "ES" / "AUTO".
    var shortCode: String {
        switch forcedLanguage {
        case "en": return "EN"
        case "es": return "ES"
        default: return "AUTO"
        }
    }
}
