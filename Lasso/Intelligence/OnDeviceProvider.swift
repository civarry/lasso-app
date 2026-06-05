import Foundation
import FoundationModels

/// Apple Foundation Models provider — 100% on-device. Best for summarize / rewrite / explain /
/// extract over the on-screen text. Not a world-knowledge engine (Spec §8).
struct OnDeviceProvider: IntelligenceProvider {
    let name = "Apple Intelligence (on-device)"
    let isAppleOnDevice = true

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
