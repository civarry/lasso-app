import Foundation

/// The plain-code half of dictation cleanup: rules that need no model, and the check every model edit
/// must pass before it may replace what you said.
///
/// The check is the safety net. Clean may drop hesitations, filler words and accidental repeats, make
/// small grammar fixes, and fix punctuation. Anything else (a dropped word, a synonym, a reordering, an
/// answer instead of an edit, a changed number or negation) fails, and your words stay as they were.
///
/// Known gap (v1): filler words such as "like" are allowed to disappear wherever they appear, because
/// plain code can't tell a filler "like" from a meaningful one. A model that drops a meaningful "like"
/// ("I like the design" → "I the design") still passes the word check. Undo brings the original back.
enum DictationCleanup {

    // MARK: Rules (no model)

    /// Hesitations: never meaningful, always removed.
    static let hesitations: Set<String> = ["um", "umm", "uh", "uhh", "uhm", "er", "erm", "hmm", "hm"]

    /// Words said twice on purpose ("very very", "had had", "no no"): never collapsed.
    static let intentionalRepeats: Set<String> = [
        "had", "that", "very", "really", "so", "no", "yes", "bye", "ha", "now", "please", "too", "far",
        "many", "much", "more", "again", "over", "on", "out", "by", "go", "blah", "knock", "night", "is",
    ]

