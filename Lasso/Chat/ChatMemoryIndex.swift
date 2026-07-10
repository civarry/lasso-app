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

        struct Ranked { let text: String; let semantic: Double; let overlap: Int }
        var ranked: [Ranked] = []
        for c in candidates {
            var sem = 0.0
            if let qMain, let qCtx {
                sem = Self.questionWeight * OllamaEmbeddings.cosine(qMain, c.vector)
                    + (1.0 - Self.questionWeight) * OllamaEmbeddings.cosine(qCtx, c.vector)
            }
            let overlap = qWords.intersection(Self.keywords(c.text)).count
            // Keep only clearly-relevant candidates: a shared keyword, or (strong embedder only) a very
            // high semantic score.
            if overlap > 0 || sem >= Self.highSemanticBar {
                ranked.append(Ranked(text: c.text, semantic: sem, overlap: overlap))
            }
        }
        guard !ranked.isEmpty else { return [] }
        ranked.sort { ($0.semantic + 0.1 * Double($0.overlap)) > ($1.semantic + 0.1 * Double($1.overlap)) }

        for r in ranked.prefix(5) {
            Log.chat.debug("retrieve · sem=\(String(format: "%.3f", r.semantic), privacy: .public) kw=\(r.overlap, privacy: .public) · \(String(r.text.prefix(48)), privacy: .public)")
        }
        return ranked.prefix(k).map(\.text)
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
