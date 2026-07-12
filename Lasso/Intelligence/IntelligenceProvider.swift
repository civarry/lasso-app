import Foundation
import FoundationModels
import Observation
import SwiftUI

/// Pluggable text-intelligence backend. On-device is the default; a local Ollama server is the
/// opt-in "bigger model" path. Both run on this machine — nothing leaves the Mac (Spec §8).
protocol IntelligenceProvider: Sendable {
    var name: String { get }
    /// True for Apple's on-device Foundation Models. Ollama is `false` (separate process) but is
    /// still fully local — see `isLocal`.
    var isAppleOnDevice: Bool { get }
    /// True when nothing leaves the Mac (Apple, Ollama, a localhost server). Cloud providers are
    /// `false` — drives the privacy badge.
    var isLocal: Bool { get }
    /// Whether the provider can serve a request right now.
    func checkAvailability() async -> Bool
    /// Stream a response as **incremental deltas** (append to accumulate).
    func respond(prompt: String, context: String?) -> AsyncThrowingStream<String, Error>
    /// Stream a response to a **multi-turn** conversation (for the Chat panel). Deltas, same as above.
    func respond(messages: [ChatTurn]) -> AsyncThrowingStream<String, Error>

    /// Whether this backend supports native tool/function calling. Drives whether the Chat panel
    /// offers the model a `web_search` tool (industry-standard, model-decides grounding) or falls
    /// back to the rule-based heuristic. Default: false.
    var supportsTools: Bool { get }

    /// Stream a response with tools the model may call. The provider runs the call loop — when the
    /// model requests a tool, `execute` is awaited and its result fed back — then streams the final
    /// answer as deltas. Default impl ignores tools (so non-tool backends transparently fall back).
    func respond(messages: [ChatTurn], tools: [ChatTool],
                 execute: @escaping ToolExecutor) -> AsyncThrowingStream<String, Error>
}

/// One message in a chat conversation, sent to a provider. A user turn may carry an image — encoded
/// base64 JPEG — for providers whose model is natively multimodal; text-only models get the image
/// folded into the text upstream (see `ChatController`).
struct ChatTurn: Sendable {
    enum Role: String, Sendable { case system, user, assistant }
    var role: Role
    var text: String
    /// Base64 JPEGs for a multimodal user turn (may be several — "compare these"). Empty for text-only.
    var imageBase64s: [String]

    init(role: Role, text: String, imageBase64s: [String] = []) {
        self.role = role
        self.text = text
        self.imageBase64s = imageBase64s
    }
}

extension IntelligenceProvider {
    /// Most backends don't (yet) do native tool calling — the Chat panel handles those via the
    /// heuristic grounding path instead.
    var supportsTools: Bool { false }

    /// Default: ignore tools and answer normally. Providers that set `supportsTools = true` override.
    func respond(messages: [ChatTurn], tools: [ChatTool],
                 execute: @escaping ToolExecutor) -> AsyncThrowingStream<String, Error> {
        respond(messages: messages)
    }

    /// Default multi-turn bridge for providers without a native implementation: flatten the history
    /// into a single prompt + context so the single-turn `respond` still carries the conversation.
    func respond(messages: [ChatTurn]) -> AsyncThrowingStream<String, Error> {
        let convo = messages.filter { $0.role != .system }
        let last = convo.last?.text ?? ""
        let priorLines = convo.dropLast().map { turn -> String in
            let speaker = turn.role == .user ? "User" : "Assistant"
            return "\(speaker): \(turn.text)"
        }
        let context = priorLines.isEmpty ? nil : priorLines.joined(separator: "\n\n")
        return respond(prompt: last, context: context)
    }
}

/// Which backend to use. Persisted in Settings.
enum ProviderKind: String, CaseIterable, Identifiable, Sendable {
    case onDevice
    case ollama
    case mlx
    case openAICompatible
    case anthropic

    var id: String { rawValue }
    var label: String {
        switch self {
        case .onDevice: "Apple Intelligence"
        case .ollama: "Ollama (local)"
        case .mlx: "MLX (local)"
        case .openAICompatible: "OpenAI-compatible"
        case .anthropic: "Anthropic"
        }
    }

    /// True for backends that keep everything on the Mac (a localhost OpenAI-compatible URL is
    /// still cloud-kind here; the provider itself reports the precise `isLocal`).
    var isLocalKind: Bool { self == .onDevice || self == .ollama || self == .mlx }
}

/// Independent provider for image understanding (Identify / Ask-AI-on-image), chosen separately from
/// the text engine so any mix is possible (cloud text + local image, a different cloud for images,
/// etc.). Apple on-device is intentionally excluded — its model is text-only.
enum VisionEngine: String, CaseIterable, Identifiable, Sendable {
    case matchText          // use the Text engine's model (only works if it's multimodal)
    case ollama             // a local Ollama vision model
    case mlx                // a local MLX vision-language model (Apple Silicon)
    case openAICompatible
    case anthropic

    var id: String { rawValue }
    var label: String {
        switch self {
        case .matchText: "Same as language model"
        case .ollama: "Ollama (local)"
        case .mlx: "MLX (local)"
        case .openAICompatible: "OpenAI-compatible"
        case .anthropic: "Anthropic"
        }
    }
}

/// Backend for the Chat semantic-memory embeddings (recall of relevant earlier messages). Peer to the
/// Language/Image model choices. `automatic` is the zero-setup default (Apple on-device, upgrading to a
/// local Ollama embed model if present); cloud reuses the Language model's OpenAI-compatible endpoint.
enum EmbeddingProviderKind: String, CaseIterable, Identifiable, Sendable {
    case automatic          // Ollama nomic-embed-text if installed, else Apple on-device, else none
    case apple              // force Apple NLEmbedding (built into macOS, zero download)
    case ollama             // a local Ollama embedding model
    case mlx                // a local MLX embedding model (bge / e5 / nomic …), downloaded in-app
    case openAICompatible   // cloud embeddings (reuses the Language model's endpoint + key)

