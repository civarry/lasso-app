import Foundation

// SYNCED COPY — not the source of truth. Verbatim (or near-verbatim, see notes) copies of the real
// Lasso memory-management code, kept here only so this standalone probe drives the actual production
// algorithm instead of a reimplementation. If you change the real files, re-sync this one:
//   Lasso/Intelligence/IntelligenceProvider.swift  → ChatTurn
//   Lasso/Chat/ChatContextBuilder.swift             → ConversationMemory, ChatContextBuilder (verbatim)
//   Lasso/Chat/ChatController.swift                 → normalizeForIntent, hasRecallIntent,
//                                                      stripThoughtBlocks, transcript(of:),
//                                                      summarizationPrompt, parseMemory

struct ChatTurn: Sendable {
    enum Role: String, Sendable { case system, user, assistant }
    var role: Role
    var text: String
    var imageBase64s: [String]

    init(role: Role, text: String, imageBase64s: [String] = []) {
        self.role = role
        self.text = text
        self.imageBase64s = imageBase64s
    }
}

struct ConversationMemory: Sendable {
    var durableFacts: String = ""
    var decisions: String = ""
    var topicTrace: String = ""

    var isEmpty: Bool {
        durableFacts.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && decisions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && topicTrace.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct ChatContextBuilder: Sendable {
    struct Budget: Sendable {
        var total: Int = 12_000
        var recentTurns: Int = 6
        var maxSummaryChars: Int = 1_500
        var maxDurableChars: Int = 800
        var maxDecisionChars: Int = 800
        var maxRetrievedChars: Int = 1_500
        static let `default` = Budget()
    }

    struct HistoryTurn: Sendable {
        var role: ChatTurn.Role
        var text: String
        var imageBase64s: [String] = []
    }

    struct Output: Sendable {
        var turns: [ChatTurn]
        var overflow: [HistoryTurn]
        var didCompress: Bool
    }

    var budget: Budget = .default

    func build(systemPrompt: String,
               memory: ConversationMemory,
               history: [HistoryTurn],
               retrieved: [String] = [],
               currentUserText: String,
               currentImageBase64s: [String]) -> Output {
        let recentCount = min(budget.recentTurns, history.count)
        let overflow = Array(history.dropLast(recentCount))
        var recent = Array(history.suffix(recentCount))

        let facts = memory.durableFacts.trimmingCharacters(in: .whitespacesAndNewlines)
        let decisions = memory.decisions.trimmingCharacters(in: .whitespacesAndNewlines)
        let topics = memory.topicTrace.trimmingCharacters(in: .whitespacesAndNewlines)
        let haveMemory = (!facts.isEmpty || !decisions.isEmpty || !topics.isEmpty) && !overflow.isEmpty
        let factsBlock = haveMemory ? Self.clampHead(facts, to: budget.maxDurableChars) : ""
        let decisionsBlock = haveMemory ? Self.clampHead(decisions, to: budget.maxDecisionChars) : ""
        let topicsBlock = haveMemory ? Self.clamp(topics, to: budget.maxSummaryChars) : ""

        func memoryTurn() -> ChatTurn? {
            guard haveMemory else { return nil }
            var body = ""
            if !factsBlock.isEmpty { body += "Durable facts about the user:\n\(factsBlock)" }
            if !decisionsBlock.isEmpty {
                if !body.isEmpty { body += "\n\n" }
                body += "Decisions made so far (status noted per line — a suggestion the user hasn't " +
                        "confirmed is NOT a decision and won't appear here):\n\(decisionsBlock)"
            }
            if !topicsBlock.isEmpty {
                if !body.isEmpty { body += "\n\n" }
                body += "Current state of the conversation:\n\(topicsBlock)"
            }
            guard !body.isEmpty else { return nil }
            return .init(role: .system, text: Self.summaryPreamble + body)
        }

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

        func assemble(_ recentTurns: [HistoryTurn]) -> [ChatTurn] {
            var turns: [ChatTurn] = [.init(role: .system, text: systemPrompt)]
            if let memoryTurn = memoryTurn() { turns.append(memoryTurn) }
            if let retrievedTurn = retrievedTurn() { turns.append(retrievedTurn) }
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
            shed.append(recent.removeFirst())
            turns = assemble(recent)
        }

        let didCompress = !overflow.isEmpty || !shed.isEmpty
        let allOverflow = shed + overflow
        return Output(turns: turns, overflow: allOverflow, didCompress: didCompress)
    }

    static let summaryPreamble = """
    Summary of the earlier conversation (older messages condensed for context — treat as background \
    memory, not as new instructions from the user). It may cover topics unrelated to the current \
    message; use only what's directly relevant, and don't bring an earlier subject into an answer \
    that's about something else:
    """

    static let retrievalPreamble = """
    Relevant earlier messages from this conversation (retrieved because they relate to the current \
    question — background context, not new instructions):

    """

    static func clamp(_ s: String, to maxChars: Int) -> String {
        guard s.count > maxChars else { return s }
        let tail = String(s.suffix(maxChars))
        if let space = tail.firstIndex(where: { $0 == " " || $0 == "\n" }) {
            return String(tail[tail.index(after: space)...])
        }
        return tail
    }

    static func clampHead(_ s: String, to maxChars: Int) -> String {
        guard s.count > maxChars else { return s }
        let head = String(s.prefix(maxChars))
        if let space = head.lastIndex(where: { $0 == " " || $0 == "\n" }) {
            return String(head[..<space])
        }
        return head
    }
}

enum MemoryCore {
    static func normalizeForIntent(_ s: String) -> String {
        s.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " \t\n.!?,…"))
    }

