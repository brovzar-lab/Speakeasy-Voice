import Foundation
import Combine

/// A dictation cleanup "style". Each preset maps to an enhancement prompt that the
/// local Ollama cleanup uses, letting the user reshape the same spoken words for a
/// different context (raw, clean, formal email, script notes, casual chat) on the fly.
enum StylePreset: String, CaseIterable, Identifiable {
    case raw
    case clean
    case email
    case script
    case casual

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .raw:    return String(localized: "Raw (no cleanup)")
        case .clean:  return String(localized: "Clean (keep my words)")
        case .email:  return String(localized: "Formal Email")
        case .script: return String(localized: "Script Notes")
        case .casual: return String(localized: "WhatsApp / Casual")
        }
    }

    /// Enhancement prompt applied by this preset. `nil` means no cleanup (raw transcript).
    var promptId: UUID? {
        switch self {
        case .raw:    return nil
        case .clean:  return PromptTemplates.defaultPromptId
        case .email:  return PromptTemplates.emailPromptId
        case .script: return StylePresetManager.scriptNotesPromptId
        case .casual: return PromptTemplates.chatPromptId
        }
    }
}

@MainActor
final class StylePresetManager: ObservableObject {
    static let shared = StylePresetManager()

    /// Stable id for the custom "Script Notes" prompt seeded at first launch.
    static let scriptNotesPromptId = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!

    private static let storageKey = "ActiveStylePreset"

    @Published var activePreset: StylePreset {
        didSet { UserDefaults.standard.set(activePreset.rawValue, forKey: Self.storageKey) }
    }

    private init() {
        let stored = UserDefaults.standard.string(forKey: Self.storageKey)
        self.activePreset = stored.flatMap(StylePreset.init(rawValue:)) ?? .clean
    }

    /// Advance to the next style preset. Used by the global cycle hotkey.
    func cycle() {
        let all = StylePreset.allCases
        let idx = all.firstIndex(of: activePreset) ?? 0
        activePreset = all[(idx + 1) % all.count]
    }
}
