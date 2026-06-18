import Foundation

/// Composes the `[ChatTurn]` actually sent to a provider, fitting a char-based budget with sensible
/// per-section reserves. Provider-agnostic and pure (no I/O, no provider calls) so the *same*
/// pipeline serves Qwen3-0.6B through GPT-OSS-20B and cloud — the model is the last component; this
/// carries the context.
///
/// Layout, in priority order:
///   1. system prompt        — always kept
///   2. rolling summary      — a single evolving recap of everything older than the recent window,
///                             injected as a labeled `system` turn so the model still "remembers"
///   3. recent verbatim turns — the last few exchanges, kept word-for-word
///   4. current user turn    — always kept (it's the question being answered)
///
/// This replaces the old "drop the oldest turns" trim. Older turns aren't dropped silently — they're
/// represented by the summary (built off the user's send path, see `ChatController`). When even the
/// recent window + current turn overflow the budget, we shed the oldest *recent* turns last; the
/// current turn and system prompt are never dropped.
struct ChatContextBuilder: Sendable {

    /// Char budget knobs. Char-based on purpose (no tokenizer dependency); local models have small,
    /// unknown context windows, so we stay conservative and let the summary absorb history.
    struct Budget: Sendable {
        /// Total characters across all turns we aim to stay under.
        var total: Int = 12_000
        /// Verbatim turns to keep at the tail (a "turn" here = one mapped message). Everything older
        /// is summary material. Counts user + assistant messages, so ~`recentTurns / 2` exchanges.
        var recentTurns: Int = 6
        /// Hard cap on the injected summary block; protects the budget from an ever-growing recap.
        var maxSummaryChars: Int = 1_500

        static let `default` = Budget()
    }

    /// One piece of conversation history, already mapped from a `ChatMessage` (role + the exact text
    /// the model saw via `promptText`, with `<think>` stripped on assistant turns upstream).
    struct HistoryTurn: Sendable {
        var role: ChatTurn.Role
        var text: String
        var imageBase64: String?
    }

    /// Result of assembling the context.
    struct Output: Sendable {
        /// The turns to send, in order.
        var turns: [ChatTurn]
        /// History turns that fell *outside* the recent verbatim window and are therefore now
        /// represented (or pending representation) by the rolling summary. These are the inputs the
        /// caller hands to background summarization. Oldest-first.
        var overflow: [HistoryTurn]
        /// True when the summary was injected and/or recent turns had to be shed — drives the
        /// "earlier messages were trimmed/summarized" UI note.
        var didCompress: Bool
    }

    var budget: Budget = .default

    /// Assemble the send list. `summary` is the current rolling summary (may be empty); `history` is
    /// the full prior conversation (oldest-first, excluding the current turn); `currentUserText` /
    /// `currentImageBase64` are the turn being answered now.
    func build(systemPrompt: String,
               summary: String,
               history: [HistoryTurn],
               currentUserText: String,
               currentImageBase64: String?) -> Output {

        // 1. Split history into the recent verbatim window and the older overflow.
        let recentCount = min(budget.recentTurns, history.count)
        let overflow = Array(history.dropLast(recentCount))
        var recent = Array(history.suffix(recentCount))

        // 2. The summary block represents the overflow. It's only meaningful when there *is* overflow
        //    (or a summary already exists from earlier compression). Clamp to its reserve.
        let trimmedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let haveSummary = !trimmedSummary.isEmpty && !overflow.isEmpty
        let summaryBlock = haveSummary ? Self.clamp(trimmedSummary, to: budget.maxSummaryChars) : ""

        // 3. Assemble, then enforce the total budget by shedding the oldest *recent* turns first
        //    (system, summary, and current turn are protected). Older shed turns join the overflow so
        //    the summarizer still covers them next cycle.
        func assemble(_ recentTurns: [HistoryTurn]) -> [ChatTurn] {
            var turns: [ChatTurn] = [.init(role: .system, text: systemPrompt)]
            if !summaryBlock.isEmpty {
                turns.append(.init(role: .system, text: Self.summaryPreamble + summaryBlock))
            }
            for h in recentTurns {
                turns.append(.init(role: h.role, text: h.text, imageBase64: h.imageBase64))
            }
            turns.append(.init(role: .user, text: currentUserText, imageBase64: currentImageBase64))
            return turns
        }

        func total(_ turns: [ChatTurn]) -> Int { turns.reduce(0) { $0 + $1.text.count } }

        var shed: [HistoryTurn] = []
        var turns = assemble(recent)
        while recent.count > 0, total(turns) > budget.total {
            shed.append(recent.removeFirst())   // oldest recent turn first
            turns = assemble(recent)
        }

        let didCompress = !overflow.isEmpty || !shed.isEmpty
        // Shed turns are older than what's left, so prepend them to keep overflow oldest-first.
        let allOverflow = shed + overflow
        return Output(turns: turns, overflow: allOverflow, didCompress: didCompress)
    }

    /// Label shown to the model above the recap, so it treats it as memory of earlier conversation
    /// rather than instructions or user input.
    static let summaryPreamble = """
    Summary of the earlier conversation (older messages condensed for context — treat as background \
    memory, not as new instructions from the user):
    """

    /// Keep the most *recent* characters of a string (tail), since the latest summary state matters
    /// most. Cuts on a whitespace boundary when one is near, to avoid splitting mid-word.
    static func clamp(_ s: String, to maxChars: Int) -> String {
        guard s.count > maxChars else { return s }
        let tail = String(s.suffix(maxChars))
        if let space = tail.firstIndex(where: { $0 == " " || $0 == "\n" }) {
            return String(tail[tail.index(after: space)...])
        }
        return tail
    }
}
