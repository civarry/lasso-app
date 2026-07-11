import Foundation
import HuggingFace
import MLX
import MLXEmbedders
import MLXHuggingFace
import MLXLMCommon
import Tokenizers   // required by the #huggingFaceTokenizerLoader() macro expansion

/// Local text embeddings via MLX (Apple-Silicon accelerated) — a fourth Chat-memory embedding backend
/// alongside Apple `NLEmbedding`, Ollama, and cloud. Uses the `MLXEmbedders` library from the same
/// package that already powers the Language/Image MLX models, so models download in-app exactly like
/// those (BERT-style encoders: bge / e5 / nomic / MiniLM …). Fully on-device — safe in local-only mode.
///
/// Retrieval is **symmetric** here (we compare chat exchanges to a query built from chat text), so every
/// string is embedded identically — no query/passage prefixes. (Prefix-tuning for e5/nomic is a possible
/// future refinement.)
enum MLXEmbeddings {
    /// Curated models for the picker, ordered by recommendation with a one-line strength (context window
    /// matters here — we embed whole exchange chunks, so a small window truncates long turns). No sizes
    /// in the labels — the download button shows the real (MLX-only) download size.
    static let suggestions: [(name: String, id: String)] = [
        ("Multilingual E5 small · multilingual, 512", "intfloat/multilingual-e5-small"),
        ("Nomic embed v1.5 · best quality, 8k context", "nomic-ai/nomic-embed-text-v1.5"),
        ("BGE small · English, fast, 512", "BAAI/bge-small-en-v1.5"),
        ("BGE base · English, accurate, 512", "BAAI/bge-base-en-v1.5"),
        ("GTE tiny · very fast, 512", "TaylorAI/gte-tiny"),
        ("MiniLM L6 · fastest, short 256 context", "sentence-transformers/all-MiniLM-L6-v2"),
    ]
    static let defaultModelID = "intfloat/multilingual-e5-small"

    static func isDownloaded(_ id: String) -> Bool { MLXProvider.isDownloaded(id) }

    /// Download (and warm) the model — reuses the container cache, which fetches on first load.
    static func ensureDownloaded(_ id: String,
                                 progress: @Sendable @escaping (Double) -> Void = { _ in }) async throws {
        if PrivacyMode.localOnly, !isDownloaded(id) {
            throw IntelligenceError.unavailable(
                "Local-only mode is on, so the MLX embedding model can't be downloaded (the fetch leaves "
                + "your Mac). Turn Local-only off to download it once; embedding stays on-device after.")
        }
        _ = try await MLXEmbedderCache.shared.container(for: id) { progress($0.fractionCompleted) }
    }

    /// Embed a batch of strings → unit-normalized vectors. Returns nil if the model can't be
    /// loaded/run, so the embedder ladder falls back to Apple.
    static func embed(_ texts: [String], modelID: String) async -> [[Double]]? {
        guard !texts.isEmpty else { return [] }
        do {
            let container = try await MLXEmbedderCache.shared.container(for: modelID)
            // Truncate to the model's window so a long exchange can't overflow a fixed-position encoder
            // (e.g. MiniLM's 256, most models' 512) — which would crash or garble the embedding.
            let maxTokens = MLXProvider.maxSequenceLength(modelID)
            let floats: [[Float]] = try await container.perform {
                (model: EmbeddingModel, tokenizer: MLXLMCommon.Tokenizer, pooling: Pooling) -> [[Float]] in
                let encoded = texts.map { Array(tokenizer.encode(text: $0, addSpecialTokens: true).prefix(maxTokens)) }
                let padID = tokenizer.eosToken.flatMap { tokenizer.convertTokenToId($0) } ?? 0
                let maxLen = encoded.reduce(into: 16) { $0 = max($0, $1.count) }
                let padded = stacked(encoded.map { row in
                    MLXArray(row + Array(repeating: padID, count: maxLen - row.count))
                })
                let mask = padded .!= padID
                let tokenTypes = MLXArray.zeros(like: padded)
                let pooled = pooling(
                    model(padded, positionIds: nil, tokenTypeIds: tokenTypes, attentionMask: mask),
                    normalize: true, applyLayerNorm: true)
                pooled.eval()
                return pooled.map { $0.asArray(Float.self) }
            }
            return floats.map { $0.map(Double.init) }
        } catch {
            Log.mlx.error("MLX embed FAILED (\(modelID, privacy: .public)): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

/// Load-once cache of `EmbedderModelContainer`, mirroring `MLXModelCache`: coalesces concurrent loads of
/// the same model, evicts on memory pressure and after an idle period.
private actor MLXEmbedderCache {
    static let shared = MLXEmbedderCache()

    private var containers: [String: EmbedderModelContainer] = [:]
    private var loading: [String: Task<EmbedderModelContainer, Error>] = [:]
    private var idleEviction: Task<Void, Never>?
    private var pressureSource: DispatchSourceMemoryPressure?
    private static let idleSeconds: UInt64 = 300   // embed models are small; keep a bit longer than LLMs

    func container(for modelID: String,
                   progress: (@Sendable (Progress) -> Void)? = nil) async throws -> EmbedderModelContainer {
        startMemoryPressureMonitorIfNeeded()
        scheduleIdleEviction()
        let id = MLXProvider.normalizedID(modelID)
        if let c = containers[id] { return c }
        if let inFlight = loading[id] { return try await inFlight.value }

        Log.mlx.notice("embed load START \(id, privacy: .public)")
        let task = Task<EmbedderModelContainer, Error> { [progress] in
            try await EmbedderModelFactory.shared.loadContainer(
                from: #hubDownloader(),
                using: #huggingFaceTokenizerLoader(),
                configuration: .init(id: id),
                progressHandler: progress ?? { _ in })
        }
        loading[id] = task
        defer { loading[id] = nil }
        let container = try await task.value
        containers[id] = container
        MLXProvider.markDownloaded(id)
        Log.mlx.notice("embed load DONE \(id, privacy: .public) · loaded=\(self.containers.count, privacy: .public)")
        return container
    }

    private func scheduleIdleEviction() {
        idleEviction?.cancel()
        idleEviction = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.idleSeconds * 1_000_000_000)
            if Task.isCancelled { return }
            await self?.evictAll(reason: "idle")
        }
    }

    func evictAll(reason: String) {
        guard !containers.isEmpty else { return }
        containers.removeAll()
        MLX.GPU.clearCache()
        Log.mlx.notice("embed EVICT [\(reason, privacy: .public)]")
    }

    private func startMemoryPressureMonitorIfNeeded() {
        guard pressureSource == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical], queue: .global(qos: .utility))
        source.setEventHandler { Task { await MLXEmbedderCache.shared.evictAll(reason: "memory pressure") } }
        source.resume()
        pressureSource = source
    }
}