    var id: String { rawValue }
    /// Labels follow the Language/Image picker convention: no editorial suffix on branded providers,
    /// `(local)` only on local runtimes. (Apple here is NaturalLanguage embeddings, not the Apple
    /// Intelligence LLM — so just "Apple".)
    var label: String {
        switch self {
        case .automatic: "Automatic"
        case .apple: "Apple"
        case .ollama: "Ollama (local)"
        case .mlx: "MLX (local)"
        case .openAICompatible: "OpenAI-compatible"
        }
    }
    /// Local kinds never leave the Mac — cloud is forced back to `automatic` in local-only mode.
    var isLocalKind: Bool { self != .openAICompatible }
}

/// Chooses and drives the active provider. The single entry point actions use for AI.
@MainActor
@Observable
final class IntelligenceCoordinator {
    static let shared = IntelligenceCoordinator()

    /// User preference (mirrored from `@AppStorage("provider")` by the app).
    var preferred: ProviderKind {
        didSet { UserDefaults.standard.set(preferred.rawValue, forKey: Self.defaultsKey) }
    }

    /// Ollama text model. Empty string means "Auto" — resolve to the best installed model at use
    /// time, so we never depend on a specific model being pulled.
    var ollamaModel: String {
        didSet { UserDefaults.standard.set(ollamaModel, forKey: Self.modelKey) }
    }

    /// Ollama vision model for Identify. Empty string means "Auto" (best installed vision model).
    var visionModel: String {
        didSet { UserDefaults.standard.set(visionModel, forKey: Self.visionModelKey) }
    }

    /// Local MLX vision (VLM) model id for the Image role.
    var visionMLXModel: String {
        didSet { UserDefaults.standard.set(visionMLXModel, forKey: "intelligence.vision.mlxModel") }
    }

    /// Image (vision) provider, independent of the text engine. Its cloud config + keys are separate
    /// from the text ones, so e.g. text=Groq + image=OpenAI GPT-4o is possible.
    var visionEngine: VisionEngine {
        didSet { UserDefaults.standard.set(visionEngine.rawValue, forKey: "intelligence.vision.engine") }
    }
    var visionOpenAIBaseURL: String {
        didSet { UserDefaults.standard.set(visionOpenAIBaseURL, forKey: "intelligence.vision.openai.baseURL") }
    }
    var visionOpenAIModel: String {
        didSet { UserDefaults.standard.set(visionOpenAIModel, forKey: "intelligence.vision.openai.model") }
    }
    var visionAnthropicBaseURL: String {
        didSet { UserDefaults.standard.set(visionAnthropicBaseURL, forKey: "intelligence.vision.anthropic.baseURL") }
    }
    var visionAnthropicModel: String {
        didSet { UserDefaults.standard.set(visionAnthropicModel, forKey: "intelligence.vision.anthropic.model") }
    }

    /// Cloud / custom provider config (non-secret; API keys live in the Keychain).
    var openAIBaseURL: String {
        didSet { UserDefaults.standard.set(openAIBaseURL, forKey: "intelligence.openai.baseURL") }
    }
    var openAIModel: String {
        didSet { UserDefaults.standard.set(openAIModel, forKey: "intelligence.openai.model") }
    }
    var anthropicBaseURL: String {
        didSet { UserDefaults.standard.set(anthropicBaseURL, forKey: "intelligence.anthropic.baseURL") }
    }
    var anthropicModel: String {
        didSet { UserDefaults.standard.set(anthropicModel, forKey: "intelligence.anthropic.model") }
    }

    /// MLX model identifier or registry key. Empty means "Auto" for the experimental native path.
    var mlxModel: String {
        didSet { UserDefaults.standard.set(mlxModel, forKey: "intelligence.mlx.model") }
    }

    // MARK: - Embedding (Chat semantic memory) config
    /// Chosen embedding backend for chat retrieval. Default `automatic` (Apple on-device, upgrading to
    /// Ollama if present) — zero setup for a fresh install.
    var embeddingProvider: EmbeddingProviderKind {
        didSet { UserDefaults.standard.set(embeddingProvider.rawValue, forKey: "intelligence.embedding.provider") }
    }
    /// Local Ollama embedding model name (when `embeddingProvider == .ollama`).
    var embeddingOllamaModel: String {
        didSet { UserDefaults.standard.set(embeddingOllamaModel, forKey: "intelligence.embedding.ollamaModel") }
    }
    /// Local MLX embedding model id (when `embeddingProvider == .mlx`).
    var embeddingMLXModel: String {
        didSet { UserDefaults.standard.set(embeddingMLXModel, forKey: "intelligence.embedding.mlxModel") }
    }
    /// Cloud embedding model name (when `embeddingProvider == .openAICompatible`). Embedding has its own
    /// independent OpenAI-compatible service/endpoint (like the Image model), so it can point at a
    /// provider that serves `/embeddings` even when the Language model uses one that doesn't.
    var embeddingOpenAIModel: String {
        didSet { UserDefaults.standard.set(embeddingOpenAIModel, forKey: "intelligence.embedding.openAIModel") }
    }
    /// The embedding provider's OpenAI-compatible base URL (its own, not the Language model's).
    var embeddingOpenAIBaseURL: String {
        didSet { UserDefaults.standard.set(embeddingOpenAIBaseURL, forKey: "intelligence.embedding.openai.baseURL") }
    }

    /// True once any cloud/off-machine call is made this session — surfaced by the privacy badge.
    private(set) var usedOffDeviceThisSession = false

    /// Name of the provider that served the most recent request (reflects fallback). Shown as
    /// attribution under AI results.
    private(set) var lastProviderName = ""
    private(set) var lastProviderIsAppleOnDevice = true
    private(set) var lastProviderIsLocal = true

    private let onDevice = OnDeviceProvider()

    static let defaultsKey = "intelligence.provider"
    static let modelKey = "intelligence.ollamaModel"
    static let visionModelKey = "intelligence.visionModel"

