import Foundation

/// Lexical ranking over the candidate pool, and rank fusion.
///
/// Deliberately storage-free. Lasso has no SQLite, FTS5, CoreData or SwiftData anywhere: conversations
/// are JSON files and the search cache is a UserDefaults blob. A turn's candidate pool is 10 to 15
/// short documents, so BM25 over that pool is a few dictionary passes. Adding a database to index
/// fifteen titles would be new infrastructure for a corpus that fits in a `[String: Double]`.
///
/// No neural inference either: this runs whatever embedding provider the user selected, and adds no
/// second model to a machine that is already evicting the one it has.
enum LexicalRanker {
    /// Okapi BM25 defaults. Standard values, named so they are tunable in one place.
    static let k1 = 1.2
    static let b = 0.75

    /// Stopwords carry no retrieval signal but do carry weight in a small pool, where a common word
    /// looks rare. Measured: without this list "The Ones Who Walk Away from Omelas" was the top BM25
    /// hit for "who was the first human to walk on Mars in 1987", scoring on "who" and "walk".
    static let stopwords: Set<String> = [
        "the", "a", "an", "and", "or", "of", "in", "on", "at", "to", "for", "from", "by", "with",
        "is", "are", "was", "were", "be", "been", "being", "do", "does", "did", "has", "have", "had",
        "it", "its", "this", "that", "these", "those", "as", "who", "whom", "whose", "what", "which",
        "when", "where", "why", "how", "first", "last", "about", "into", "over", "under", "than",
        "then", "there", "their", "his", "her", "he", "she", "they", "them", "you", "your", "we",
        "our", "us", "can", "could", "should", "would", "will", "shall", "may", "might", "must",
        "not", "no", "yes", "if", "so", "but", "also", "any", "some", "all", "tell", "give", "show",
    ]

    static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 2 && !stopwords.contains($0) }
    }

    /// BM25 score per document, IDF computed over the pool itself.
    ///
    /// A note on what this can and cannot do here: every candidate was retrieved *because* it matched
    /// the query, so the pool's IDF is compressed and BM25's discriminative power is limited. It earns
    /// its place on proper nouns and exact identifiers, where an embedding will happily rank a topical
    /// neighbour above an exact match. It is not evidence of correctness, which is why it feeds the
    /// ordering and never the admission decision.
    static func bm25(query: String, documents: [String]) -> [Double] {
        let docTokens = documents.map(tokens)
        let n = Double(documents.count)
        guard n > 0 else { return [] }
        let avgLength = docTokens.reduce(0.0) { $0 + Double($1.count) } / n

        var documentFrequency: [String: Double] = [:]
        for doc in docTokens {
            for term in Set(doc) { documentFrequency[term, default: 0] += 1 }
        }
        let queryTerms = Set(tokens(query))

        return docTokens.map { doc in
            var termFrequency: [String: Double] = [:]
            for term in doc { termFrequency[term, default: 0] += 1 }
            var score = 0.0
            for term in queryTerms {
                guard let f = termFrequency[term], let df = documentFrequency[term] else { continue }
                let idf = log(1 + (n - df + 0.5) / (df + 0.5))
                let norm = f + k1 * (1 - b + b * Double(doc.count) / max(avgLength, 1))
                score += idf * (f * (k1 + 1)) / norm
            }
            return score
        }
    }
}

/// Reciprocal Rank Fusion: combine rankings without ever adding raw scores from different scales.
///
/// RRF(d) = Σ 1 / (k + rank_i(d))
enum RankFusion {
    /// Conventional value from the original RRF paper. Named rather than scattered: it damps the
    /// contribution of any single ranking's top position, so one confident-but-wrong ranker cannot
    /// dominate the fused order.
    static let k = 60.0

    /// 1-based dense ranks, best score first. Ties resolve by index, which keeps the order stable.
    static func ranks(of scores: [Double]) -> [Int] {
        let ordered = scores.enumerated().sorted { a, b in
            a.element == b.element ? a.offset < b.offset : a.element > b.element
        }.map(\.offset)
        var result = [Int](repeating: 0, count: scores.count)
        for (position, index) in ordered.enumerated() { result[index] = position + 1 }
        return result
    }

    /// Fuse any number of rankings over the same document set. A document ranked by only one strategy
    /// still scores, it simply receives one contribution instead of several.
    static func fuse(_ rankings: [[Int]], count: Int) -> [Double] {
        var fused = [Double](repeating: 0, count: count)
        for ranking in rankings where ranking.count == count {
            for index in 0..<count { fused[index] += 1.0 / (k + Double(ranking[index])) }
        }
        return fused
    }
}
