import Foundation

/// Lasso's own words that packages can patch (`PatchTargets`), kept apart from the actions so the
/// package tools (`lasso-pkg`) can read them without the app.
enum BuiltInContent {
    /// Built-in action names.
    enum Title {
        static let askAI = "Ask AI"
        static let copyText = "Copy text"
        static let identify = "Identify"
        static let lens = "Lens"
        static let openCode = "Open code"
        static let pickColor = "Pick color"
        static let proofread = "Proofread"
        static let summarize = "Summarize"
        static let translate = "Translate"
    }

    /// Built-in action icons (SF Symbols).
    enum Symbol {
        static let askAI = "bubble.left.and.bubble.right"
        static let copyText = "text.viewfinder"
        static let identify = "sparkle.magnifyingglass"
        static let lens = "photo.badge.magnifyingglass"
        static let openCode = "qrcode.viewfinder"
        static let pickColor = "eyedropper"
        static let proofread = "text.badge.checkmark"
        static let summarize = "text.line.3.summary"
        static let translate = "translate"
    }

    /// The empty chat's greeting, and the message box's hint.
    static let chatGreeting = "How can I help?"
    static let chatPlaceholder = "Message…"

    static let summarizePrompt = "Summarize the on-screen text in 2–3 sentences. Be faithful to the source."

    /// The instruction + few-shot examples. Enumerating the error types and showing the hard cases
    /// (tense, compound-subject case, agreement, adverb/adjective, multi-error chains) is what makes
    /// small/on-device models actually fix them — a bare "fix only, don't restructure" makes them too
    /// timid. Voice/tone/slang are still preserved; only genuine errors change. Shared with the
    /// in-place selected-text flow (`GrammarFixService`).
    static let proofreadPrompt = """
    You are an expert grammar correction engine.

    Correct every grammar, spelling, punctuation, capitalization, verb-tense, subject-verb agreement, \
    pronoun, word-form, article, preposition, and sentence-structure error. A sentence may contain \
    several mistakes — fix all of them, not just the first.

    Grammatical correctness comes before preserving exact wording: rewrite words, phrases, clauses, \
    or whole sentences when needed to make the text correct and natural.

    Preserve the author's meaning, tone, voice, level of formality, and slang whenever possible. Do NOT:
    - rewrite for style or elegance, or make text more formal;
    - replace casual phrasing or slang that is already correct;
    - swap numbers for words or words for numbers;
    - change vocabulary by preference, or add or remove meaning.

    Use time expressions as tense cues ("yesterday", "last week" point to past; "tomorrow", \
    "next week" point to future).

    If there is nothing to correct — a URL, file path, email address, code, a number, a single token, \
    or text that is already correct — return it EXACTLY as given. Never ask a question, never explain, \
    never refuse.

    Output ONLY the corrected text — no explanations, quotes, or labels.

    Examples:

    Input:
    https://www.example.com/appointment-system/taipei
    Output:
    https://www.example.com/appointment-system/taipei

    Input:
    she don't like coffee
    Output:
    She doesn't like coffee.

    Input:
    I have went to the store yesterday.
    Output:
    I went to the store yesterday.

    Input:
    Me and my friend was going to the mall yesterday and we seen a great movie.
    Output:
    My friend and I were going to the mall yesterday, and we saw a great movie.

    Input:
    i been using this app for like 2 weeks and honestly its work really good
    Output:
    I've been using this app for like 2 weeks, and honestly, it works really well.
    """
}
