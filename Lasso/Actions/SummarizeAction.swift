import SwiftUI

/// Summarize the selected text using the active intelligence provider (on-device or Ollama).
struct SummarizeAction: CaptureAction {
    let intelligence: IntelligenceCoordinator

    let id = "ai.summarize"
    let title = "Summarize"
    let systemImage = "sparkles"
    let relevancePriority = 30

    func isRelevant(to ctx: CaptureContext) -> Bool {
        (ctx.ocrText?.count ?? 0) > 40
    }

    func perform(_ ctx: CaptureContext) async throws -> ActionResult {
        let stream = intelligence.respond(
            prompt: "Summarize the on-screen text in 2–3 sentences. Be faithful to the source.",
            context: ctx.ocrText
        )
        return .stream(stream)
    }
}