    init() {
        let defaults = UserDefaults.standard
        let raw = defaults.string(forKey: Self.defaultsKey)
        self.preferred = raw.flatMap(ProviderKind.init(rawValue:)) ?? .onDevice
        // Default to "Auto" (empty) — resolved to an installed model at use time, never hardcoded.
        self.ollamaModel = defaults.string(forKey: Self.modelKey) ?? ""
        self.visionModel = defaults.string(forKey: Self.visionModelKey) ?? ""
        self.visionMLXModel = defaults.string(forKey: "intelligence.vision.mlxModel") ?? MLXVisionProvider.defaultModelID
        self.openAIBaseURL = defaults.string(forKey: "intelligence.openai.baseURL") ?? "https://api.openai.com/v1"
        self.openAIModel = defaults.string(forKey: "intelligence.openai.model") ?? "gpt-4o-mini"
        self.anthropicBaseURL = defaults.string(forKey: "intelligence.anthropic.baseURL") ?? "https://api.anthropic.com"
        self.anthropicModel = defaults.string(forKey: "intelligence.anthropic.model") ?? "claude-3-5-haiku-latest"
        self.mlxModel = defaults.string(forKey: "intelligence.mlx.model") ?? MLXProvider.defaultModelID
        self.embeddingProvider = defaults.string(forKey: "intelligence.embedding.provider")
            .flatMap(EmbeddingProviderKind.init(rawValue:)) ?? .automatic
        self.embeddingOllamaModel = defaults.string(forKey: "intelligence.embedding.ollamaModel") ?? ""
        self.embeddingMLXModel = defaults.string(forKey: "intelligence.embedding.mlxModel") ?? MLXEmbeddings.defaultModelID
        // "" = use the text-embedding-3-small default; an empty field shows a placeholder (so it reads
        // as an editable text input, like the Language model's Model row) instead of a fixed label.
        self.embeddingOpenAIModel = defaults.string(forKey: "intelligence.embedding.openAIModel") ?? ""
        self.embeddingOpenAIBaseURL = defaults.string(forKey: "intelligence.embedding.openai.baseURL") ?? "https://api.openai.com/v1"
        self.visionOpenAIBaseURL = defaults.string(forKey: "intelligence.vision.openai.baseURL") ?? "https://api.openai.com/v1"
        self.visionOpenAIModel = defaults.string(forKey: "intelligence.vision.openai.model") ?? "gpt-4o"
        self.visionAnthropicBaseURL = defaults.string(forKey: "intelligence.vision.anthropic.baseURL") ?? "https://api.anthropic.com"
        self.visionAnthropicModel = defaults.string(forKey: "intelligence.vision.anthropic.model") ?? "claude-3-5-sonnet-latest"
        // Vision engine: stored choice, else migrate from the legacy "Image model" override (a set
        // visionModel meant "use this local Ollama model"; empty meant "use the main/text model").
        if let raw = defaults.string(forKey: "intelligence.vision.engine"), let v = VisionEngine(rawValue: raw) {
            self.visionEngine = v
        } else {
            self.visionEngine = (defaults.string(forKey: Self.visionModelKey)?.isEmpty == false) ? .ollama : .matchText
        }
    }

    /// Display name for the OpenAI-compatible provider, inferred from its base URL.
    func openAIDisplayName() -> String {
        let host = (URL(string: openAIBaseURL)?.host ?? "").lowercased()
        if host.contains("groq") { return "Groq" }
        if host.contains("openrouter") { return "OpenRouter" }
        if host.contains("openai") { return "OpenAI" }
        if host == "localhost" || host == "127.0.0.1" { return "Local" }
        return "Custom"
    }

    // MARK: - OpenAI-compatible services (per-service config, shared with Settings)

    /// The known OpenAI-compatible services and their canonical base URLs / names. Mirrors Settings so
    /// quick-switching from the chat header stays consistent with the editor.
    static let openAIServices = ["openai", "groq", "openrouter", "custom"]
    static func openAIServiceURL(_ service: String, custom: String) -> String {
        switch service {
        case "groq": return "https://api.groq.com/openai/v1"
        case "openrouter": return "https://openrouter.ai/api/v1"
        case "custom": return custom
        default: return "https://api.openai.com/v1"
        }
    }
    static func openAIServiceName(_ service: String) -> String {
        switch service {
        case "groq": return "Groq"
        case "openrouter": return "OpenRouter"
        case "custom": return "Custom"
        default: return "OpenAI"
        }
    }
    /// Per-service key only — never the shared/legacy "openai.apiKey", which holds the *active*
    /// service's key. Falling back to it made an unconfigured service (e.g. OpenAI) look configured
    /// by borrowing another service's key.
    private func openAIServiceKey(_ service: String) -> String {
        Keychain.get("openai.svc.\(service).key") ?? ""
    }
    /// The active OpenAI-compatible service key (UserDefaults), defaulting to "openai".
    var activeOpenAIService: String { UserDefaults.standard.string(forKey: "intelligence.openai.service") ?? "openai" }

    /// Services the user has configured (a key + a model) — for the chat header's quick switcher.
    func configuredOpenAIServices() -> [(service: String, name: String, model: String)] {
        Self.openAIServices.compactMap { s in
            let model = UserDefaults.standard.string(forKey: "intelligence.openai.svc.\(s).model") ?? ""
            guard !openAIServiceKey(s).isEmpty, !model.isEmpty else { return nil }
            return (s, Self.openAIServiceName(s), model)
        }
    }

    /// Switch the active OpenAI-compatible service (and its saved model + key) — the same commit
    /// Settings ▸ Apply performs, so the two never diverge.
    func switchOpenAIService(_ service: String) {
        let custom = UserDefaults.standard.string(forKey: "intelligence.openai.customBaseURL")
            ?? "https://api.openai.com/v1"
        openAIBaseURL = Self.openAIServiceURL(service, custom: custom)
        openAIModel = UserDefaults.standard.string(forKey: "intelligence.openai.svc.\(service).model") ?? openAIModel
        Keychain.set(openAIServiceKey(service), for: "openai.apiKey")
        UserDefaults.standard.set(service, forKey: "intelligence.openai.service")
        preferred = .openAICompatible
    }

    /// Resolve the text model to use: the user's choice if installed, else the best installed chat
    /// model (Auto). Returns "" only when no suitable model is installed.
    func resolvedTextModel() async -> String {
        let installed = await OllamaModels.installed()
        if !ollamaModel.isEmpty, installed.contains(ollamaModel) { return ollamaModel }
        return OllamaModels.bestTextModel(installed) ?? ollamaModel
    }

