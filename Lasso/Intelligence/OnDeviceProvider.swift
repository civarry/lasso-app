import Foundation
import FoundationModels

/// Apple Foundation Models provider — 100% on-device. Best for summarize / rewrite / explain /
/// extract over the on-screen text. Not a world-knowledge engine (Spec §8).
struct OnDeviceProvider: IntelligenceProvider {
    let name = "Apple Intelligence (on-device)"
    let isAppleOnDevice = true
    let isLocal = true

    /// Set when this model is answering in place of one that is unavailable. A small local model handed
    /// a conversation it didn't take part in tends to answer as if the topic were new; being told what
    /// it is doing, and to work from the conversation in front of it, is the difference between a useful
    /// stand-in answer and one that reads as lost.
    var standingInFor: String?

    /// Apple's on-device window, and what's left for input once the reply is reserved (`replyOptions`).
    /// The pool's own filters use the same arithmetic for cloud candidates.
    static let contextTokens = 4_096
    static let inputBudgetTokens = contextTokens - 2_048

    /// Base codes of the languages Apple's model supports (23 on macOS 26; Filipino isn't one). It
    /// writes an unsupported language anyway, badly, so callers that know their languages ask first.
    static let supportedLanguageCodes: Set<String> =
        Set(SystemLanguageModel.default.supportedLanguages.map {
            LanguageDetect.baseCode($0.languageCode?.identifier ?? $0.minimalIdentifier)
        })

    /// Whether the model can read and write every language in `languages` (base codes).
    static func supports(languages: Set<String>) -> Bool {
        languages.isSubset(of: supportedLanguageCodes)
    }

    /// Display names of `languages` the model doesn't support, for an explanation.
    static func unsupportedNames(_ languages: Set<String>) -> String {
        languages.subtracting(supportedLanguageCodes).sorted()
            .map { Locale.current.localizedString(forLanguageCode: $0) ?? $0 }
            .joined(separator: ", ")
    }

    private static let instructions = """
    You transform and reason over text the user selected on their screen. \
    Be concise, accurate, and do not invent facts that are not present in the provided context.
    """

    /// Cap the reply length so input + output stay inside Apple's ~4096-token window. An *unbounded*
    /// response grows until it overflows and the session hard-stops with `.exceededContextWindowSize`
    /// (the "it just cuts off" behavior) — this makes it end cleanly at a sane length instead. Paired
    /// with the chat input budget (which caps input to fit the window), input + output ≤ 4096.
    private static let replyOptions = GenerationOptions(maximumResponseTokens: 2_048)

    func checkAvailability() async -> Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    func respond(prompt: String, context: String?) -> AsyncThrowingStream<String, Error> {
        stream(fullPrompt: Self.compose(prompt: prompt, context: context))
    }

    /// Multi-turn for the Chat panel. Apple's model is text-only (any attached image was converted to
    /// a text description upstream). We replay prior turns as a structured `Transcript` of
    /// `.prompt`/`.response` entries and stream only the *current* user turn — so the model sees real
    /// conversational turn boundaries instead of a flat "User:/Assistant:" text blob it would imitate
    /// and run past, inventing fake follow-up turns. The system prompt (plus any injected rolling
    /// summary) becomes the transcript's `.instructions`.
    func respond(messages: [ChatTurn]) -> AsyncThrowingStream<String, Error> {
        let instructions = mergedInstructions(from: messages)
        let convo = messages.filter { $0.role != .system && !$0.text.isEmpty }

        // The trailing user turn is the question to answer now; everything before it is prior context.
        guard let current = convo.last, current.role == .user else {
            // No current user turn (shouldn't happen in chat) — fall back to a plain instructions session.
            return stream(fullPrompt: convo.map(\.text).joined(separator: "\n\n"),
                          instructions: instructions)
        }

        var entries: [Transcript.Entry] = [
            .instructions(.init(segments: [.text(.init(content: instructions))], toolDefinitions: []))
        ]
        for turn in convo.dropLast() {
            let segments: [Transcript.Segment] = [.text(.init(content: turn.text))]
            switch turn.role {
            case .user:      entries.append(.prompt(.init(segments: segments)))
            case .assistant: entries.append(.response(.init(assetIDs: [], segments: segments)))
            case .system:    break
            }
        }
        return streamChat(transcript: Transcript(entries: entries), prompt: current.text)
    }

    /// Combine every system-role turn (the base prompt + any rolling-summary block injected by
    /// `ChatContextBuilder`) into one instructions string. Falls back to the default when there are none.
    private func mergedInstructions(from messages: [ChatTurn]) -> String {
        let systems = messages.filter { $0.role == .system && !$0.text.isEmpty }.map(\.text)
        return Self.withStandInNote(systems.isEmpty ? Self.instructions : systems.joined(separator: "\n\n"),
                                    standingInFor: standingInFor)
    }

