import Foundation
import FoundationModels

/// Apple Foundation Models provider — 100% on-device. Best for summarize / rewrite / explain /
/// extract over the on-screen text. Not a world-knowledge engine (Spec §8).
struct OnDeviceProvider: IntelligenceProvider {
    let name = "Apple Intelligence (on-device)"
    let isAppleOnDevice = true
    let isLocal = true

    private static let instructions = """
    You transform and reason over text the user selected on their screen. \
    Be concise, accurate, and do not invent facts that are not present in the provided context.
    """

    func checkAvailability() async -> Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    func respond(prompt: String, context: String?) -> AsyncThrowingStream<String, Error> {
        stream(fullPrompt: Self.compose(prompt: prompt, context: context))
    }

    /// Multi-turn for the Chat panel. Apple's model is text-only and the session here is rebuilt per
    /// turn, so the conversation is replayed as a single labelled transcript (any attached image has
    /// already been converted to a text description upstream).
    func respond(messages: [ChatTurn]) -> AsyncThrowingStream<String, Error> {
        let instructions = messages.first(where: { $0.role == .system })?.text ?? Self.instructions
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
        return stream(fullPrompt: full, instructions: instructions)
    }

    private func stream(fullPrompt full: String, instructions: String = Self.instructions)
        -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard case .available = SystemLanguageModel.default.availability else {
                        throw IntelligenceError.unavailable(
                            "Apple Intelligence is off or unsupported on this Mac.")
                    }
                    let session = LanguageModelSession(instructions: instructions)

                    // FoundationModels streams *cumulative* snapshots; convert to deltas so the
                    // ResultPane can simply append (matches the Ollama provider's contract).
                    var emitted = ""
                    for try await partial in session.streamResponse(to: full) {
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
                + "content may be fine). Switch the engine to Ollama or a cloud model in Settings → "
                + "Intelligence for fewer restrictions.")
        }
        if description.contains("context") && description.contains("exceed") {
            return IntelligenceError.server(
                "The selection is too large for Apple's on-device model. Try a smaller selection, or "
                + "switch the engine in Settings → Intelligence.")
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

    var errorDescription: String? {
        switch self {
        case .unavailable(let m): m
        case .server(let m): m
        }
    }
}