    /// Resolve the vision model for local Ollama. Priority:
    ///   1. The explicit "Image model" override, if the user picked one and it's installed.
    ///   2. The main text model when it's already multimodal — a vision-capable model serves both,
    ///      so no separate model is needed (the unification the user asked for).
    ///   3. Otherwise the best installed dedicated vision model.
    func resolvedVisionModel() async -> String {
        let installed = await OllamaModels.installed()
        if !visionModel.isEmpty, installed.contains(visionModel) { return visionModel }
        let mainText = ollamaModel.isEmpty
            ? (OllamaModels.bestTextModel(installed) ?? "") : ollamaModel
        if !mainText.isEmpty, installed.contains(mainText), OllamaModels.isVision(mainText) {
            return mainText
        }
        return OllamaModels.bestVisionModel(installed) ?? visionModel
    }

    /// Resolve the embedding model used for relevance ranking (best installed; nil → "" disables it).
    func resolvedEmbeddingModel() async -> String {
        OllamaModels.bestEmbeddingModel(await OllamaModels.installed()) ?? ""
    }

    // MARK: - Chat embedding backend (semantic memory)

    /// Effective embedding backend — local-only forces a cloud choice back to the local ladder, so no
    /// conversation text ever leaves the Mac (mirrors `effectivePreferred` / `effectiveVisionEngine`).
    var effectiveEmbeddingProvider: EmbeddingProviderKind {
        (PrivacyMode.localOnly && !embeddingProvider.isLocalKind) ? .automatic : embeddingProvider
    }

    /// Human label for the resolved embedding backend (Settings caption + logs).
    var embeddingEngineLabel: String {
        switch effectiveEmbeddingProvider {
        case .automatic: return "Automatic (Apple / Ollama)"
        case .apple: return "Apple (on-device)"
        case .ollama: return "Ollama · \(embeddingOllamaModel.isEmpty ? "auto" : embeddingOllamaModel)"
        case .mlx: return "MLX · \((embeddingMLXModel.isEmpty ? MLXEmbeddings.defaultModelID : embeddingMLXModel).components(separatedBy: "/").last ?? "auto")"
        case .openAICompatible:
            let host = (URL(string: embeddingOpenAIBaseURL)?.host ?? "").lowercased()
            let name = host.contains("groq") ? "Groq" : host.contains("openrouter") ? "OpenRouter"
                : host.contains("openai") ? "OpenAI" : (host == "localhost" || host == "127.0.0.1") ? "Local" : "Custom"
            return "\(name) · \(embeddingOpenAIModel.isEmpty ? "text-embedding-3-small" : embeddingOpenAIModel)"
        }
    }

    /// Build the Chat retrieval embedder for the current **effective** config. Vectors from different
    /// backends aren't comparable, so `ChatMemoryIndex` fully resets when this changes. Falls back to
    /// Apple on-device (never breaks retrieval); returns nil only when even Apple is unavailable.
    /// Cloud is only ever reached when NOT local-only (see `effectiveEmbeddingProvider`), so it can't leak.
    func makeEmbedder() async -> ChatEmbedder? {
        func apple() -> ChatEmbedder? { let a = AppleSentenceEmbedder(); return a.isAvailable ? a : nil }
        func probe(_ e: ChatEmbedder) async -> Bool { (await e.embed(["probe"]))?.first?.isEmpty == false }

        switch effectiveEmbeddingProvider {
        case .apple:
            return apple()

        case .automatic:
            if await OllamaEndpoint.isReachable(OllamaEndpoint.baseURL, maxAge: 30) {
                let o = OllamaChatEmbedder(model: "nomic-embed-text")
                if await probe(o) { Log.chat.notice("embedder: Ollama nomic-embed-text (auto)"); return o }
            }
            if let a = apple() { Log.chat.notice("embedder: Apple NLEmbedding (auto)"); return a }
            Log.chat.notice("embedder: none available (auto) — retrieval off"); return nil

        case .ollama:
            // Empty = "Auto" → best installed embedding model (avoids a hardcoded tag-less name that
            // mismatches Ollama's ":latest"). Falls back to nomic-embed-text as a last resort.
            let chosen = embeddingOllamaModel.trimmingCharacters(in: .whitespacesAndNewlines)
            let model = chosen.isEmpty ? (await resolvedEmbeddingModel().isEmpty ? "nomic-embed-text"
                                          : await resolvedEmbeddingModel()) : chosen
            if await OllamaEndpoint.isReachable(OllamaEndpoint.baseURL, maxAge: 30) {
                let o = OllamaChatEmbedder(model: model)
                if await probe(o) { Log.chat.notice("embedder: Ollama \(model, privacy: .public)"); return o }
            }
            Log.chat.notice("embedder: Ollama \(model, privacy: .public) unavailable → Apple"); return apple()

        case .mlx:
            let mlxModel = embeddingMLXModel.isEmpty ? MLXEmbeddings.defaultModelID : embeddingMLXModel
            // Don't block the first reply on a fresh download — fall back to Apple until it's installed
            // (Settings shows the download button). Once present, load + probe.
            guard MLXEmbeddings.isDownloaded(mlxModel) else {
                Log.chat.notice("embedder: MLX \(mlxModel, privacy: .public) not downloaded → Apple"); return apple()
            }
            let m = MLXChatEmbedder(model: mlxModel)
            if await probe(m) { Log.chat.notice("embedder: MLX \(mlxModel, privacy: .public)"); return m }
            Log.chat.notice("embedder: MLX \(mlxModel, privacy: .public) failed → Apple"); return apple()

        case .openAICompatible:
            // Embedding's own endpoint + key (independent of the Language model).
            let key = Keychain.get("embedding.openai.apiKey") ?? ""
            let model = embeddingOpenAIModel.isEmpty ? "text-embedding-3-small" : embeddingOpenAIModel
            guard !key.isEmpty, let url = URL(string: embeddingOpenAIBaseURL) else {
                Log.chat.notice("embedder: cloud embedding not configured → Apple"); return apple()
            }
            let e = OpenAIEmbedder(baseURL: url, apiKey: key, model: model)
            if await probe(e) {
                usedOffDeviceThisSession = true   // conversation text is being sent off-device
                Log.chat.notice("embedder: cloud \(model, privacy: .public)"); return e
            }
            Log.chat.notice("embedder: cloud \(model, privacy: .public) failed → Apple"); return apple()
        }
    }