    /// The prompt was written for the model the user chose. Say plainly what this one is, so it answers
    /// from the conversation instead of treating the last message as the start of a new one.
    static func withStandInNote(_ instructions: String, standingInFor: String?) -> String {
        guard let standingInFor else { return instructions }
        return instructions + """


        You are a smaller on-device model answering in place of \(standingInFor), which is unavailable \
        right now. This conversation began with that model: read the messages above and continue it. \
        Answer from what is in front of you, keep it brief, and say so in one line if something you'd \
        need was not included, rather than guessing or starting over.
        """
    }

    // MARK: - Tool calling

    /// Disabled: the on-device model is too small to tool-call reliably — attaching tools overflows
    /// its context window and throws `GenerationError` even on trivial prompts (verified in testing).
    /// The Chat panel routes on-device turns through the heuristic grounding path instead. The
    /// implementation below is kept (and reachable only if this is flipped back to `true`) so a future
    /// OS/model that handles tools well can re-enable it with a one-line change.
    var supportsTools: Bool { false }

    /// Attach the bridged `web_search` tool and let FoundationModels run the call loop. Other tools
    /// are ignored (only web search is wired). Falls back to a plain answer if no tool matches.
    func respond(messages: [ChatTurn], tools: [ChatTool],
                 execute: @escaping ToolExecutor) -> AsyncThrowingStream<String, Error> {
        let fmTools: [any Tool] = tools.compactMap { tool in
            guard tool.name == ChatTool.webSearch.name else { return nil }
            return WebSearchTool { query in
                let argsJSON = (try? JSONSerialization.data(withJSONObject: ["query": query]))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                return await execute(ToolCall(id: tool.name, name: tool.name, argumentsJSON: argsJSON))
            }
        }
        guard !fmTools.isEmpty else { return respond(messages: messages) }

        let instructions = Self.withStandInNote(messages.first(where: { $0.role == .system })?.text ?? Self.instructions,
                                                standingInFor: standingInFor)
        let transcript = messages
            .filter { $0.role != .system && !$0.text.isEmpty }
            .map { turn -> String in
                switch turn.role {
                case .user: "User: \(turn.text)"
                case .assistant: "Assistant: \(turn.text)"
                case .system: turn.text
                }
            }
            .joined(separator: "\n\n")
        let full = transcript.isEmpty ? "" : "\(transcript)\n\nAssistant:"
        return stream(fullPrompt: full, instructions: instructions, tools: fmTools)
    }

    private func stream(fullPrompt full: String, instructions: String = Self.instructions,
                        tools: [any Tool] = [])
        -> AsyncThrowingStream<String, Error> {
        streamSession(prompt: full) {
            tools.isEmpty
                ? LanguageModelSession(instructions: instructions)
                : LanguageModelSession(tools: tools, instructions: instructions)
        }
    }

    /// Multi-turn variant: seed the session with a prior-conversation `Transcript` and stream the
    /// current user turn against it.
    private func streamChat(transcript: Transcript, prompt: String)
        -> AsyncThrowingStream<String, Error> {
        streamSession(prompt: prompt) { LanguageModelSession(transcript: transcript) }
    }

