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
    var imageBase64: String?

    init(role: Role, text: String, imageBase64: String? = nil) {
        self.role = role
        self.text = text
        self.imageBase64 = imageBase64
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

    /// True when the current config actually uses a local Ollama model (for text or image) — so we
    /// only probe / auto-start Ollama when it's relevant (no noise for cloud-only setups).
    var usesOllama: Bool { effectivePreferred == .ollama || effectiveVisionEngine == .ollama }

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
            return OllamaProvider(model: await resolvedTextModel())
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

    /// Stream a response from the active provider.
    func respond(prompt: String, context: String?) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [weak self] in
                guard let self else { continuation.finish(); return }
                let provider = await self.activeProvider()
                self.lastProviderName = provider.name
                self.lastProviderIsAppleOnDevice = provider.isAppleOnDevice
                self.lastProviderIsLocal = provider.isLocal
                if !provider.isLocal { self.usedOffDeviceThisSession = true }
                do {
                    for try await delta in provider.respond(prompt: prompt, context: context) {
                        continuation.yield(delta)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
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
        AsyncThrowingStream { continuation in
            let task = Task { [weak self] in
                guard let self else { continuation.finish(); return }
                let provider = await self.activeProvider()
                self.lastProviderName = provider.name
                self.lastProviderIsAppleOnDevice = provider.isAppleOnDevice
                self.lastProviderIsLocal = provider.isLocal
                if !provider.isLocal { self.usedOffDeviceThisSession = true }
                let stream = provider.supportsTools
                    ? provider.respond(messages: messages, tools: tools, execute: execute)
                    : provider.respond(messages: messages)
                do {
                    for try await delta in stream { continuation.yield(delta) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Stream a response to a multi-turn conversation from the active provider (the Chat panel).
    func respond(messages: [ChatTurn]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [weak self] in
                guard let self else { continuation.finish(); return }
                let t0 = Date()
                Log.chat.notice("coordinator.respond · resolving active provider…")
                let provider = await self.activeProvider()
                Log.chat.notice("coordinator.respond · provider=\(provider.name, privacy: .public) local=\(provider.isLocal, privacy: .public) (+\(Int(Date().timeIntervalSince(t0) * 1000), privacy: .public)ms)")
                self.lastProviderName = provider.name
                self.lastProviderIsAppleOnDevice = provider.isAppleOnDevice
                self.lastProviderIsLocal = provider.isLocal
                if !provider.isLocal { self.usedOffDeviceThisSession = true }
                do {
                    for try await delta in provider.respond(messages: messages) {
                        continuation.yield(delta)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
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
