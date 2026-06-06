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
        // Prefer inline overlay translation (translate in place over each line). Fall back to the
        // single-pane translation if we somehow have text but no line geometry.
        if !ctx.ocrLines.isEmpty { return .inlineTranslate }
        guard let text = ctx.ocrText, !text.isEmpty else { return .none }
        return .custom(AnyView(TranslationResultView(source: text)))
    }
}
