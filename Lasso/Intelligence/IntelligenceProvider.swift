import Foundation
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
}

/// Which backend to use. Persisted in Settings.
enum ProviderKind: String, CaseIterable, Identifiable, Sendable {
    case onDevice
    case ollama
    case openAICompatible
    case anthropic

    var id: String { rawValue }
    var label: String {
        switch self {
        case .onDevice: "Apple Intelligence"
        case .ollama: "Ollama (local)"
        case .openAICompatible: "OpenAI-compatible"
        case .anthropic: "Anthropic"
        }
    }

    /// True for backends that keep everything on the Mac (a localhost OpenAI-compatible URL is
    /// still cloud-kind here; the provider itself reports the precise `isLocal`).
    var isLocalKind: Bool { self == .onDevice || self == .ollama }
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
        self.openAIBaseURL = defaults.string(forKey: "intelligence.openai.baseURL") ?? "https://api.openai.com/v1"
        self.openAIModel = defaults.string(forKey: "intelligence.openai.model") ?? "gpt-4o-mini"
        self.anthropicBaseURL = defaults.string(forKey: "intelligence.anthropic.baseURL") ?? "https://api.anthropic.com"
        self.anthropicModel = defaults.string(forKey: "intelligence.anthropic.model") ?? "claude-3-5-haiku-latest"
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

    /// Build the provider for the current preference (cloud reads its key from the Keychain; Ollama
    /// uses the resolved installed model).
    private func buildProvider() async -> IntelligenceProvider {
        switch effectivePreferred {
        case .onDevice:
            return onDevice
        case .ollama:
            return OllamaProvider(model: await resolvedTextModel())
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

    /// Resolve the active vision backend. Priority:
    ///   1. An explicit local "Image model" override — honored for *any* engine, so a user on a
    ///      text-only cloud model (e.g. a Groq Llama) can still identify images with a local vision
    ///      model instead of sending a doomed request to a non-multimodal endpoint.
    ///   2. The chosen cloud provider's model (assumed multimodal) when no override is set.
    ///   3. Local Ollama vision (the main model if it's multimodal, else the best installed one) —
    ///      also the fallback for Apple on-device, which is text-only.
    /// Returns nil when no vision backend is available.
    func activeVisionProvider() async -> VisionProvider? {
        // 1. Explicit override wins, regardless of engine.
        let installed = await OllamaModels.installed()
        if !visionModel.isEmpty, installed.contains(visionModel) {
            let override = OllamaVisionProvider(model: visionModel)
            if await override.isAvailable() { return override }
        }

        // 2. Cloud model serves vision directly when chosen and no override is set. (In local-only
        // mode `effectivePreferred` is on-device, so we never reach for a cloud vision endpoint.)
        let cloud: VisionProvider?
        switch effectivePreferred {
        case .openAICompatible:
            let url = URL(string: openAIBaseURL) ?? URL(string: "https://api.openai.com/v1")!
            cloud = OpenAICompatibleVisionProvider(
                baseURL: url, apiKey: Keychain.get("openai.apiKey") ?? "", model: openAIModel)
        case .anthropic:
            let url = URL(string: anthropicBaseURL) ?? URL(string: "https://api.anthropic.com")!
            cloud = AnthropicVisionProvider(
                baseURL: url, apiKey: Keychain.get("anthropic.apiKey") ?? "", model: anthropicModel)
        case .ollama, .onDevice:
            cloud = nil
        }
        if let cloud, await cloud.isAvailable() { return cloud }

        // 3. Local Ollama vision (main-if-multimodal, else best installed).
        let ollamaVision = OllamaVisionProvider(model: await resolvedVisionModel())
        if await ollamaVision.isAvailable() { return ollamaVision }
        return nil
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
}
