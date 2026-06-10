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

/// Independent provider for image understanding (Identify / Ask-AI-on-image), chosen separately from
/// the text engine so any mix is possible (cloud text + local image, a different cloud for images,
/// etc.). Apple on-device is intentionally excluded — its model is text-only.
enum VisionEngine: String, CaseIterable, Identifiable, Sendable {
    case matchText          // use the Text engine's model (only works if it's multimodal)
    case ollama             // a local Ollama vision model
    case openAICompatible
    case anthropic

    var id: String { rawValue }
    var label: String {
        switch self {
        case .matchText: "Same as text engine"
        case .ollama: "Ollama (local)"
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

    /// The image provider to actually use: in local-only mode any cloud choice is forced to local
    /// Ollama (and "Same as text" stays local only if the effective text engine is local).
    var effectiveVisionEngine: VisionEngine {
        guard PrivacyMode.localOnly else { return visionEngine }
        switch visionEngine {
        case .ollama: return .ollama
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
        case .ollama, .onDevice:
            return await localOllamaVision()
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