    var privacyNote: String {
        usedOffDeviceThisSession
            ? "Cloud was used this session."
            : "All processing stayed on this Mac."
    }

    /// Human label for the configured **text** engine (e.g. "Groq · openai/gpt-oss-20b").
    var textEngineLabel: String {
        switch effectivePreferred {
        case .onDevice: return "Apple Intelligence"
        case .ollama: return ollamaModel.isEmpty ? "Ollama (auto)" : "Ollama · \(ollamaModel)"
        case .mlx: return mlxModel.isEmpty ? "MLX (auto)" : "MLX · \(mlxModel)"
        case .openAICompatible: return "\(openAIDisplayName()) · \(openAIModel)"
        case .anthropic: return "Anthropic · \(anthropicModel)"
        }
    }

    /// Human label for the configured **image** (vision) backend (e.g. "OpenAI · gpt-4o").
    var imageEngineLabel: String {
        func cloudName(_ urlString: String) -> String {
            let host = (URL(string: urlString)?.host ?? "").lowercased()
            if host.contains("groq") { return "Groq" }
            if host.contains("openrouter") { return "OpenRouter" }
            if host.contains("openai") { return "OpenAI" }
            if host == "localhost" || host == "127.0.0.1" { return "Local" }
            return "Cloud"
        }
        switch effectiveVisionEngine {
        case .matchText: return textEngineLabel   // images go through the text model
        case .ollama: return visionModel.isEmpty ? "Ollama vision (auto)" : "Ollama · \(visionModel)"
        case .mlx: return "MLX · \(visionMLXModel)"
        case .openAICompatible: return "\(cloudName(visionOpenAIBaseURL)) · \(visionOpenAIModel)"
        case .anthropic: return "Anthropic · \(visionAnthropicModel)"
        }
    }

    /// SF Symbol + short location note for the last provider, for result attribution.
    var lastProviderIcon: String {
        lastProviderIsAppleOnDevice ? "cpu" : (lastProviderIsLocal ? "server.rack" : "cloud")
    }
    var lastProviderLocationNote: String {
        lastProviderIsLocal ? "on this Mac" : "cloud · leaves your Mac"
    }

    /// The provider to actually use: in local-only mode a cloud engine is forced back to on-device,
    /// so nothing ever leaves the Mac regardless of what's stored.
    var effectivePreferred: ProviderKind {
        (PrivacyMode.localOnly && !preferred.isLocalKind) ? .onDevice : preferred
    }

    /// Context length (tokens) detected at runtime for the active provider, when we could read it:
    /// Ollama's `/api/show` and OpenAI-compatible `/v1/models` (Groq/OpenRouter expose it). Refreshed by
    /// `refreshContextWindow()`; nil until then or when the API doesn't expose it.
    private(set) var ollamaContextTokens: Int?
    private(set) var cloudContextTokens: Int?

    /// Approximate context-window length (in tokens) of the active text model, so the chat budget scales
    /// to it. MLX reads the model's real `max_position_embeddings`; Ollama/cloud use the runtime-detected
    /// value when available, else a conservative per-family default.
    var effectiveContextTokens: Int {
        switch effectivePreferred {
        case .mlx:      return MLXProvider.maxSequenceLength(mlxModel)
        case .onDevice: return 4_096                               // Apple on-device FM — small window
        case .ollama:   return ollamaContextTokens ?? 8_192
        case .openAICompatible:
            // 4-tier: manual override → detected (/v1/models) → inferred from model name → conservative.
            if openAIContextOverride > 0 { return openAIContextOverride }
            return cloudContextTokens ?? Self.inferContextFromModelName(openAIModel) ?? 32_000
        case .anthropic:
            return cloudContextTokens ?? Self.inferContextFromModelName(anthropicModel) ?? 200_000
        }
    }

    /// Manual context-window override (tokens) for the active OpenAI-compatible service; 0 = Auto. Set in
    /// Settings for a custom gateway (e.g. Claude 200K/1M) whose `/v1/models` doesn't advertise the window.
    var openAIContextOverride: Int {
        UserDefaults.standard.integer(forKey: "intelligence.openai.svc.\(activeOpenAIService).context")
    }

    /// Best-effort context window from a model id when the endpoint doesn't report one — covers the
    /// common families so a custom gateway serving Claude/GPT/Llama isn't wrongly clamped to the default.
    static func inferContextFromModelName(_ model: String) -> Int? {
        let m = model.lowercased()
        if m.contains("1m") { return 1_000_000 }
        if m.contains("gemini") { return 1_000_000 }
        if m.contains("claude") { return 200_000 }
        if m.contains("llama-3.1") || m.contains("llama-3.3") || m.contains("llama3.1") { return 131_072 }
        if m.contains("gpt-4o") || m.contains("gpt-4.1") || m.contains("gpt-4-turbo")
            || m.hasPrefix("o1") || m.hasPrefix("o3") || m.contains("gpt-4-1106") { return 128_000 }
        if m.contains("mixtral") || m.contains("mistral") { return 32_000 }
        return nil
    }

    /// The chat context budget for the active model — local uses a RAM-safe sweet spot, cloud a large
    /// slice of its window. Single source of truth, shared by the builder and the Ollama `num_ctx`.
    var contextBudget: ChatContextBuilder.Budget {
        .forContextTokens(effectiveContextTokens, isLocal: effectivePreferred.isLocalKind)
    }

    /// `num_ctx` to request from Ollama = the input budget (tokens) + a little output headroom, never
    /// above the model's real window. This is what actually lifts Ollama off its ~4096 default — kept
    /// modest so the KV cache doesn't eat device RAM.
    var ollamaNumCtx: Int {
        min(effectiveContextTokens, contextBudget.total / 4 + 1_200)
    }