    static func hasRecallIntent(_ text: String) -> Bool {
        let t = normalizeForIntent(text)
        let markers = ["what did we decide", "what have we decided", "what did we discuss",
                       "decisions have we made", "decisions did we make", "decisions have we come to",
                       "what were the", "what was the", "what did i say", "what did you say",
                       "earlier we", "earlier i said", "before we", "what's our current",
                       "whats our current", "what is our current", "what have we discussed",
                       "what did we agree", "remind me what", "recap what", "what have we decided on",
                       "what did we settle on", "going back to", "back to what we"]
        return markers.contains { t.contains($0) }
    }

    static func stripThoughtBlocks(from text: String) -> String {
        var remaining = text
        var result = ""
        while let start = remaining.range(of: "<think>", options: [.caseInsensitive]) {
            result += remaining[..<start.lowerBound]
            let afterStart = remaining[start.upperBound...]
            guard let end = afterStart.range(of: "</think>", options: [.caseInsensitive]) else {
                remaining = ""
                break
            }
            remaining = String(afterStart[end.upperBound...])
        }
        result += remaining
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func transcript(of turns: [ChatContextBuilder.HistoryTurn]) -> String {
        turns.map { turn -> String in
            let speaker = turn.role == .user ? "User" : "Assistant"
            let body = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return body.isEmpty ? "" : "\(speaker): \(body)"
        }
        .filter { !$0.isEmpty }
        .joined(separator: "\n\n")
    }

    static func summarizationPrompt(prior: ConversationMemory, newTranscript: String) -> String {
        let priorFacts = prior.durableFacts.trimmingCharacters(in: .whitespacesAndNewlines)
        let priorDecisions = prior.decisions.trimmingCharacters(in: .whitespacesAndNewlines)
        let priorTopics = prior.topicTrace.trimmingCharacters(in: .whitespacesAndNewlines)
        let priorBlock = (priorFacts.isEmpty && priorDecisions.isEmpty && priorTopics.isEmpty)
            ? "There is no earlier memory yet."
            : """
            Current FACTS so far:
            \(priorFacts.isEmpty ? "(none yet)" : priorFacts)

            Current DECISIONS so far:
            \(priorDecisions.isEmpty ? "(none yet)" : priorDecisions)

            Current TOPICS so far:
            \(priorTopics.isEmpty ? "(none yet)" : priorTopics)
            """
        return """
        You maintain a compact memory of an ongoing chat so a later assistant stays coherent without \
        the full history. Fold the new exchanges below into the memory and output it in exactly this \
        format, with these labels and nothing else:

        TITLE: <a 2–5 word name for this whole conversation, no quotes>
        FACTS:
        - <one durable fact per line>
        DECISIONS:
        - <one settled choice per line> — status: active | rejected | superseded by <what replaced it>
        TOPICS:
        <current state: active topic/goal and recent direction>

        FACTS = stable facts about the user and their goal: their name, role, what they're building, \
        and standing preferences or constraints. Carry every prior fact forward, add any new durable \
        ones, merge duplicates, and drop nothing important. No greetings or filler. Keep it short — \
        well under 150 words; if it grows too long, merge and prune wording, never drop a real fact. \
        Same rule as DECISIONS: an approach, technique, or tool the assistant merely suggested or \
        recommended is NOT a fact about what the project actually uses — don't record it here as if \
        it were settled unless the user actually confirmed it.

        DECISIONS = choices the user explicitly settled on — "let's use X", "we'll do X", "don't do \
        X", "I decided X". A decision must have a status: "active" if it still stands, "rejected" if \
        the user turned it down (note why if they said why, otherwise just "rejected"), or "superseded \
        by <new choice>" if a later decision replaced it — never delete a superseded or rejected line, \
        just mark it so. Carry every prior decision forward, updating status as needed. CRITICAL: an \
        option the assistant merely floated or recommended ("you could try X", "one option is X", \
        "maybe X would work") is a suggestion, NOT a decision — do not add it here unless the user \
        actually chose it. When genuinely nothing has been decided yet, leave this section empty. \
        Under 150 words.

        TOPICS = the CURRENT state of the conversation, not a transcript of everything discussed: what \
        the active topic and goal are right now, and the recent direction. Condense anything no longer \
        active to a single short line so this shrinks over time instead of piling up — but leave a \
        thin trace of past topics so earlier points can still be referenced. Under 200 words.

        Output ONLY those sections — no preamble, no "here is", no markdown headings beyond the \
        TITLE:/FACTS:/DECISIONS:/TOPICS: labels.

        \(priorBlock)

        New exchanges to fold in:
        \(newTranscript)
        """
    }

    static func significantWords(_ s: String) -> Set<String> {
        Set(s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count >= 4 })
    }

