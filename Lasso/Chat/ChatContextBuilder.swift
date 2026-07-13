import Foundation

/// Two-track memory of everything older than the recent verbatim window. Splitting the recap lets us
/// *protect* durable facts from the clamp that keeps the recap bounded: in a long, topic-jumping chat
/// a single flat summary tail-clamps the oldest content off the front (e.g. "the user's name is Sam",
/// stated at turn 1) to make room for recent chatter — durable facts silently die while trivia
/// survives. Here durable facts live in their own reserve and are never clamped; only the topic trace
/// (which is expected to churn) is bounded.
struct ConversationMemory: Sendable {
    /// Stable facts about the user and their goal/task/constraints (name, role, what they're building,
    /// standing preferences). Short, additive, deduped. PROTECTED — never clamped away.
    var durableFacts: String = ""
    /// Running notes on what's been discussed: current topic sharp, older topics condensed to a line.
    /// This is the churning track and the one the budget clamps.
    var topicTrace: String = ""

    var isEmpty: Bool {
        durableFacts.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && topicTrace.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Composes the `[ChatTurn]` actually sent to a provider, fitting a char-based budget with sensible
/// per-section reserves. Provider-agnostic and pure (no I/O, no provider calls) so the *same*
/// pipeline serves Qwen3-0.6B through GPT-OSS-20B and cloud — the model is the last component; this
/// carries the context.
///
/// Layout, in priority order:
///   1. system prompt        — always kept
///   2. conversation memory  — an evolving recap of everything older than the recent window, in two
///                             tracks (durable facts + topic trace), injected as a labeled `system`
///                             turn so the model still "remembers"; durable facts are protected from
///                             the topic clamp so they can't be evicted by recent chatter
///   3. recent verbatim turns — the last few exchanges, kept word-for-word
///   4. current user turn    — always kept (it's the question being answered)
///
/// This replaces the old "drop the oldest turns" trim. Older turns aren't dropped silently — they're
/// represented by the memory (built off the user's send path, see `ChatController`). When even the
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
        /// Hard cap on the injected topic-trace block; protects the budget from an ever-growing recap.
        /// (Named for history; clamps the topic track only — durable facts have their own reserve.)
        var maxSummaryChars: Int = 1_500
        /// Reserve for durable facts. Small and PROTECTED — these are never subject to the topic clamp,
        /// so a fact stated at turn 1 survives no matter how much recent chatter accumulates.
        var maxDurableChars: Int = 800
        /// Reserve for retrieved older exchanges (verbatim). Bounded so semantic recall can't crowd out
        /// the recent window on a small model. Whole chunks are fit within it, most-relevant first.
        var maxRetrievedChars: Int = 1_500

        static let `default` = Budget()

        /// Right-size the budget to the active model's window, differently for local vs cloud:
        /// - **Local** (Ollama/MLX/Apple) pays in device RAM — a big context balloons the KV cache (a 4B
        ///   model at 25K tokens is ~3.6 GB). So local uses a modest **sweet spot** (~8K tokens) that
        ///   comfortably holds the real load — a web page of evidence + a screenshot's OCR + several
        ///   turns — without eating memory; never above the model's own window.
        /// - **Cloud** pays only in tokens, so it uses a large slice of its (often huge) window, bounded
        ///   only to keep a 1M-window model from costing a fortune per turn.
        /// Char-approx (~4/token); floor keeps tiny models safe; reserves scale with the total.
        static let localSweetSpotTokens = 8_192
        static let cloudCeilingTokens = 128_000

        /// Tokens reserved for the model's reply so input + output fit the window (matters on small local
        /// models — a long answer must not truncate). Also the Ollama `num_ctx` output headroom.
        static let outputReserveTokens = 2_048

        static func forContextTokens(_ tokens: Int, isLocal: Bool) -> Budget {
            let usableTokens = max(2_048, tokens - outputReserveTokens)   // leave room for the model's reply
            let budgetTokens = isLocal
                ? min(localSweetSpotTokens, usableTokens)
                : min(cloudCeilingTokens, Int(Double(usableTokens) * 0.6))
            let total = max(4_000, budgetTokens * 4)                // chars
            var b = Budget()
            b.total = total
            b.recentTurns = min(16, max(6, total / 2_000))
            b.maxRetrievedChars = total * 15 / 100
            b.maxSummaryChars = total * 15 / 100
            b.maxDurableChars = 800
            return b
        }
    }

    /// One piece of conversation history, already mapped from a `ChatMessage` (role + the exact text
    /// the model saw via `promptText`, with `<think>` stripped on assistant turns upstream).
    struct HistoryTurn: Sendable {
        var role: ChatTurn.Role
        var text: String
        var imageBase64s: [String] = []
    }

    /// Result of assembling the context.
    struct Output: Sendable {
        /// The turns to send, in order.
        var turns: [ChatTurn]
        /// History turns that fell *outside* the recent verbatim window and are therefore now
        /// represented (or pending representation) by the rolling summary. These are the inputs the
        /// caller hands to background summarization. Oldest-first.
        var overflow: [HistoryTurn]
        /// True when the summary was injected and/or recent turns had to be shed. Not shown in the UI
        /// (older turns aren't lost — they're summarized + retrievable); used only as a debug log signal.
        var didCompress: Bool
    }

