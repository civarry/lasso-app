import Foundation
import NaturalLanguage

/// In-session semantic memory for Chat: embeds completed conversation *exchanges* (a user turn + its
/// assistant reply) and, at send time, retrieves the few most relevant *older* exchanges verbatim so
/// specific details that scrolled out of the recent window — and were only lossily summarized — can be
/// recalled exactly. Complements the two-track running summary (`ConversationMemory`); it does not
/// replace it. Brute-force cosine over an in-memory list (a single chat is small) — no vector DB.
///
/// Embeddings use a zero-setup ladder (`resolveEmbedder`): Ollama `nomic-embed-text` if the user runs
/// it → Apple `NLEmbedding` (on-device, instant, any Mac) → none (retrieval silently off). So the app
/// always works; quality just improves. Reset per conversation (in-session only).
@MainActor
final class ChatMemoryIndex {
    /// One completed exchange to (maybe) index — the exact text the model saw, plus the covered ids.
    struct Exchange: Sendable {
        let messageIDs: Set<UUID>
        let text: String
    }

    private struct Chunk {
        let messageIDs: Set<UUID>
        let text: String
        let vector: [Double]
        let importance: Double
    }

    private var chunks: [Chunk] = []
    /// Number of exchanges already indexed, so re-indexing only embeds the new tail.
    private var indexedExchanges = 0
    /// Resolved once: `nil` = not yet resolved; `.some(nil)` = resolved to "no embedder available".
    private var embedderCache: (ChatEmbedder?)?

    func reset() {
        chunks.removeAll()
        indexedExchanges = 0
        // Keep the resolved embedder — the backend doesn't change within a session.
    }

    /// Index any completed exchanges not yet covered (background; off the send path). Cheap-skips
    /// trivial exchanges. No-op when nothing new or no embedder is available.
    func index(_ exchanges: [Exchange]) async {
        guard exchanges.count > indexedExchanges else { return }
        guard let embedder = await resolveEmbedder() else { return }
        let fresh = Array(exchanges.suffix(from: indexedExchanges))
        let worth = fresh.filter { Self.importance($0.text) > 0 }
        guard !worth.isEmpty else { indexedExchanges = exchanges.count; return }
        guard let vectors = await embedder.embed(worth.map(\.text)), vectors.count == worth.count else {
            return   // transient failure — retry on the next turn (don't advance the cursor)
        }
        for (ex, v) in zip(worth, vectors) {
            chunks.append(Chunk(messageIDs: ex.messageIDs, text: ex.text, vector: v,
                                importance: Self.importance(ex.text)))
        }
        indexedExchanges = exchanges.count
    }

    /// Up to `k` exchanges most relevant to `query`, excluding any that cover a message already in the
    /// recent verbatim window (`excluding`). Returns verbatim chunk texts, most-relevant first, or [].
    func retrieve(query: String, excluding: Set<UUID>, k: Int = 3, threshold: Double = 0.16) async -> [String] {
        guard !chunks.isEmpty, !query.isEmpty,
              let embedder = await resolveEmbedder(),
              let qv = await embedder.embed([query])?.first else { return [] }
        let ranked = chunks
            .filter { $0.messageIDs.isDisjoint(with: excluding) }
            .map { (text: $0.text, score: OllamaEmbeddings.cosine(qv, $0.vector) * (0.6 + 0.4 * $0.importance)) }
            .filter { $0.score >= threshold }
            .sorted { $0.score > $1.score }
        return ranked.prefix(k).map(\.text)
    }

    // MARK: - Embedder ladder

    private func resolveEmbedder() async -> ChatEmbedder? {
        if let embedderCache { return embedderCache }
        let resolved = await Self.pickEmbedder()
        embedderCache = .some(resolved)
        Log.chat.notice("memory index embedder: \(resolved?.label ?? "none (retrieval off)", privacy: .public)")
        return resolved
    }

    /// Probe the ladder once: Ollama (only if it actually returns a vector) → Apple → none.
    private static func pickEmbedder() async -> ChatEmbedder? {
        let ollama = OllamaChatEmbedder()
        if let probe = await ollama.embed(["probe"]), probe.first?.isEmpty == false { return ollama }
        let apple = AppleSentenceEmbedder()
        if apple.isAvailable { return apple }
        return nil
    }

    /// Cheap importance heuristic. 0 = trivial (skip from the index — "ok", "thanks"); higher = richer
    /// content that deserves a better shot at retrieval (long answers, code, links, "remember"/personal).
    static func importance(_ text: String) -> Double {
        let t = text.lowercased()
        if t.filter(\.isLetter).count < 12 { return 0 }
        var score = 0.3
        if text.count > 240 { score += 0.3 }
        if text.contains("```") || text.contains("();") || text.contains(") {") { score += 0.2 }
        if t.contains("http://") || t.contains("https://") || t.contains("/") { score += 0.1 }
        if t.contains("remember") || t.contains("my name") || t.contains("i'm ") || t.contains("i am ") {
            score += 0.2
        }
        return min(score, 1.0)
    }
}

// MARK: - Embedders

/// A text embedder for chat retrieval. Returns nil when unavailable so retrieval degrades gracefully.
protocol ChatEmbedder: Sendable {
    var label: String { get }
    func embed(_ texts: [String]) async -> [[Double]]?
}

/// Apple on-device sentence embeddings (NaturalLanguage) — zero setup, instant, offline on any Mac.
/// The ladder's baseline. Sentence embeddings exist for a set of languages; `isAvailable` is false
/// (→ skip) when the asset isn't present. `@unchecked Sendable`: `NLEmbedding.vector(for:)` is a
/// read-only query on an immutable model, safe to call concurrently.
struct AppleSentenceEmbedder: ChatEmbedder, @unchecked Sendable {
    let label = "Apple NLEmbedding"
    private let model: NLEmbedding?

    init(language: NLLanguage = .english) {
        model = NLEmbedding.sentenceEmbedding(for: language)
    }

    var isAvailable: Bool { model != nil }

    func embed(_ texts: [String]) async -> [[Double]]? {
        guard let model else { return nil }
        var out: [[Double]] = []
        out.reserveCapacity(texts.count)
        for t in texts {
            guard let v = model.vector(for: t.isEmpty ? " " : t) else { return nil }
            out.append(v)
        }
        return out
    }
}

/// Ollama embeddings (`nomic-embed-text`) via the existing provider — better quality/multilingual.
/// Returns nil when the server/model isn't there, so the ladder falls back to Apple.
struct OllamaChatEmbedder: ChatEmbedder {
    let label = "Ollama nomic-embed-text"
    func embed(_ texts: [String]) async -> [[Double]]? {
        await OllamaEmbeddings().embed(texts)
    }
}
