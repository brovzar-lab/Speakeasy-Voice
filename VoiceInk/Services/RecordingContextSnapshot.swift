import Foundation
import AppKit

struct RecordingContextSnapshot {
    var capturedAt = Date()
    var selectedText: String?
    var clipboardText: String?
    var screenText: String?
}

@MainActor
final class RecordingContextSnapshotStore {
    private(set) var snapshot = RecordingContextSnapshot()

    func updateSelectedText(_ text: String?) {
        snapshot.selectedText = Self.normalized(text)
    }

    func updateClipboardText(_ text: String?) {
        snapshot.clipboardText = Self.normalized(text)
    }

    func updateScreenText(_ text: String?) {
        snapshot.screenText = Self.normalized(text)
    }

    private static func normalized(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Controls which expensive context probes run while the user is dictating.
/// Skipping unused captures avoids screen OCR and simulated copy on every recording.
struct RecordingContextCaptureOptions: OptionSet {
    let rawValue: Int

    static let clipboard = RecordingContextCaptureOptions(rawValue: 1 << 0)
    static let selectedText = RecordingContextCaptureOptions(rawValue: 1 << 1)
    static let screen = RecordingContextCaptureOptions(rawValue: 1 << 2)

    static let all: RecordingContextCaptureOptions = [.clipboard, .selectedText, .screen]
}

@MainActor
enum RecordingContextCaptureService {
    static func startCapture(
        into store: RecordingContextSnapshotStore,
        options: RecordingContextCaptureOptions
    ) -> [Task<Void, Never>] {
        guard !options.isEmpty else { return [] }

        var tasks: [Task<Void, Never>] = []

        if options.contains(.clipboard) {
            tasks.append(Task { @MainActor in
                store.updateClipboardText(NSPasteboard.general.string(forType: .string))
            })
        }

        if options.contains(.selectedText) {
            tasks.append(Task { @MainActor in
                guard !Task.isCancelled else { return }
                let selectedText = await SelectedTextService.fetchSelectedText()
                guard !Task.isCancelled else { return }
                store.updateSelectedText(selectedText)
            })
        }

        if options.contains(.screen) {
            tasks.append(Task { @MainActor in
                guard CGPreflightScreenCaptureAccess(), !Task.isCancelled else { return }
                let screenCaptureService = ScreenCaptureService()
                let screenText = await screenCaptureService.captureAndExtractText()
                guard !Task.isCancelled else { return }
                store.updateScreenText(screenText)
            })
        }

        return tasks
    }
}
