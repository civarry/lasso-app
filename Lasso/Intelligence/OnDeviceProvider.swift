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
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard case .available = SystemLanguageModel.default.availability else {
                        throw IntelligenceError.unavailable(
                            "Apple Intelligence is off or unsupported on this Mac.")
                    }
                    let session = LanguageModelSession(instructions: Self.instructions)
                    let full = Self.compose(prompt: prompt, context: context)

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
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
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
        let table = try await session.respond(to: prompt, generating: GeneratedTable.self).content
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
