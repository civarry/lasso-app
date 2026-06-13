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
                    // BYOM: never silently download on the hot path. The user downloads the model
                    // explicitly in Settings first (Hugging Face fetch leaves the Mac); here we only
                    // run it once it's local.
                    guard Self.isDownloaded(modelID) else {
                        throw IntelligenceError.unavailable(
                            PrivacyMode.localOnly
                            ? "This MLX model isn't downloaded, and Local-only mode blocks the download (it would leave your Mac). Download it once with Local-only off in Settings ▸ Intelligence."
                            : "This MLX model isn't downloaded yet. Download it in Settings ▸ Intelligence (MLX), then try again.")
                    }
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

    // MARK: - Download / availability (BYOM: explicit, consented, tracked)

    private static let downloadedKey = "mlx.downloadedModels"

    static func downloadedModels() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: downloadedKey) ?? [])
    }

    static func isDownloaded(_ id: String) -> Bool {
        downloadedModels().contains(normalizedID(id))
    }

    static func markDownloaded(_ id: String) {
        var set = downloadedModels()
        set.insert(normalizedID(id))
        UserDefaults.standard.set(Array(set), forKey: downloadedKey)
    }

    static func normalizedID(_ id: String) -> String {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultModelID : trimmed
    }

    /// Fetch the model into the local Hugging Face cache (explicit user action from Settings). The
    /// fetch leaves the Mac, so it's blocked in Local-only mode. Once cached, inference is fully local.
    static func ensureDownloaded(_ id: String) async throws {
        let modelID = normalizedID(id)
        if PrivacyMode.localOnly, !isDownloaded(modelID) {
            throw IntelligenceError.unavailable(
                "Local-only mode is on, so the MLX model can't be downloaded (the fetch leaves your "
                + "Mac). Turn Local-only off to download it once; inference stays on-device after that.")
        }
        _ = try await MLXModelCache.shared.container(for: modelID)
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
        MLXProvider.markDownloaded(modelID)   // a successful load means it's cached on disk
        return container
    }
}
