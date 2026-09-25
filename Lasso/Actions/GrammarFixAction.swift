import SwiftUI

/// Fix spelling, grammar, and punctuation in the selected text using the active text engine — a
/// copy-edit that preserves the writer's own voice and wording, NOT a rewrite. Runs on-device by
/// default (Apple Intelligence handles this well and privately), or any configured text model.
struct GrammarFixAction: CaptureAction {
    let intelligence: IntelligenceCoordinator

    let id = "ai.grammar"
    let title = "Proofread"
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

    /// The instruction + few-shot examples. Enumerating the error types and showing the hard cases
    /// (tense, compound-subject case, agreement, adverb/adjective, multi-error chains) is what makes
    /// small/on-device models actually fix them — a bare "fix only, don't restructure" makes them too
    /// timid. Voice/tone/slang are still preserved; only genuine errors change. Shared with the
    /// in-place selected-text flow (`GrammarFixService`).
    static let prompt = """
    You are an expert grammar correction engine.

    Correct every grammar, spelling, punctuation, capitalization, verb-tense, subject-verb agreement, \
    pronoun, word-form, article, preposition, and sentence-structure error. A sentence may contain \
    several mistakes — fix all of them, not just the first.

    Grammatical correctness comes before preserving exact wording: rewrite words, phrases, clauses, \
    or whole sentences when needed to make the text correct and natural.

    Preserve the author's meaning, tone, voice, level of formality, and slang whenever possible. Do NOT:
    - rewrite for style or elegance, or make text more formal;
    - replace casual phrasing or slang that is already correct;
    - swap numbers for words or words for numbers;
    - change vocabulary by preference, or add or remove meaning.

    Use time expressions as tense cues ("yesterday", "last week" point to past; "tomorrow", \
    "next week" point to future).

    If there is nothing to correct — a URL, file path, email address, code, a number, a single token, \
    or text that is already correct — return it EXACTLY as given. Never ask a question, never explain, \
    never refuse.

    Output ONLY the corrected text — no explanations, quotes, or labels.

    Examples:

    Input:
    https://www.example.com/appointment-system/taipei
    Output:
    https://www.example.com/appointment-system/taipei

    Input:
    she don't like coffee
    Output:
    She doesn't like coffee.

    Input:
    I have went to the store yesterday.
    Output:
    I went to the store yesterday.

    Input:
    Me and my friend was going to the mall yesterday and we seen a great movie.
    Output:
    My friend and I were going to the mall yesterday, and we saw a great movie.

    Input:
    i been using this app for like 2 weeks and honestly its work really good
    Output:
    I've been using this app for like 2 weeks, and honestly, it works really well.
    """

    /// Append the user's text as the next Input/Output turn so the model *completes the few-shot
    /// pattern* — far more reliable on small models than tacking the text on under a different header.
    static func framedPrompt(for text: String) -> String {
        "\(prompt)\n\nInput:\n\(text)\nOutput:\n"
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
