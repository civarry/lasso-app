import Foundation

/// The model the **harness** thinks with, as opposed to the model that writes the answer.
///
/// Routing, planning, query rewriting and (later) verification are narrow, repetitive jobs with
/// typed outputs. They do not need the user's best model; they need a model that is always there,
/// costs nothing, answers fast, and can be *forced* into a valid shape. On Apple silicon that is the
/// on-device Foundation Models model, which is the only backend Lasso has with real constrained
/// decoding, so the harness prefers it regardless of what the user picked for chat.
///
/// Three properties this buys, in order of how much they matter:
/// 1. **Reliability.** Utility jobs run on the `.guided` rung, where malformed output is impossible.
/// 2. **Latency.** An MLX chat model no longer has to serialize a planning pass and the answer pass
///    through one `ModelContainer`, and a cold local model is not woken up twice.
/// 3. **Privacy and cost.** Harness thinking stays on the Mac even when the answer does not.
///
/// Calls made through here are deliberately **not attributed**: they bypass
/// `IntelligenceCoordinator.respond`, so `lastProvider…` and the privacy badge keep describing the
/// model that answered the user, not the plumbing. Utility calls are also always tool-free and
/// bounded, because the on-device window is ~4k and attaching tools to it overflows (see
/// `OnDeviceProvider.supportsTools`).
struct UtilityModel: Sendable {
    /// Where the utility model came from. `.activeProvider` means Apple Intelligence was unavailable
    /// (Intel Mac, or turned off) and the harness is borrowing the user's chat model instead.
    enum Source: String, Sendable {
        case appleOnDevice
        case activeProvider
    }

    let provider: any IntelligenceProvider
    let source: Source
    /// Invoked before a call that leaves the device, so the coordinator's session privacy flag stays
    /// truthful. Empty for every local provider, which is the normal case.
    private let noteUse: @Sendable () -> Void

    init(provider: any IntelligenceProvider, source: Source, noteUse: @escaping @Sendable () -> Void) {
        self.provider = provider
        self.source = source
        self.noteUse = noteUse
    }

    var label: String { provider.name }
    var isLocal: Bool { provider.isLocal }

    /// Ask for a typed value. Never throws: an unusable answer comes back as `value == nil` and the
    /// call site applies its own deterministic fallback.
    func structured<Value: StructuredOutput>(_ type: Value.Type, prompt: String,
                                             maxTokens: Int = 256) async -> StructuredResult<Value> {
        noteUse()
        let t0 = Date()
        let result = await StructuredRunner.run(type, prompt: prompt, provider: provider,
                                                maxTokens: maxTokens)
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        Log.intelligence.notice(
            "utility · \(Value.schemaName, privacy: .public) rung=\(result.rung.rawValue, privacy: .public) ok=\(result.succeeded, privacy: .public) on \(provider.name, privacy: .public) (\(ms, privacy: .public)ms)")
        return result
    }

    /// Warm the backend, when warming it is free. Only ever the Apple on-device model: a speculative
    /// cloud request would cost a real call, and loading an MLX model early would cost memory for a
    /// job that may never run.
    func prewarm() {
        guard source == .appleOnDevice, let onDevice = provider as? OnDeviceProvider else { return }
        onDevice.prewarm()
    }

    /// Free-text utility call, capped. For jobs with no schema worth declaring (a one-line summary).
    func text(prompt: String, maxChars: Int = 700) async -> String? {
        noteUse()
        var raw = ""
        do {
            for try await delta in provider.respond(prompt: prompt, context: nil) {
                if Task.isCancelled { return nil }
                raw += delta
                if raw.count > maxChars { break }
            }
        } catch {
            Log.intelligence.notice(
                "utility · text call failed on \(provider.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
        let cleaned = ModelText.stripThoughtBlocks(from: raw)
        return cleaned.isEmpty ? nil : cleaned
    }
}

extension IntelligenceCoordinator {
    /// Resolve the harness's utility model: Apple on-device when this Mac has it, otherwise the
    /// user's own active provider.
    ///
    /// The fallback is deliberately the *active* provider and never some other cloud service: the
    /// harness must not send text to an endpoint the user did not choose. Local-only mode needs no
    /// special case, since on-device is local and `activeProvider()` already resolves through
    /// `effectivePreferred`.
    /// Warm the harness's model when a surface that will use it opens (the chat panel). Fire and
    /// forget: a failure here only means the first planning call pays the load it would have anyway.
    func prewarmUtility() {
        Task { await utilityModel().prewarm() }
    }

    func utilityModel() async -> UtilityModel {
        if await onDevice.checkAvailability() {
            return UtilityModel(provider: onDevice, source: .appleOnDevice, noteUse: {})
        }
        let active = await activeProvider()
        var noteUse: @Sendable () -> Void = {}
        if !active.isLocal {
            noteUse = { Task { @MainActor in IntelligenceCoordinator.shared.noteOffDeviceUse() } }
        }
        Log.intelligence.notice(
            "utility · on-device unavailable; borrowing \(active.name, privacy: .public) for harness jobs")
        return UtilityModel(provider: active, source: .activeProvider, noteUse: noteUse)
    }
}