    /// Shared streaming core: build a session, stream the prompt, and convert FoundationModels'
    /// *cumulative* snapshots into deltas so the ResultPane can simply append (matches the Ollama
    /// provider's contract). The session is constructed inside the Task via `makeSession`.
    private func streamSession(prompt: String,
                               makeSession: @escaping @Sendable () -> LanguageModelSession)
        -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard case .available = SystemLanguageModel.default.availability else {
                        throw IntelligenceError.unavailable(
                            "Apple Intelligence is off or unsupported on this Mac.")
                    }
                    let session = makeSession()
                    var emitted = ""
                    for try await partial in session.streamResponse(to: prompt, options: Self.replyOptions) {
                        let snapshot = partial.content
                        if snapshot.count >= emitted.count, snapshot.hasPrefix(emitted) {
                            let delta = String(snapshot.dropFirst(emitted.count))
                            if !delta.isEmpty { continuation.yield(delta) }
                        } else {
                            // Non-monotonic snapshot: re-emit whole thing.
                            continuation.yield(snapshot)
                        }
                        emitted = snapshot
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.friendly(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Apple's on-device model has a conservative safety guardrail that sometimes refuses benign
    /// content (foreign-language memes, etc.) with a terse "unsafe" error. Translate that into a
    /// clear, actionable message so it doesn't look like a Lasso bug.
    private static func friendly(_ error: Error) -> Error {
        let description = error.localizedDescription.lowercased()
        if description.contains("unsafe") || description.contains("guardrail")
            || description.contains("safety") {
            return IntelligenceError.server(
                "Apple's on-device model declined this content (its built-in safety filter — the "
                + "content may be fine). Switch the model to Ollama or a cloud model in Settings ▸ "
                + "Intelligence for fewer restrictions.")
        }
        if description.contains("context") && description.contains("exceed") {
            return IntelligenceError.server(
                "The selection is too large for Apple's on-device model. Try a smaller selection, or "
                + "switch the model in Settings ▸ Intelligence.")
        }
        return error
    }

    private static func compose(prompt: String, context: String?) -> String {
        guard let context, !context.isEmpty else { return prompt }
        return """
        \(prompt)

        --- On-screen text ---
        \(context)
        """
    }

    /// Warm the on-device model's resources ahead of the harness's first guided call. Measured on a
    /// real run, the first `search_plan` call cost 1455ms and later ones settled to ~830ms; this is
    /// aimed at that gap, not at the steady-state cost.
    func prewarm() {
        guard case .available = SystemLanguageModel.default.availability else { return }
        LanguageModelSession().prewarm()
    }

    // MARK: - Guided generation (constrained decoding)

    /// Fill a `@Generable` type directly. Constrained decoding makes malformed output *impossible*,
    /// not merely unlikely, which is what lets the harness put its own reasoning (routing, planning,
    /// verification) on a 3B on-device model and trust the result. See `StructuredRunner` rung 1.
    ///
    /// Tool-free and token-bounded by design: this window is ~4k, and attaching tools to it overflows
    /// (`supportsTools`).
    func generate<Value: Generable>(_ type: Value.Type, prompt: String, instructions: String?,
                                    maxTokens: Int) async throws -> Value {
        guard case .available = SystemLanguageModel.default.availability else {
            throw IntelligenceError.unavailable("Apple Intelligence is off or unsupported on this Mac.")
        }
        let session = instructions.map { LanguageModelSession(instructions: $0) }
            ?? LanguageModelSession()
        do {
            return try await session.respond(
                to: prompt, generating: type,
                options: GenerationOptions(temperature: 0, maximumResponseTokens: maxTokens)).content
        } catch {
            throw Self.friendly(error)
        }
    }

    // MARK: - Guided table generation

    /// Produce a table reliably via guided generation (the small on-device model is poor at
    /// hand-writing Markdown tables, but good at filling a typed schema). Returned as a Markdown
    /// table so `MarkdownView` renders it as a grid.
    func generateTableMarkdown(instruction: String, context: String?) async throws -> String {
        guard case .available = SystemLanguageModel.default.availability else {
            throw IntelligenceError.unavailable("Apple Intelligence is off or unsupported on this Mac.")
        }
        let session = LanguageModelSession(
            instructions: "Extract a clear table from the user's request and the on-screen text. "
                + "Use concise headers and one value per column for each row.")
        let prompt = Self.compose(prompt: instruction, context: context)
        let table: GeneratedTable
        do {
            table = try await session.respond(to: prompt, generating: GeneratedTable.self).content
        } catch {
            throw Self.friendly(error)
        }
        return Self.markdown(from: table)
    }

    private static func markdown(from table: GeneratedTable) -> String {
        guard !table.headers.isEmpty else { return "No tabular data found." }
        var lines: [String] = []
        lines.append("| " + table.headers.joined(separator: " | ") + " |")
        lines.append("| " + table.headers.map { _ in "---" }.joined(separator: " | ") + " |")
        for row in table.rows {
            var cells = row.cells
            if cells.count < table.headers.count {
                cells += Array(repeating: "", count: table.headers.count - cells.count)
            }
            lines.append("| " + cells.prefix(table.headers.count).joined(separator: " | ") + " |")
        }
        return lines.joined(separator: "\n")
    }
}

@Generable
struct GeneratedTable {
    @Guide(description: "The column header titles, concise")
    var headers: [String]
    @Guide(description: "The data rows; each row has one value per header, in the same order")
    var rows: [GeneratedTableRow]
}

@Generable
struct GeneratedTableRow {
    @Guide(description: "Cell values for this row, one per column")
    var cells: [String]
}

enum IntelligenceError: LocalizedError {
    case unavailable(String)
    case server(String)
    /// A stream that finished without a single token. Only raised for a fallback candidate (the free
    /// pool), where an empty answer means "try the next one" rather than "the model had nothing to say".
    case emptyResponse(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let m): m
        case .server(let m): m
        case .emptyResponse(let name): "\(name) returned an empty response."
        }
    }
}
