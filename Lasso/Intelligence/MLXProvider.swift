import Foundation
import HuggingFace
import MLXLLM
import MLXHuggingFace
import MLXLMCommon
import Tokenizers

/// Experimental native MLX text provider.
struct MLXProvider: IntelligenceProvider {
    static let defaultModelID = "mlx-community/Qwen3-0.6B-4bit"

    let modelID: String

    var name: String { "MLX · \(modelID)" }
    let isAppleOnDevice = false
    let isLocal = true

    init(modelID: String = Self.defaultModelID) {
        self.modelID = modelID.isEmpty ? Self.defaultModelID : modelID
    }

    func checkAvailability() async -> Bool {
        !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func respond(prompt: String, context: String?) -> AsyncThrowingStream<String, Error> {
        var userContent = prompt
        if let context, !context.isEmpty {
            userContent += "\n\n--- On-screen text ---\n\(context)"
        }
        let messages = [
            ChatTurn(role: .system, text: Self.systemPrompt),
            ChatTurn(role: .user, text: userContent),
        ]
        return respond(messages: messages)
    }

    func respond(messages: [ChatTurn]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let model = try await MLXModelCache.shared.container(for: modelID)
                    let history = Self.history(from: messages)
                    let session = ChatSession(
                        model,
                        instructions: Self.systemPrompt,
                        history: history.prior,
                        generateParameters: .init(maxTokens: 1024, temperature: 0.2))
                    for try await chunk in session.streamResponse(
                        to: history.prompt, role: history.role, images: [], videos: []) {
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static let systemPrompt = """
    You help the user understand and act on text they selected on their screen. Be concise and \
    accurate. When on-screen text is provided, ground your answer in it.
    """

    private static func history(from turns: [ChatTurn]) -> (prior: [Chat.Message], prompt: String, role: Chat.Message.Role) {
        let visible = turns.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let last = visible.last ?? ChatTurn(role: .user, text: "")
        let prior = visible.dropLast().compactMap { turn -> Chat.Message? in
            switch turn.role {
            case .system:
                return nil
            case .user:
                return .user(turn.text)
            case .assistant:
                return .assistant(turn.text)
            }
        }
        return (Array(prior), last.text, mlxRole(for: last.role))
    }

    private static func mlxRole(for role: ChatTurn.Role) -> Chat.Message.Role {
        switch role {
        case .system: .system
        case .user: .user
        case .assistant: .assistant
        }
    }
}

private actor MLXModelCache {
    static let shared = MLXModelCache()

    private var containers: [String: ModelContainer] = [:]

    func container(for modelID: String) async throws -> ModelContainer {
        if let container = containers[modelID] { return container }
        let container = try await #huggingFaceLoadModelContainer(
            configuration: ModelConfiguration(id: modelID))
        containers[modelID] = container
        return container
    }
}