    /// Detect the active model's real context window (Ollama `/api/show`, cloud `/v1/models`) and cache
    /// it. Best-effort: any failure leaves the conservative default in place. Never runs off-device work
    /// in local-only mode beyond the local Ollama server.
    func refreshContextWindow() async {
        switch effectivePreferred {
        case .ollama:
            guard await OllamaEndpoint.isReachable(OllamaEndpoint.baseURL, maxAge: 30) else { return }
            if let c = await OllamaEndpoint.contextLength(await resolvedTextModel()) { ollamaContextTokens = c }
        case .openAICompatible:
            guard !PrivacyMode.localOnly else { return }
            if let c = await fetchOpenAIContextLength() { cloudContextTokens = c }
        default:
            break
        }
    }

    /// GET `{baseURL}/models` and read the active model's context length where the provider exposes it
    /// (Groq `context_window`, OpenRouter `context_length` / `top_provider.context_length`).
    private func fetchOpenAIContextLength() async -> Int? {
        guard let base = URL(string: openAIBaseURL) else { return nil }
        let key = Keychain.getMigrating("openai.apiKey", legacyDefaultsKey: "openai.apiKey") ?? ""
        var request = URLRequest(url: base.appendingPathComponent("models"))
        if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        request.timeoutInterval = 5
        guard let (data, resp) = try? await URLSession.shared.data(for: request),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return Self.parseOpenAIContextLength(data, model: openAIModel)
    }

