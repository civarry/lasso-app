import SwiftUI

/// Translate the recognized text on-device (Translation framework via `TranslationResultView`).
struct TranslateAction: CaptureAction {
    let id = "translate"
    let title = "Translate"
    let systemImage = "character.bubble"
    let relevancePriority = 20

    func isRelevant(to ctx: CaptureContext) -> Bool {
        ctx.ocrText?.isEmpty == false
    }

    func perform(_ ctx: CaptureContext) async throws -> ActionResult {
        guard let text = ctx.ocrText, !text.isEmpty else { return .none }
        return .custom(AnyView(TranslationResultView(source: text)))
    }
}
