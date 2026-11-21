import SwiftUI

/// Fix spelling, grammar, and punctuation in the selected text using the active text engine — a
/// copy-edit that preserves the writer's own voice and wording, NOT a rewrite. Runs on-device by
/// default (Apple Intelligence handles this well and privately), or any configured text model.
struct GrammarFixAction: CaptureAction {
    let intelligence: IntelligenceCoordinator

    let id = "ai.grammar"
    nonisolated static let defaultTitle = BuiltInContent.Title.proofread
    var title: String { PatchState.title(id, default: Self.defaultTitle) }
    let systemImage = "text.badge.checkmark"
    let relevancePriority = 25

    func isRelevant(to ctx: CaptureContext) -> Bool { true }
    func disabledReason(for ctx: CaptureContext, visionAvailable: Bool) -> String? {
        ctx.ocrText?.isEmpty == false ? nil : "No text to correct."
    }

    func perform(_ ctx: CaptureContext) async throws -> ActionResult {
        // The result card's footer names the answering model (attribution is set at its first token),
        // and the card has no other status line, so a fallback is only logged here.
        .stream(intelligence.respond(prompt: Self.framedPrompt(for: ctx.ocrText ?? ""), context: nil,
                                     onFallback: { notice in
            Log.intelligence.notice("Proofread card · \(notice.text, privacy: .public)")
        }))
    }

    /// The instruction + few-shot examples (`BuiltInContent.proofreadPrompt`, where a package can patch it).
    nonisolated static let prompt = BuiltInContent.proofreadPrompt

    /// Append the user's text as the next Input/Output turn so the model *completes the few-shot
    /// pattern* — far more reliable on small models than tacking the text on under a different header.
    static func framedPrompt(for text: String) -> String {
        "\(PatchState.prompt("ai.grammar", default: prompt))\n\nInput:\n\(text)\nOutput:\n"
    }

    /// Clean a model's raw correction: drop <think> reasoning, cut any hallucinated continuation of
    /// the few-shot chain, and strip an echoed "Output:" label or wrapping quotes. Keeps paste-back
    /// safe even when a small model gets chatty.
    static func cleanCorrection(_ raw: String) -> String {
        var s = ChatController.splitReasoning(raw).answer
        // Stop at any attempt to continue the example chain.
        for marker in ["\n\nInput:", "\nInput:", "\nOutput:"] {
            if let r = s.range(of: marker) { s = String(s[..<r.lowerBound]) }
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = s.range(of: "Output:", options: [.anchored, .caseInsensitive]) {
            s = String(s[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if s.count >= 2, s.hasPrefix("\""), s.hasSuffix("\"") {
            s = String(s.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return s
    }
}
