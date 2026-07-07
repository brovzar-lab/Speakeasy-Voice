import AppIntents
import Foundation
import AppKit

struct DismissMiniRecorderIntent: AppIntent {
    static var title: LocalizedStringResource = "Dismiss Speakeasy-Voice Recorder"
    static var description = IntentDescription("Dismiss the Speakeasy-Voice recorder and cancel any active recording.")
    
    static var openAppWhenRun: Bool = false
    
    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        NotificationCenter.default.post(name: .dismissRecorderPanel, object: nil)
        
        let dialog: IntentDialog = "Speakeasy-Voice recorder dismissed"
        return .result(dialog: dialog)
    }
}