    /// Removes hesitations and accidental adjacent repeats ("I I think", "the the build"), and tidies
    /// the spacing and capitalization that removal leaves behind.
    static func tidy(_ text: String) -> String {
        var s = text
        // Hesitations, with the comma that usually follows ("Um, so" → "So").
        // Lowercase or capitalised only: "ER", "UM", "HM" in capitals are acronyms, not hesitations.
        s = replacing(#"\b(?:[Uu]m+|[Uu]h+|[Uu]hm|[Ee]rm?|[Hh]mm+|[Hh]m)\b,?[ \t]*"#, in: s) { match, ns in
            atSentenceStart(match.range.location, in: ns) ? "\u{1}" : ""
        }
        // Accidental repeats separated only by spaces ("the the" → "the"), skipping intentional ones.
        s = replacing(#"(?i)\b([\p{L}']+)(?:[ \t]+\1\b)+"#, in: s) { match, ns in
            let word = ns.substring(with: match.range(at: 1))
            let whole = ns.substring(with: match.range)
            // Capitalised every time ("Bora Bora", "Baden Baden"): a name, said on purpose.
            // (Not "I I think": one letter is the pronoun.)
            let names = word.count > 1
                && whole.split(whereSeparator: { $0 == " " || $0 == "\t" }).allSatisfy { $0.first?.isUppercase == true }
            return intentionalRepeats.contains(key(word)) || names ? whole : word
        }
        // Spacing left behind: doubled spaces, a space before punctuation, a dangling leading comma.
        s = replacing(#"[ \t]{2,}"#, in: s) { _, _ in " " }
        s = replacing(#"[ \t]+([,.!?;:])"#, in: s) { m, ns in ns.substring(with: m.range(at: 1)) }
        s = replacing(#",(?=\s*[,.!?])"#, in: s) { _, _ in "" }
        s = replacing(#"(^|[.!?]\s+)[ \t]*,[ \t]*"#, in: s) { m, ns in ns.substring(with: m.range(at: 1)) }
        // A removal at the start of a sentence leaves its next word to capitalize ("um, so" → "So").
        s = replacing(#"\x{01}+[\s.,]*(\p{Ll})?"#, in: s) { m, ns in
            m.range(at: 1).location == NSNotFound ? "" : ns.substring(with: m.range(at: 1)).uppercased()
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = s.first, first.isLowercase, text.trimmingCharacters(in: .whitespaces).first?.isUppercase == true {
            s = first.uppercased() + s.dropFirst()
        }
        return s
    }

    // MARK: The check

    /// Fillers the model may drop anywhere. See the type's note on the "like" gap.
    static let fillers: Set<String> = ["like", "basically", "actually", "literally", "well", "so", "okay", "ok"]
    static let fillerPhrases: [[String]] = [["you", "know"], ["i", "mean"], ["kind", "of"], ["sort", "of"]]
    /// Grammar words the model may drop ("say that the build" → "say the build").
    static let droppable: Set<String> = ["a", "an", "the", "that"]
    /// Grammar words the model may add (articles, auxiliaries).
    static let insertable: Set<String> = [
        "a", "an", "the", "is", "are", "was", "were", "am", "be", "been", "have", "has", "do", "does",
        "did", "to", "of", "it", "will",
    ]
    /// One-word swaps that are grammar fixes, never changes of meaning.
    static let grammarGroups: [Set<String>] = [
        ["a", "an", "the"], ["is", "are", "was", "were", "am", "be", "been", "being"], ["have", "has", "had"],
        ["do", "does", "did"], ["this", "these"], ["that", "those"], ["i", "me"], ["he", "him"],
        ["she", "her"], ["we", "us"], ["they", "them"], ["who", "whom"], ["there", "their", "theyre"],
        ["your", "youre"], ["to", "too"], ["then", "than"],
    ]
    static let negations: Set<String> = [
        "not", "no", "never", "none", "nobody", "nothing", "nowhere", "neither", "nor", "cannot", "without",
    ]
    /// Keys of "n't" words ("can't" → "cant").
    static let contractedNegations: Set<String> = [
        "dont", "doesnt", "didnt", "cant", "wont", "isnt", "arent", "wasnt", "werent", "shouldnt", "wouldnt",
        "couldnt", "havent", "hasnt", "hadnt", "aint", "mustnt", "neednt", "mightnt",
    ]
    static let numberWords: Set<String> = [
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven",
        "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen",
        "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety", "hundred",
        "thousand", "million", "billion", "half", "first", "second", "third", "once", "twice",
    ]

    /// Why `edited` may not replace `original`; empty when it may.
    static func problems(edited: String, original: String) -> [String] {
        let e = edited.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !e.isEmpty else { return ["The edit came back empty."] }
        let o = words(original), w = words(e)
        var found: [String] = []

        if numbers(o) != numbers(w) { found.append("A number changed.") }
        if negationMarks(o) != negationMarks(w) { found.append("A negation (not, no, never, n't) changed.") }
        if original.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?"), !e.hasSuffix("?") {
            found.append("A question became a statement.")
        }
        if !aligns(o.map(\.key), w.map(\.key)) {
            let kept = Set(o.map(\.key)), now = Set(w.map(\.key))
            let added = w.map(\.key).filter { !kept.contains($0) && !insertable.contains($0) }
            let dropped = o.map(\.key).filter {
                !now.contains($0) && !hesitations.contains($0) && !fillers.contains($0) && !droppable.contains($0)
            }
            if !added.isEmpty { found.append("Added words not said: \(unique(added).joined(separator: ", ")).") }
            if !dropped.isEmpty { found.append("Dropped words that were said: \(unique(dropped).joined(separator: ", ")).") }
            if added.isEmpty, dropped.isEmpty { found.append("Changed or reordered the speaker's words.") }
        }
        return found
    }

    /// Whether `w` is `o` with only the allowed edits: dropped hesitations, fillers, repeats and a few
    /// grammar words; added grammar words; one-word grammar swaps. Swaps and additions are budgeted so
    /// a pile of small changes can't add up to a rewrite.
    static func aligns(_ o: [String], _ w: [String]) -> Bool {
        let n = o.count, m = w.count
        let budget = max(3, n / 5)
        let inf = Int.max / 4
        // cost[i][j]: fewest budgeted edits turning o[i...] into w[j...].
        var cost = Array(repeating: Array(repeating: inf, count: m + 1), count: n + 1)
        cost[n][m] = 0
        for i in stride(from: n, through: 0, by: -1) {
            for j in stride(from: m, through: 0, by: -1) where !(i == n && j == m) {
                var best = inf
                if i < n, j < m, o[i] == w[j] { best = min(best, cost[i + 1][j + 1]) }
                if i < n, j < m, grammarSwap(o[i], w[j]) { best = min(best, cost[i + 1][j + 1] + 1) }
                if i < n, mayDrop(o, at: i) { best = min(best, cost[i + 1][j]) }
                if i + 1 < n, mayDropPair(o, at: i) { best = min(best, cost[i + 2][j]) }
                if j < m, insertable.contains(w[j]) { best = min(best, cost[i][j + 1] + 1) }
                cost[i][j] = best
            }
        }
        return cost[0][0] <= budget
    }

    private static func mayDrop(_ o: [String], at i: Int) -> Bool {
        let t = o[i]
        if hesitations.contains(t) || fillers.contains(t) || droppable.contains(t) { return true }
        // An accidental repeat ("I I think"): drop either copy.
        return (i + 1 < o.count && o[i + 1] == t) || (i > 0 && o[i - 1] == t)
    }

    private static func mayDropPair(_ o: [String], at i: Int) -> Bool {
        let pair = [o[i], o[i + 1]]
        if fillerPhrases.contains(pair) { return true }
        // A repeated two-word start ("I think I think").
        return i + 3 < o.count && o[i + 2] == o[i] && o[i + 3] == o[i + 1]
    }

    static func grammarSwap(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        if grammarGroups.contains(where: { $0.contains(a) && $0.contains(b) }) { return true }
        // Numbers and negations never change by "grammar" ("six" → "sixty", "can" → "can't").
        let guarded = { (s: String) in
            s.contains(where: \.isNumber) || numberWords.contains(s) || negations.contains(s) || contractedNegations.contains(s)
        }
        if guarded(a) || guarded(b) { return false }
        // Word forms share all but the last letter of the shorter word: "go" → "goes", "apple" →
        // "apples", "spend" → "spent". "GitHub" → "GitLab" or "ran" → "run" don't.
        let shorter = min(a.count, b.count)
        let prefix = zip(a, b).prefix { $0 == $1 }.count
        return prefix >= 2 && prefix >= shorter - 1 && abs(a.count - b.count) <= 3
    }

    // MARK: Words

    struct Word: Equatable {
        let text: String
        /// Lowercased, apostrophes removed: "Don't" and "dont" are the same word.
        var key: String { DictationCleanup.key(text) }
    }

    static func words(_ s: String) -> [Word] {
        let ns = s as NSString
        return wordPattern.matches(in: s, range: NSRange(location: 0, length: ns.length))
            .map { Word(text: ns.substring(with: $0.range)) }
    }

    static func key(_ word: String) -> String {
        word.lowercased().replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "\u{2019}", with: "")
    }

    private static let wordPattern = try! NSRegularExpression(pattern: #"\d+(?:[.,:/]\d+)*(?:st|nd|rd|th|%)?|[\p{L}\p{N}]+(?:['\x{2019}][\p{L}]+)*"#)

    private static func numbers(_ w: [Word]) -> [String] {
        w.map(\.key).filter { $0.contains(where: \.isNumber) || numberWords.contains($0) }
    }

    /// Negations in order. "can't" and "cannot" both read as a negation of "can".
    private static func negationMarks(_ w: [Word]) -> [String] {
        w.compactMap { word in
            let t = word.text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
            if t.hasSuffix("n't") || contractedNegations.contains(word.key) { return "not" }
            return negations.contains(t) ? (t == "cannot" ? "not" : t) : nil
        }
    }

    private static func unique(_ a: [String]) -> [String] {
        var seen = Set<String>()
        return a.filter { seen.insert($0).inserted }
    }

    // MARK: Regex helpers

    private static func replacing(_ pattern: String, in s: String,
                                  with transform: (NSTextCheckingResult, NSString) -> String) -> String {
        let regex = try! NSRegularExpression(pattern: pattern)
        let ns = s as NSString
        var out = s as NSString
        for match in regex.matches(in: s, range: NSRange(location: 0, length: ns.length)).reversed() {
            out = out.replacingCharacters(in: match.range, with: transform(match, ns)) as NSString
        }
        return out as String
    }

    /// True when nothing but spaces, or the end of a sentence, comes before `location`.
    private static func atSentenceStart(_ location: Int, in ns: NSString) -> Bool {
        var i = location - 1
        while i >= 0 {
            let c = ns.character(at: i)
            if c == 0x20 || c == 0x09 { i -= 1; continue }
            return c == 0x2E || c == 0x21 || c == 0x3F || c == 0x0A   // . ! ? newline
        }
        return true
    }
}
