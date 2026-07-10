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

    /// Retrieval relevance tuning. NLEmbedding cosines cluster high, so a flat threshold over-fires
    /// (retrieves noise on unrelated turns). Relevance is judged *relatively* — a chunk must stand out
    /// above the candidate set (mean + σ·`relevanceSigma`) — plus an absolute floor as a small-N
    /// backstop. Calibrate both from the `retrieve · score=…` debug logs on a real conversation.
    private static let relevanceSigma = 1.0
    private static let scoreFloor = 0.30
    /// Weight of the current question vs. the recent-context blend (helps follow-ups without letting
    /// off-topic recent turns dilute an explicit question).
    private static let questionWeight = 0.7

    /// Retrieve up to `k` older exchanges relevant to the current turn, excluding any already in the
    /// recent verbatim window. Scores blend the question (primary) with recent context (tiebreaker),
    /// then a relevance gate keeps only clear standouts — so an unrelated turn retrieves NOTHING.
    func retrieve(question: String, context: String, excluding: Set<UUID>, k: Int = 2) async -> [String] {
        let candidates = chunks.filter { $0.messageIDs.isDisjoint(with: excluding) }
        guard !candidates.isEmpty, !question.isEmpty,
              let embedder = await resolveEmbedder(),
              let qs = await embedder.embed([question, context]), qs.count == 2 else { return [] }
        let qMain = qs[0]
        let qCtx = qs[1]

        // Blend the question (primary) with the recent-context vector, nudged by importance.
        var scored: [(text: String, score: Double)] = []
        scored.reserveCapacity(candidates.count)
        for c in candidates {
            let main = OllamaEmbeddings.cosine(qMain, c.vector)
            let ctxSim = OllamaEmbeddings.cosine(qCtx, c.vector)
            let sim = Self.questionWeight * main + (1.0 - Self.questionWeight) * ctxSim
            scored.append((c.text, sim * (0.85 + 0.15 * c.importance)))
        }
        scored.sort { $0.score > $1.score }

        // Relevance gate: a chunk must stand clearly above the candidate mean (outlier), plus a floor.
        let n = Double(scored.count)
        var sum = 0.0
        for s in scored { sum += s.score }
        let mean = sum / n
        var varAcc = 0.0
        for s in scored { let d = s.score - mean; varAcc += d * d }
        let sd = (varAcc / n).squareRoot()
        let bar = mean + Self.relevanceSigma * sd

        for s in scored.prefix(5) {
            Log.chat.debug("retrieve · score=\(String(format: "%.3f", s.score), privacy: .public) bar=\(String(format: "%.3f", bar), privacy: .public) · \(String(s.text.prefix(48)), privacy: .public)")
        }

        var kept: [String] = []
        for s in scored where s.score >= bar && s.score >= Self.scoreFloor && kept.count < k {
            kept.append(s.text)
        }
        return kept
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