    /// Pull a context length out of an OpenAI-compatible `/v1/models` response for `model`. Internal for tests.
    static func parseOpenAIContextLength(_ data: Data, model: String) -> Int? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["data"] as? [[String: Any]] else { return nil }
        guard let entry = list.first(where: { ($0["id"] as? String) == model }) ?? list.first else { return nil }
        for key in ["context_window", "context_length", "max_context_length", "max_input_tokens"] {
            if let n = entry[key] as? Int, n > 0 { return n }
        }
        if let tp = entry["top_provider"] as? [String: Any], let n = tp["context_length"] as? Int, n > 0 {
            return n
        }
        return nil
    }

    /// True when the current config actually uses a local Ollama model (for text or image) — so we
    /// only probe / auto-start Ollama when it's relevant (no noise for cloud-only setups).
    var usesOllama: Bool {
        effectivePreferred == .ollama || effectiveVisionEngine == .ollama
            || effectiveEmbeddingProvider == .ollama
    }

    /// The image provider to actually use: in local-only mode any cloud choice is forced to local
    /// Ollama (and "Same as text" stays local only if the effective text engine is local).
    var effectiveVisionEngine: VisionEngine {
        guard PrivacyMode.localOnly else { return visionEngine }
        switch visionEngine {
        case .ollama: return .ollama
        case .mlx: return .mlx   // local — fine in local-only mode
        case .matchText: return effectivePreferred.isLocalKind ? .matchText : .ollama
        case .openAICompatible, .anthropic: return .ollama
        }
    }

    /// Build the provider for the current preference (cloud reads its key from the Keychain; Ollama
    /// uses the resolved installed model).
    private func buildProvider() async -> IntelligenceProvider {
        switch effectivePreferred {
        case .onDevice:
            return onDevice
        case .ollama:
            return OllamaProvider(model: await resolvedTextModel(), numCtx: ollamaNumCtx)
        case .mlx:
            return MLXProvider(modelID: mlxModel.isEmpty ? MLXProvider.defaultModelID : mlxModel)
        case .openAICompatible:
            let url = URL(string: openAIBaseURL) ?? URL(string: "https://api.openai.com/v1")!
            return OpenAICompatibleProvider(
                baseURL: url,
                apiKey: Keychain.getMigrating("openai.apiKey", legacyDefaultsKey: "openai.apiKey") ?? "",
                model: openAIModel, displayName: openAIDisplayName())
        case .anthropic:
            let url = URL(string: anthropicBaseURL) ?? URL(string: "https://api.anthropic.com")!
            return AnthropicProvider(
                baseURL: url,
                apiKey: Keychain.getMigrating("anthropic.apiKey", legacyDefaultsKey: "anthropic.apiKey") ?? "",
                model: anthropicModel)
        }
    }

    /// Resolve the active provider, falling back to on-device when the chosen one is unavailable.
    func activeProvider() async -> IntelligenceProvider {
        let primary = await buildProvider()
        if await primary.checkAvailability() { return primary }
        if await onDevice.checkAvailability() {
            Log.intelligence.notice("Primary provider unavailable; falling back to on-device")
            return onDevice
        }
        return primary // let the call surface a clear error
    }

    /// Resolve the active vision backend from the independent `visionEngine` choice. Returns nil when
    /// the chosen backend isn't usable (no key, server down, no installed model) — the caller surfaces
    /// a clear hint.
    func activeVisionProvider() async -> VisionProvider? {
        switch effectiveVisionEngine {
        case .matchText:
            return await visionFromTextEngine()
        case .ollama:
            return await localOllamaVision()
        case .mlx:
            let provider = MLXVisionProvider(modelID: visionMLXModel)
            return await provider.isAvailable() ? provider : nil
        case .openAICompatible:
            let url = URL(string: visionOpenAIBaseURL) ?? URL(string: "https://api.openai.com/v1")!
            let cloud = OpenAICompatibleVisionProvider(
                baseURL: url, apiKey: Keychain.get("vision.openai.apiKey") ?? "", model: visionOpenAIModel)
            if await cloud.isAvailable() { usedOffDeviceThisSession = true; return cloud }
            return nil
        case .anthropic:
            let url = URL(string: visionAnthropicBaseURL) ?? URL(string: "https://api.anthropic.com")!
            let cloud = AnthropicVisionProvider(
                baseURL: url, apiKey: Keychain.get("vision.anthropic.apiKey") ?? "", model: visionAnthropicModel)
            if await cloud.isAvailable() { usedOffDeviceThisSession = true; return cloud }
            return nil
        }
    }

    /// "Same as text engine": route images through the configured Text provider (cloud models serve
    /// vision directly; Apple is text-only, so it falls back to local Ollama vision).
    private func visionFromTextEngine() async -> VisionProvider? {
        switch effectivePreferred {
        case .openAICompatible:
            let url = URL(string: openAIBaseURL) ?? URL(string: "https://api.openai.com/v1")!
            let cloud = OpenAICompatibleVisionProvider(
                baseURL: url,
                apiKey: Keychain.getMigrating("openai.apiKey", legacyDefaultsKey: "openai.apiKey") ?? "",
                model: openAIModel)
            if await cloud.isAvailable() { usedOffDeviceThisSession = true; return cloud }
            return nil
        case .anthropic:
            let url = URL(string: anthropicBaseURL) ?? URL(string: "https://api.anthropic.com")!
            let cloud = AnthropicVisionProvider(
                baseURL: url,
                apiKey: Keychain.getMigrating("anthropic.apiKey", legacyDefaultsKey: "anthropic.apiKey") ?? "",
                model: anthropicModel)
            if await cloud.isAvailable() { usedOffDeviceThisSession = true; return cloud }
            return nil
        case .mlx:
            // A VLM text model serves images too — reuse it (one model for both roles).
            guard MLXProvider.isVision(mlxModel) else { return nil }
            let provider = MLXVisionProvider(modelID: mlxModel)
            return await provider.isAvailable() ? provider : nil
        case .ollama:
            return await localOllamaVision()
        case .onDevice:
            return nil   // Apple is text-only; no silent Ollama fallback — the user picks an image provider
        }
    }

    /// Local Ollama vision (resolved model: explicit override, main-if-multimodal, else best installed).
    private func localOllamaVision() async -> VisionProvider? {
        let provider = OllamaVisionProvider(model: await resolvedVisionModel())
        return await provider.isAvailable() ? provider : nil
    }

    private var lastVisionPrewarm = Date.distantPast

    /// Speculatively load the local vision model so Identify is warm by the time it's clicked. Only
    /// ever warms a *local* Ollama model — never fires a speculative cloud request — and debounces so
    /// rapid re-selections don't spam the server. Fire-and-forget; safe to call on every capture.
    func prewarmVision() {
        guard Date().timeIntervalSince(lastVisionPrewarm) > 20 else { return }
        lastVisionPrewarm = Date()
        Task {
            guard let ollama = await activeVisionProvider() as? OllamaVisionProvider else { return }
            await ollama.preload()
        }
    }

    /// Cached: is a vision backend available (a local Ollama vision model, or a configured cloud
    /// image model)? Drives greying of vision features. Refreshed at launch, after Save, and on
    /// capture. Side-effect-free — unlike `activeVisionProvider`, it never flips the privacy flag.
    private(set) var visionAvailable = false

    func refreshVisionAvailability() async {
        visionAvailable = await computeVisionAvailability()
    }

    private func computeVisionAvailability() async -> Bool {
        func cloudReady(_ keyAccount: String, _ model: String) -> Bool {
            !(Keychain.get(keyAccount) ?? "").isEmpty && !model.isEmpty
        }
        switch effectiveVisionEngine {
        // Explicit image provider: the user deliberately picked it for images — trust the config.
        case .openAICompatible: return cloudReady("vision.openai.apiKey", visionOpenAIModel)
        case .anthropic:        return cloudReady("vision.anthropic.apiKey", visionAnthropicModel)
        case .ollama:           return await hasInstalledVisionModel()
        case .mlx:              return MLXProvider.isDownloaded(visionMLXModel)
        // "Same as text": only counts as vision if the *text* model can actually see (a text-only
        // cloud model like Groq gpt-oss must not masquerade as a vision backend).
        case .matchText:
            switch effectivePreferred {
            case .openAICompatible: return cloudReady("openai.apiKey", openAIModel) && Self.looksMultimodal(openAIModel)
            case .anthropic:        return cloudReady("anthropic.apiKey", anthropicModel) && Self.looksMultimodal(anthropicModel)
            case .ollama:           return await hasInstalledVisionModel()
            case .mlx:              return MLXProvider.isVision(mlxModel) && MLXProvider.isDownloaded(mlxModel)
            case .onDevice:         return false   // Apple can't see images; no fallback
            }
        }
    }

    private func hasInstalledVisionModel() async -> Bool {
        let installed = await OllamaModels.installed()
        if installed.contains(where: OllamaModels.isVision) { return true }
        return !ollamaModel.isEmpty && OllamaModels.isVision(ollamaModel)
    }

    /// Heuristic: does the prompt ask for tabular/structured output? Kept conservative.
    static func looksLikeTableRequest(_ prompt: String) -> Bool {
        let lower = prompt.lowercased()
        let keywords = ["table", "csv", "spreadsheet", "tabulate", "columns", "rows", "grid", "in a table"]
        return keywords.contains { lower.contains($0) }
    }

    /// Safeguard for the on-device model (weak at hand-writing Markdown tables): produce a reliable
    /// table via guided generation, returned as Markdown. Sets attribution for the result footer.
    func onDeviceTableMarkdown(prompt: String, context: String?) async throws -> String {
        lastProviderName = onDevice.name
        lastProviderIsAppleOnDevice = true
        lastProviderIsLocal = true
        return try await onDevice.generateTableMarkdown(instruction: prompt, context: context)
    }

    // MARK: - Streaming with transient-error failover

    /// Record which provider actually served a request (drives the result-footer attribution and the
    /// privacy badge). Called again after a failover so the UI reflects the model that truly answered.
    private func setLastProvider(_ provider: IntelligenceProvider) {
        lastProviderName = provider.name
        lastProviderIsAppleOnDevice = provider.isAppleOnDevice
        lastProviderIsLocal = provider.isLocal
        if !provider.isLocal { usedOffDeviceThisSession = true }
    }

    /// The one safe failover target: the on-device Apple model. It's always **local** — so a cloud→local
    /// fallback can never leak, and local-only mode never reaches for the network — and it doesn't
    /// rate-limit. Returns nil when the primary already *is* on-device, or on-device isn't available on
    /// this Mac (nothing better to do → surface the original error).
    private func failoverProvider(from primary: IntelligenceProvider) async -> IntelligenceProvider? {
        guard !primary.isAppleOnDevice, await onDevice.checkAvailability() else { return nil }
        return onDevice
    }

    /// Whether an error is worth retrying on the fallback: transient outages (rate limits, timeouts,
    /// 5xx, network blips) — NOT bad keys, oversized prompts, or cancellation (retrying those just fails
    /// again, or is the user's own doing). Errors surface as `IntelligenceError.server(msg)` (HTTP text)
    /// or `URLError`, so we classify on both.
    static func isTransient(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .cannotConnectToHost, .cannotFindHost, .networkConnectionLost,
                 .notConnectedToInternet, .dnsLookupFailed, .resourceUnavailable:
                return true
            default:
                return false
            }
        }
        let m = error.localizedDescription.lowercased()
        // Explicit non-transient signals win (a rate-limit message never contains these).
        if m.contains("401") || m.contains("403") || m.contains("api key") || m.contains("unauthor")
            || m.contains("invalid") || m.contains("too large") || m.contains("cancel") {
            return false
        }
        return m.contains("429") || m.contains("rate limit") || m.contains("timed out")
            || m.contains("timeout") || m.contains("overloaded")
            || m.contains("500") || m.contains("502") || m.contains("503") || m.contains("504")
    }

    /// Shared streaming core with **pre-first-token** failover. Resolves the active provider, streams via
    /// `open`, and — if the stream throws a *transient* error **before any token was emitted** — retries
    /// once on the on-device model (never cloud), prefixing a short honest note. Once tokens have
    /// streamed we never swap mid-answer (that would splice two models); the error surfaces instead.
    private func streamWithFailover(
        label: String,
        _ open: @escaping @Sendable (IntelligenceProvider) -> AsyncThrowingStream<String, Error>
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [weak self] in
                guard let self else { continuation.finish(); return }
                let t0 = Date()
                var provider = await self.activeProvider()
                self.setLastProvider(provider)
                Log.intelligence.notice("\(label, privacy: .public) · provider=\(provider.name, privacy: .public) local=\(provider.isLocal, privacy: .public) (+\(Int(Date().timeIntervalSince(t0) * 1000), privacy: .public)ms)")
                var didFailover = false
                while true {
                    var emitted = false
                    do {
                        for try await delta in open(provider) {
                            emitted = true
                            continuation.yield(delta)
                        }
                        continuation.finish()
                        return
                    } catch {
                        if !emitted, !didFailover, Self.isTransient(error),
                           let fallback = await self.failoverProvider(from: provider) {
                            didFailover = true
                            Log.intelligence.notice("\(label, privacy: .public) · \(provider.name, privacy: .public) failed transiently (\(error.localizedDescription, privacy: .public)); failing over to \(fallback.name, privacy: .public)")
                            continuation.yield("_(\(provider.name) was unavailable — answered on-device with \(fallback.name).)_\n\n")
                            provider = fallback
                            self.setLastProvider(fallback)
                            continue
                        }
                        continuation.finish(throwing: error)
                        return
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Stream a response from the active provider.
    func respond(prompt: String, context: String?) -> AsyncThrowingStream<String, Error> {
        streamWithFailover(label: "respond(prompt)") { $0.respond(prompt: prompt, context: context) }
    }

    /// Whether the active **text** provider supports native tool calling — so the Chat panel knows to
    /// offer the model a `web_search` tool (model-decides grounding) instead of the rule-based
    /// heuristic. Resolves the Ollama model (which gates on family); cloud always supports it; Apple
    /// on-device supports it when available; MLX does not.
    func activeTextProviderSupportsTools() async -> Bool {
        switch effectivePreferred {
        case .openAICompatible, .anthropic:
            return true
        case .ollama:
            return OllamaModels.supportsTools(await resolvedTextModel())
        case .onDevice, .mlx:
            // Apple's on-device model is too small to tool-call reliably — attaching tools overflows
            // its context and throws GenerationError even on trivial prompts (verified). MLX has no
            // tool-calling path. Both use the heuristic grounding route instead.
            return false
        }
    }

    /// Stream a multi-turn response with tools the model may call (the Chat panel's grounded path).
    /// The resolved provider runs the tool loop; if it turns out not to support tools, it transparently
    /// answers without them.
    func respond(messages: [ChatTurn], tools: [ChatTool],
                 execute: @escaping ToolExecutor) -> AsyncThrowingStream<String, Error> {
        // The failover target (on-device) has no tool loop, so `supportsTools` is re-checked per
        // provider: the fallback transparently answers without tools.
        streamWithFailover(label: "respond(tools)") { provider in
            provider.supportsTools
                ? provider.respond(messages: messages, tools: tools, execute: execute)
                : provider.respond(messages: messages)
        }
    }

    /// Stream a response to a multi-turn conversation from the active provider (the Chat panel).
    func respond(messages: [ChatTurn]) -> AsyncThrowingStream<String, Error> {
        streamWithFailover(label: "respond(messages)") { $0.respond(messages: messages) }
    }

    /// Whether the active **text** model can natively accept an image in a chat message. Drives the
    /// Chat panel's "send the image natively vs. describe it via the vision provider" routing. Apple
    /// on-device is text-only; Ollama is checked by model name; cloud uses a conservative name
    /// heuristic (a native send that still fails falls back to a vision description upstream).
    func textModelSupportsVision() async -> Bool {
        switch effectivePreferred {
        case .onDevice:
            return false
        case .ollama:
            return OllamaModels.isVision(await resolvedTextModel())
        case .mlx:
            return MLXProvider.isVision(mlxModel)   // a VLM text model can take images natively
        case .openAICompatible:
            return Self.looksMultimodal(openAIModel)
        case .anthropic:
            return Self.looksMultimodal(anthropicModel)
        }
    }

    /// Conservative "is this cloud model multimodal" check by name. Errs toward false so we fall back
    /// to the dedicated vision provider rather than firing an image at a text-only model.
    static func looksMultimodal(_ model: String) -> Bool {
        let m = model.lowercased()
        // Anthropic: Claude 3+ are all vision-capable.
        if m.contains("claude-3") || m.contains("claude-4") || m.contains("claude-sonnet")
            || m.contains("claude-opus") || m.contains("claude-haiku") { return true }
        let hints = ["4o", "4.1", "gpt-5", "o3", "o4", "gemini", "-vl", "vl-", "llava", "vision",
                     "pixtral", "qwen-vl", "qwen2-vl", "qwen2.5-vl", "qwen3-vl", "llama-3.2-11b",
                     "llama-3.2-90b", "internvl", "minicpm-v"]
        return hints.contains { m.contains($0) }
    }
}
