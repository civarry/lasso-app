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

    /// Name of the Ollama model to use.
    var ollamaModel: String {
        didSet { UserDefaults.standard.set(ollamaModel, forKey: Self.modelKey) }
    }

    /// True once any cloud/off-machine call is ever made this session. Lasso never does today, so
    /// this stays false — surfaced by the privacy badge.
    private(set) var usedOffDeviceThisSession = false

    /// Name of the provider that served the most recent request (reflects fallback). Shown as
    /// attribution under AI results.
    private(set) var lastProviderName = ""
    private(set) var lastProviderIsAppleOnDevice = true

    private let onDevice = OnDeviceProvider()
    private var ollama: OllamaProvider { OllamaProvider(model: ollamaModel) }

    static let defaultsKey = "intelligence.provider"
    static let modelKey = "intelligence.ollamaModel"

    init() {
        let raw = UserDefaults.standard.string(forKey: Self.defaultsKey)
        self.preferred = raw.flatMap(ProviderKind.init(rawValue:)) ?? .onDevice
        self.ollamaModel = UserDefaults.standard.string(forKey: Self.modelKey) ?? "gpt-oss:20b"
    }

    var privacyNote: String {
        usedOffDeviceThisSession
            ? "Cloud was used this session."
            : "All processing stayed on this Mac."
    }

    /// Resolve the active provider, falling back to whichever is available.
    func activeProvider() async -> IntelligenceProvider {
        let primary: IntelligenceProvider = preferred == .onDevice ? onDevice : ollama
        if await primary.checkAvailability() { return primary }
        let fallback: IntelligenceProvider = preferred == .onDevice ? ollama : onDevice
        if await fallback.checkAvailability() {
            Log.intelligence.notice("Primary provider unavailable; falling back to \(fallback.name)")
            return fallback
        }
        return primary // let the call surface a clear error
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
