import Foundation
import Observation
import SwiftUI

/// Pluggable text-intelligence backend. On-device is the default; a local Ollama server is the
/// opt-in "bigger model" path. Both run on this machine — nothing leaves the Mac (Spec §8).
protocol IntelligenceProvider: Sendable {
    var name: String { get }
    /// True for Apple's on-device Foundation Models. Ollama is `false` (separate process) but is
    /// still fully local — see `IntelligenceCoordinator.privacyNote`.
    var isAppleOnDevice: Bool { get }
    /// Whether the provider can serve a request right now.
    func checkAvailability() async -> Bool
    /// Stream a response as **incremental deltas** (append to accumulate).
    func respond(prompt: String, context: String?) -> AsyncThrowingStream<String, Error>
}

/// Which backend to use. Persisted in Settings.
enum ProviderKind: String, CaseIterable, Identifiable, Sendable {
    case onDevice
    case ollama

    var id: String { rawValue }
    var label: String {
        switch self {
        case .onDevice: "Apple Intelligence (on-device)"
        case .ollama: "Ollama (local server)"
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

    /// True once any cloud/off-machine call is ever made this session. Lasso never does today, so
    /// this stays false — surfaced by the privacy badge.
    private(set) var usedOffDeviceThisSession = false

    /// Name of the provider that served the most recent request (reflects fallback). Shown as
    /// attribution under AI results.
    private(set) var lastProviderName = ""
    private(set) var lastProviderIsAppleOnDevice = true

    private let onDevice = OnDeviceProvider()

    static let defaultsKey = "intelligence.provider"
    static let modelKey = "intelligence.ollamaModel"
    static let visionModelKey = "intelligence.visionModel"

    init() {
        let raw = UserDefaults.standard.string(forKey: Self.defaultsKey)
        self.preferred = raw.flatMap(ProviderKind.init(rawValue:)) ?? .onDevice
        // Default to "Auto" (empty) — resolved to an installed model at use time, never hardcoded.
        self.ollamaModel = UserDefaults.standard.string(forKey: Self.modelKey) ?? ""
        self.visionModel = UserDefaults.standard.string(forKey: Self.visionModelKey) ?? ""
    }

    /// Resolve the text model to use: the user's choice if installed, else the best installed chat
    /// model (Auto). Returns "" only when no suitable model is installed.
    func resolvedTextModel() async -> String {
        let installed = await OllamaModels.installed()
        if !ollamaModel.isEmpty, installed.contains(ollamaModel) { return ollamaModel }
        return OllamaModels.bestTextModel(installed) ?? ollamaModel
    }

    /// Resolve the vision model (user's choice if installed, else best installed vision model).
    func resolvedVisionModel() async -> String {
        let installed = await OllamaModels.installed()
        if !visionModel.isEmpty, installed.contains(visionModel) { return visionModel }
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

    /// Resolve the active provider, falling back to whichever is available. The Ollama provider is
    /// built from the resolved (installed) model so we never call a model that isn't pulled.
    func activeProvider() async -> IntelligenceProvider {
        let ollama = OllamaProvider(model: await resolvedTextModel())
        let primary: IntelligenceProvider = preferred == .onDevice ? onDevice : ollama
        if await primary.checkAvailability() { return primary }
        let fallback: IntelligenceProvider = preferred == .onDevice ? ollama : onDevice
        if await fallback.checkAvailability() {
            Log.intelligence.notice("Primary provider unavailable; falling back to \(fallback.name)")
            return fallback
        }
        return primary // let the call surface a clear error
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