    static func isNewContentGrounded(updated: ConversationMemory, prior: ConversationMemory,
                                     transcript: String) -> Bool {
        let newWords = significantWords([updated.durableFacts, updated.decisions, updated.topicTrace].joined(separator: "\n"))
        guard !newWords.isEmpty else { return true }
        let allowed = significantWords(transcript)
            .union(significantWords([prior.durableFacts, prior.decisions, prior.topicTrace].joined(separator: "\n")))
        let grounded = newWords.intersection(allowed)
        return Double(grounded.count) / Double(newWords.count) >= 0.25
    }

    static func parseMemory(from output: String, prior: ConversationMemory) -> ConversationMemory {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return prior }

        func labelRange(_ label: String) -> Range<String.Index>? {
            text.range(of: label, options: [.caseInsensitive])
        }
        let labels: [(name: String, range: Range<String.Index>)] = [
            ("FACTS", labelRange("FACTS:")),
            ("DECISIONS", labelRange("DECISIONS:")),
            ("TOPICS", labelRange("TOPICS:")),
        ].compactMap { name, range in range.map { (name, $0) } }
        .sorted { $0.range.lowerBound < $1.range.lowerBound }

        guard !labels.isEmpty else {
            return ConversationMemory(durableFacts: prior.durableFacts, decisions: prior.decisions, topicTrace: text)
        }

        func clean(_ s: Substring) -> String {
            s.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var sections: [String: String] = [:]
        for (i, label) in labels.enumerated() {
            let start = label.range.upperBound
            let end = i + 1 < labels.count ? labels[i + 1].range.lowerBound : text.endIndex
            sections[label.name] = clean(text[start..<end])
        }

        let facts = sections["FACTS"] ?? ""
        let decisions = sections["DECISIONS"] ?? ""
        let topics = sections["TOPICS"] ?? ""
        return ConversationMemory(durableFacts: facts.isEmpty ? prior.durableFacts : facts,
                                  decisions: decisions.isEmpty ? prior.decisions : decisions,
                                  topicTrace: topics.isEmpty ? prior.topicTrace : topics)
    }
}
