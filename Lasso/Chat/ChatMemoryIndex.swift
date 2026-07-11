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

    /// Drop the cached embedder so the next resolve re-reads the user's embedding-model choice. Called
    /// (with `reset()`) when the embedding backend changes in Settings — old vectors are incomparable
    /// with a new backend's, so the whole index rebuilds.
    func clearEmbedderCache() { embedderCache = nil }

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

    /// Retrieval tuning. NLEmbedding's cosines are too compressed to separate a genuine match from a
    /// topically-adjacent one (a real recall scored 0.34 while unrelated noise scored 0.36 in testing),
    /// so **lexical overlap** — sharing a significant keyword with the question — is the reliable
    /// precision gate. Semantic similarity only ranks the survivors, plus a high-bar OR-path that stays
    /// dormant for NLEmbedding and activates only for a stronger embedder (Ollama nomic-embed).
    private static let questionWeight = 0.7     // question vs. recent-context weight in the semantic score
    private static let highSemanticBar = 0.55   // pure-semantic escape hatch (only strong embedders reach it)

    /// Retrieve up to `k` older exchanges relevant to the current turn, excluding any already in the
    /// recent verbatim window. A candidate must share a keyword with the question (or clear the high
    /// semantic bar); survivors are ranked by semantic similarity + keyword overlap. An unrelated turn
    /// (no shared keywords, weak similarity) retrieves NOTHING. Works even with no embedder (lexical).
    func retrieve(question: String, context: String, excluding: Set<UUID>, k: Int = 2) async -> [String] {
        let candidates = chunks.filter { $0.messageIDs.isDisjoint(with: excluding) }
        guard !candidates.isEmpty, !question.isEmpty else { return [] }
        let qWords = Self.keywords(question)

        // Semantic vectors are best-effort — lexical gating still works if the embedder is unavailable.
        var qMain: [Double]?, qCtx: [Double]?
        if let embedder = await resolveEmbedder(),
           let qs = await embedder.embed([question, context]), qs.count == 2 {
            qMain = qs[0]; qCtx = qs[1]
        }

        let qCount = Double(max(1, qWords.count))
        struct Cand { let text: String; let sem: Double; let overlap: Int; let final: Double; let passes: Bool }
        var cands: [Cand] = []
        for c in candidates {
            var sem = 0.0
            if let qMain, let qCtx {
                sem = Self.questionWeight * OllamaEmbeddings.cosine(qMain, c.vector)
                    + (1.0 - Self.questionWeight) * OllamaEmbeddings.cosine(qCtx, c.vector)
            }
            let overlap = qWords.intersection(Self.keywords(c.text)).count
            // Gate on lexical overlap (the reliable precision signal), or a very high semantic score
            // that only a stronger embedder reaches. `final` normalizes keyword overlap to 0–1 and
            // adds semantic as a tiebreaker, so the score is legible and tunable.
            let passes = overlap > 0 || sem >= Self.highSemanticBar
            let final = (Double(overlap) / qCount) + 0.3 * sem
            cands.append(Cand(text: c.text, sem: sem, overlap: overlap, final: final, passes: passes))
        }
        cands.sort { $0.final > $1.final }

        var kept: [String] = []
        for c in cands where c.passes && kept.count < k { kept.append(c.text) }

        // Glanceable log: what was retrieved (✓) vs. skipped (• with reason) and the scores behind it —
        // so "why did it remember this?" is answerable at a glance.
        let keptChars = kept.reduce(0) { $0 + $1.count }
        Log.chat.debug("🧠 retrieve · kept \(kept.count, privacy: .public)/\(cands.count, privacy: .public) (\(keptChars, privacy: .public) chars) · q=\"\(String(question.prefix(44)), privacy: .public)\"")
        for c in cands.prefix(6) {
            let inTopK = kept.contains(c.text)
            let reason = inTopK ? "" : (c.passes ? " over-k" : " no-kw")
            Log.chat.debug("   \(inTopK ? "✓" : "•", privacy: .public) final=\(String(format: "%.2f", c.final), privacy: .public) sem=\(String(format: "%.3f", c.sem), privacy: .public) kw=\(c.overlap, privacy: .public)/\(Int(qCount), privacy: .public)\(reason, privacy: .public) · \(String(c.text.prefix(40)), privacy: .public)")
        }
        return kept
    }

    /// Significant keywords for lexical overlap: lowercase alphanumeric tokens ≥4 chars, minus common
    /// question/filler words. (Codes/numbers ≥4 chars are kept — a "TX-8841" recall can match on 8841.)
    private static func keywords(_ text: String) -> Set<String> {
        var out = Set<String>()
        for token in text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            let w = String(token)
            if w.count >= 4, !stopwords.contains(w) { out.insert(w) }
        }
        return out
    }

    private static let stopwords: Set<String> = [
        "what", "when", "where", "which", "that", "this", "then", "there", "here", "about", "again",
        "your", "yours", "yourself", "were", "was", "are", "have", "has", "had", "does", "did", "doing",
        "with", "from", "into", "than", "they", "them", "just", "like", "want", "need", "know", "tell",
        "remind", "give", "some", "will", "would", "could", "should", "please", "also", "over", "very",
        "much", "many", "more", "most", "such", "only", "still",
    ]

    // MARK: - Embedder ladder

    private func resolveEmbedder() async -> ChatEmbedder? {
        if let embedderCache { return embedderCache }
        let resolved = await Self.pickEmbedder()
        embedderCache = .some(resolved)
        Log.chat.notice("memory index embedder: \(resolved?.label ?? "none (retrieval off)", privacy: .public)")
        return resolved
    }

    /// Resolve the embedder from the user's Embedding-model choice (Settings ▸ Intelligence). The
    /// coordinator owns the ladder + local-only enforcement + cloud config, so this just delegates.
    private static func pickEmbedder() async -> ChatEmbedder? {
        await IntelligenceCoordinator.shared.makeEmbedder()
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

/// Ollama embeddings via the existing provider — better quality/multilingual. Returns nil when the
/// server/model isn't there, so resolution falls back to Apple.
struct OllamaChatEmbedder: ChatEmbedder {
    var model: String = "nomic-embed-text"
    var label: String { "Ollama · \(model)" }
    func embed(_ texts: [String]) async -> [[Double]]? {
        await OllamaEmbeddings(model: model).embed(texts)
    }
}

/// Cloud embeddings via an OpenAI-compatible `/embeddings` endpoint (e.g. text-embedding-3-small /
/// -large). Reuses the Language model's endpoint + key. **Sends conversation text off-device** — only
/// resolved when NOT in local-only mode (enforced by `effectiveEmbeddingProvider`).
struct OpenAIEmbedder: ChatEmbedder {
    let baseURL: URL
    let apiKey: String
    let model: String
    var label: String { "Cloud · \(model)" }

    func embed(_ texts: [String]) async -> [[Double]]? {
        guard !texts.isEmpty else { return [] }
        var request = URLRequest(url: baseURL.appendingPathComponent("embeddings"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20
        request.httpBody = try? JSONEncoder().encode(Req(model: model, input: texts))
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(Resp.self, from: data),
              decoded.data.count == texts.count else { return nil }
        // The API may return items out of order — sort by `index` before dropping it.
        return decoded.data.sorted { $0.index < $1.index }.map(\.embedding)
    }

    private struct Req: Encodable { let model: String; let input: [String] }
    private struct Resp: Decodable {
        struct Item: Decodable { let embedding: [Double]; let index: Int }
        let data: [Item]
    }
}
