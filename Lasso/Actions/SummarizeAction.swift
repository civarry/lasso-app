import SwiftUI

/// Summarize the selected text using the active intelligence provider (on-device or Ollama).
struct SummarizeAction: CaptureAction {
    let intelligence: IntelligenceCoordinator

    let id = "ai.summarize"
    nonisolated static let defaultTitle = BuiltInContent.Title.summarize
    var title: String { PatchState.title(id, default: Self.defaultTitle) }
    let systemImage = "text.line.3.summary"
    let relevancePriority = 30

    /// A package can replace it (`action.ai.summarize.prompt`); the selected text still follows it.
    nonisolated static let defaultPrompt = BuiltInContent.summarizePrompt

    func isRelevant(to ctx: CaptureContext) -> Bool { true }
    func disabledReason(for ctx: CaptureContext, visionAvailable: Bool) -> String? {
        (ctx.ocrText?.count ?? 0) > 40 ? nil : "Select more text to summarize."
    }

    func perform(_ ctx: CaptureContext) async throws -> ActionResult {
        let stream = intelligence.respond(
            prompt: PatchState.prompt(id, default: Self.defaultPrompt),
            context: ctx.ocrText
        )
        return .stream(stream)
    }
}