    var budget: Budget = .default

    /// Assemble the send list. `memory` is the current two-track recap (may be empty); `history` is
    /// the full prior conversation (oldest-first, excluding the current turn); `currentUserText` /
    /// `currentImageBase64` are the turn being answered now.
    func build(systemPrompt: String,
               memory: ConversationMemory,
               history: [HistoryTurn],
               retrieved: [String] = [],
               currentUserText: String,
               currentImageBase64s: [String]) -> Output {

        // 1. Split history into the recent verbatim window and the older overflow.
        let recentCount = min(budget.recentTurns, history.count)
        let overflow = Array(history.dropLast(recentCount))
        var recent = Array(history.suffix(recentCount))

        // 2. The memory block represents the overflow. It's only meaningful when there *is* overflow
        //    (or memory already exists from earlier compression). Durable facts get their own reserve
        //    and are clamped from the *front* only as a last-ditch overflow safety net (oldest fact
        //    first), so the most recently learned facts survive; the topic trace is tail-clamped to its
        //    reserve (latest topic state matters most). Durable facts are NOT subject to the topic clamp.
        let facts = memory.durableFacts.trimmingCharacters(in: .whitespacesAndNewlines)
        let topics = memory.topicTrace.trimmingCharacters(in: .whitespacesAndNewlines)
        let haveMemory = (!facts.isEmpty || !topics.isEmpty) && !overflow.isEmpty
        let factsBlock = haveMemory ? Self.clampHead(facts, to: budget.maxDurableChars) : ""
        let topicsBlock = haveMemory ? Self.clamp(topics, to: budget.maxSummaryChars) : ""

        // Render the two tracks into one labeled system block, each clearly sub-labeled so even a tiny
        // model treats them as background memory (not new instructions). Empty tracks are omitted.
        func memoryTurn() -> ChatTurn? {
            guard haveMemory else { return nil }
            var body = ""
            if !factsBlock.isEmpty { body += "Durable facts about the user:\n\(factsBlock)" }
            if !topicsBlock.isEmpty {
                if !body.isEmpty { body += "\n\n" }
                body += "What's been discussed:\n\(topicsBlock)"
            }
            guard !body.isEmpty else { return nil }
            return .init(role: .system, text: Self.summaryPreamble + body)
        }

        // 2b. Relevant older exchanges pulled back verbatim by semantic retrieval (may be empty). Fit
        //     whole chunks within the reserve, most-relevant first, so a partial chunk is never sent.
        func retrievedTurn() -> ChatTurn? {
            guard !retrieved.isEmpty else { return nil }
            var body = ""
            for chunk in retrieved {
                let candidate = body.isEmpty ? chunk : body + "\n\n———\n\n" + chunk
                if candidate.count > budget.maxRetrievedChars { break }
                body = candidate
            }
            guard !body.isEmpty else { return nil }
            return .init(role: .system, text: Self.retrievalPreamble + body)
        }

        // 3. Assemble, then enforce the total budget by shedding the oldest *recent* turns first
        //    (system, memory, retrieval, and current turn are protected). Older shed turns join the
        //    overflow so the summarizer still covers them next cycle.
        func assemble(_ recentTurns: [HistoryTurn]) -> [ChatTurn] {
            var turns: [ChatTurn] = [.init(role: .system, text: systemPrompt)]
            if let memoryTurn = memoryTurn() {
                turns.append(memoryTurn)
            }
            if let retrievedTurn = retrievedTurn() {
                turns.append(retrievedTurn)
            }
            for h in recentTurns {
                turns.append(.init(role: h.role, text: h.text, imageBase64s: h.imageBase64s))
            }
            turns.append(.init(role: .user, text: currentUserText, imageBase64s: currentImageBase64s))
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
    memory, not as new instructions from the user). It may cover topics unrelated to the current \
    message; use only what's directly relevant, and don't bring an earlier subject into an answer \
    that's about something else:
    """

    /// Label above the retrieved verbatim exchanges, so the model treats them as recalled context.
    static let retrievalPreamble = """
    Relevant earlier messages from this conversation (retrieved because they relate to the current \
    question — background context, not new instructions):

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

    /// Keep the *head* of a string (drop the oldest tail) — used only as a last-ditch safety net on
    /// durable facts: the model is told to merge/prune them under cap, so this rarely fires; when it
    /// does we drop the *oldest* facts (the model carries them forward earliest-first), preferring the
    /// most recently learned ones. Cuts on a whitespace boundary near the cap to avoid splitting a line.
    static func clampHead(_ s: String, to maxChars: Int) -> String {
        guard s.count > maxChars else { return s }
        let head = String(s.prefix(maxChars))
        if let space = head.lastIndex(where: { $0 == " " || $0 == "\n" }) {
            return String(head[..<space])
        }
        return head
    }
}
