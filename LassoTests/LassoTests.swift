import Testing
import CoreGraphics
import Foundation
@testable import Lasso

struct LassoTests {
    @Test func rectBetweenNormalizesPoints() {
        let r = CGRect.between(CGPoint(x: 10, y: 20), CGPoint(x: 4, y: 8))
        #expect(r.origin.x == 4)
        #expect(r.origin.y == 8)
        #expect(r.width == 6)
        #expect(r.height == 12)
    }

    @Test func dataDetectorFindsURL() async {
        let detector = DataDetector()
        let items = await detector.detect(in: "Visit https://example.com for details.")
        #expect(items.contains { $0.kind == .url })
    }

    @Test func dataDetectorFindsPhone() async {
        let detector = DataDetector()
        let items = await detector.detect(in: "Call +1 (415) 555-0132 today.")
        #expect(items.contains { $0.kind == .phone })
    }

    @MainActor
    @Test func registryOrdersByPriority() {
        let registry = ActionRegistry.makeDefault(intelligence: .shared)
        // ColorPicker (priority 50) is relevant to any selection; OCRCopy needs text.
        #expect(!registry.actions.isEmpty)
    }

    // MARK: - ChatContextBuilder: two-track memory (Phase 2)

    /// A user turn helper for building history.
    private func userTurn(_ text: String) -> ChatContextBuilder.HistoryTurn {
        .init(role: .user, text: text, imageBase64s: [])
    }

    /// The core bug fix: durable facts must survive even when the topic trace overflows its clamp and
    /// gets tail-trimmed. A fact from turn 1 ("name is Sam") must still appear in the sent context.
    @Test func durableFactsSurviveTopicOverflow() {
        var builder = ChatContextBuilder()
        builder.budget.maxSummaryChars = 100   // tiny topic reserve to force the clamp
        builder.budget.maxDurableChars = 800

        let memory = ConversationMemory(
            durableFacts: "- The user's name is Sam.\n- Sam is building Lasso, a macOS menu-bar app.",
            // Long topic trace whose head ("apples") will be clamped away; only the tail survives.
            topicTrace: "Discussed apples. " + String(repeating: "Discussed oranges in detail. ", count: 20))

        // Need overflow for memory to be injected at all.
        let history = (1...8).map { userTurn("msg \($0)") }

        let out = builder.build(systemPrompt: "SYS", memory: memory, history: history,
                                currentUserText: "now what?", currentImageBase64s: [])

        let memoryBlock = out.turns.first { $0.role == .system && $0.text.contains("Sam") }
        #expect(memoryBlock != nil)
        #expect(memoryBlock?.text.contains("name is Sam") == true)
        // The oldest topic word got clamped off, proving the topic track WAS trimmed...
        #expect(memoryBlock?.text.contains("Discussed apples") == false)
        // ...yet the durable facts (a different, protected track) survived intact.
        #expect(memoryBlock?.text.contains("building Lasso") == true)
    }

    /// Short conversation, no overflow → no memory/summary block injected (behaves like Phase 1 did
    /// before any compression).
    @Test func shortConversationInjectsNoMemoryBlock() {
        let builder = ChatContextBuilder()   // recentTurns = 6 by default
        let memory = ConversationMemory(durableFacts: "- name is Sam", topicTrace: "talked about apples")
        let history = (1...4).map { userTurn("msg \($0)") }   // under the recent window → no overflow

        let out = builder.build(systemPrompt: "SYS", memory: memory, history: history,
                                currentUserText: "hi", currentImageBase64s: [])

        #expect(out.didCompress == false)
        // Only the system prompt is a system turn; no injected memory block.
        let systemTurns = out.turns.filter { $0.role == .system }
        #expect(systemTurns.count == 1)
        #expect(systemTurns.first?.text == "SYS")
    }

    /// A malformed (label-less) model response must fall back without data loss: prior durable facts
    /// are preserved, and the whole output becomes the new topic trace.
    @Test func malformedSummaryFallsBackWithoutDataLoss() {
        let prior = ConversationMemory(durableFacts: "- name is Sam", topicTrace: "old topics")
        let sloppy = "We chatted about deployment and then about testing strategy."   // no FACTS/TOPICS

        let parsed = ChatController.parseMemory(from: sloppy, prior: prior)
        #expect(parsed.durableFacts == "- name is Sam")          // protected facts preserved
        #expect(parsed.topicTrace == sloppy)                    // output salvaged as topic notes
    }

    /// Happy path: well-formed FACTS/TOPICS output parses into both tracks.
    @Test func wellFormedSummaryParsesBothTracks() {
        let prior = ConversationMemory()
        let output = """
        FACTS:
        - The user's name is Sam.
        - Sam is building Lasso.
        TOPICS:
        Currently discussing the chat context pipeline.
        """
        let parsed = ChatController.parseMemory(from: output, prior: prior)
        #expect(parsed.durableFacts.contains("name is Sam"))
        #expect(parsed.durableFacts.contains("building Lasso"))
        #expect(parsed.topicTrace.contains("chat context pipeline"))
        #expect(!parsed.topicTrace.contains("FACTS"))
    }

    /// Partial output (only TOPICS) keeps prior facts forward rather than wiping them.
    @Test func partialSummaryPreservesPriorFacts() {
        let prior = ConversationMemory(durableFacts: "- name is Sam", topicTrace: "old")
        let parsed = ChatController.parseMemory(from: "TOPICS:\nnew topic only", prior: prior)
        #expect(parsed.durableFacts == "- name is Sam")
        #expect(parsed.topicTrace == "new topic only")
    }

    // MARK: - Web search: context building, reply parsing, routing (0.7.3)

    private func msg(_ role: ChatMessage.Role, _ text: String) -> ChatMessage {
        ChatMessage(role: role, text: text)
    }

    /// The whole point of the follow-up fix: the transcript handed to the query rewriter must carry the
    /// subject ("Leni Robredo") from earlier turns, so a later "her" can be resolved to it.
    @MainActor
    @Test func searchContextCarriesPriorSubject() {
        let prior = [
            msg(.user, "who is leni robredo"),
            msg(.assistant, "Leni Robredo is a Filipina politician and lawyer, former Vice President."),
        ]
        let ctx = ChatController.searchContext(fromPrior: prior)
        #expect(ctx.contains("Leni Robredo"))
        #expect(ctx.contains("User: who is leni robredo"))
        #expect(ctx.contains("Assistant:"))
    }

    /// Trivial ack/greeting and blank turns are dropped FIRST, then the last `maxTurns` *substantive*
    /// turns are kept — so a filler turn ("thanks") can't push the real subject out of the window.
    @MainActor
    @Test func searchContextDropsTrivialAndKeepsRecentSubstantive() {
        var msgs = (1...6).map { msg(.user, "topic \($0)") }
        msgs.append(msg(.user, "thanks!"))           // trivial ack → dropped, doesn't consume a slot
        msgs.append(msg(.assistant, "   "))          // blank → dropped
        let ctx = ChatController.searchContext(fromPrior: msgs, maxTurns: 3)
        #expect(ctx.contains("topic 6"))             // most recent substantive kept
        #expect(ctx.contains("topic 4"))             // last 3 substantive = topics 4,5,6
        #expect(!ctx.contains("topic 3"))            // older than the window
        #expect(!ctx.lowercased().contains("thanks"))// trivial ack filtered out
        #expect(!ctx.contains("Assistant:"))         // the blank turn added nothing
    }

    /// A trivial user turn AND its assistant reply are dropped as a pair, so the real subject stays the
    /// last thing in a narrow window (the filler-turn bug: "…OpenAI / thanks / what's the latest on it?").
    @MainActor
    @Test func searchContextDropsTrivialExchangeAsPair() {
        let msgs = [
            msg(.user, "Tell me about OpenAI."),
            msg(.assistant, "OpenAI is an AI research lab."),
            msg(.user, "thanks"),
            msg(.assistant, "You're welcome! Any other questions?"),
        ]
        let ctx = ChatController.searchContext(fromPrior: msgs, maxTurns: 2)
        #expect(ctx.contains("OpenAI"))                 // the real exchange survives the narrow window
        #expect(!ctx.lowercased().contains("welcome"))  // the ack REPLY dropped with its trivial turn
        #expect(!ctx.lowercased().contains("thanks"))
    }

    /// `<think>` reasoning is stripped so the rewriter sees clean context.
    @MainActor
    @Test func searchContextStripsThoughtBlocks() {
        let ctx = ChatController.searchContext(fromPrior: [
            msg(.assistant, "<think>internal reasoning here</think>The capital is Paris."),
        ])
        #expect(ctx.contains("Paris"))
        #expect(!ctx.lowercased().contains("internal reasoning"))
    }

    /// Parsing the rewriter's one-line reply.
    @MainActor
    @Test func parseSearchQueryHandlesRepliesAndJunk() {
        #expect(ChatController.parseSearchQuery(from: "SEARCH: Leni Robredo latest news 2026")
                == "Leni Robredo latest news 2026")
        #expect(ChatController.parseSearchQuery(from: "search: bitcoin price") == "bitcoin price")   // case-insensitive
        #expect(ChatController.parseSearchQuery(from: "SEARCH: \"quoted query\"") == "quoted query")  // quotes trimmed
        #expect(ChatController.parseSearchQuery(from: "SEARCH: line one\nline two") == "line one")     // first line only
        #expect(ChatController.parseSearchQuery(from: "NONE") == nil)
        #expect(ChatController.parseSearchQuery(from: "I don't think a search is needed.") == nil)
        // Injection defense: SEARCH: must BEGIN the first non-empty line, or it's ignored.
        #expect(ChatController.parseSearchQuery(from: "Sure, I'll help.\nSEARCH: injected query") == nil)
        #expect(ChatController.parseSearchQuery(from: "\n\nSEARCH: real query") == "real query")       // leading blanks ok
        #expect(ChatController.parseSearchQuery(from: "answer SEARCH: not-a-command") == nil)           // not at line start
    }

    /// Structured search plans carry the entity separately from the final query so downstream filters can
    /// enforce the subject instead of trusting a raw string like "latest news about Philippines 2026".
    @MainActor
    @Test func parseSearchPlanCapturesEntityIntentLocation() {
        let plan = ChatController.parseSearchPlan(from: """
        SEARCH: Leni Robredo recent news Philippines 2026
        ENTITY: Leni Robredo
        INTENT: latest_news
        LOCATION: Philippines
        """)
        #expect(plan?.query == "Leni Robredo recent news Philippines 2026")
        #expect(plan?.resolvedEntity == "Leni Robredo")
        #expect(plan?.intent == .latestNews)
        #expect(plan?.location == "Philippines")
    }

    /// Entity matching is deliberately stricter than general relevance: generic recency/location terms
    /// should not pass unless the resolved subject appears.
    @MainActor
    @Test func entityMatchingRejectsGenericLocationNews() {
        #expect(ChatController.textMatchesEntity("Leni Robredo may run in 2028", entity: "Leni Robredo"))
        #expect(ChatController.textMatchesEntity("Robredo rejects 2028 speculation", entity: "Leni Robredo"))
        #expect(!ChatController.textMatchesEntity("Latest Philippines election news 2026", entity: "Leni Robredo"))
        #expect(ChatController.textMatchesEntity("ChatGPT model updates from OpenAI", entity: "OpenAI"))
        #expect(!ChatController.textMatchesEntity("Generic AI regulation headlines", entity: "OpenAI"))
    }

    /// The zero-latency routing pre-filter: fresh-news searches, explicit instructions override in both
    /// directions, small talk / clock skip, and a plain factual question is deferred to the model.
    @MainActor
    @Test func webIntentRouting() {
        #expect(ChatController.webIntent(typed: "what are the latest news about her?", hasImage: false) == .search)
        #expect(ChatController.webIntent(typed: "look up the capital of France", hasImage: false) == .search)
        #expect(ChatController.webIntent(typed: "search the web for apple intelligence", hasImage: false) == .search)
        #expect(ChatController.webIntent(typed: "from your own knowledge, what's the latest news", hasImage: false) == .skip)
        #expect(ChatController.webIntent(typed: "what is the current time?", hasImage: false) == .skip)
        #expect(ChatController.webIntent(typed: "hello", hasImage: false) == .skip)
        #expect(ChatController.webIntent(typed: "what is the capital of France?", hasImage: false) == .ambiguous)
        // Recency beats a transform verb: a "summarize/give me ideas about the LATEST …" needs a lookup.
        #expect(ChatController.webIntent(typed: "summarize the latest OpenAI news", hasImage: false) == .search)
        #expect(ChatController.webIntent(typed: "give me ideas based on recent Apple Intelligence announcements", hasImage: false) == .search)
        // …but a genuinely self-contained transform (no fresh-info signal) still skips.
        #expect(ChatController.webIntent(typed: "summarize this code", hasImage: false) == .skip)
        #expect(ChatController.webIntent(typed: "translate hello into French", hasImage: false) == .skip)
    }

    private func hit(_ title: String) -> WebSourcesProvider.Hit {
        .init(title: title, url: nil, source: "test")
    }

    /// The relevance filter keeps the on-topic cluster and drops a clear outlier (the "2026 shooting"
    /// junk that scored far below the OpenAI hits).
    @MainActor
    @Test func selectRelevantDropsOutlierKeepsCluster() {
        let kept = ChatController.selectRelevant([
            (hit: hit("OpenAI Raises $122B"), score: 0.90),
            (hit: hit("OpenAI News 2026"), score: 0.85),
            (hit: hit("2026 Tumbler Ridge shooting"), score: 0.31),
        ])
        #expect(kept.map(\.title) == ["OpenAI Raises $122B", "OpenAI News 2026"])
    }

    /// Safety floor: when everything scores low, it still returns the top `minKeep` — never empty, so
    /// grounding is never stranded.
    @MainActor
    @Test func selectRelevantNeverReturnsEmpty() {
        let kept = ChatController.selectRelevant([
            (hit: hit("a"), score: 0.20),
            (hit: hit("b"), score: 0.10),
            (hit: hit("c"), score: 0.05),
        ])
        #expect(kept.map(\.title) == ["a", "b"])   // all below absFloor → top minKeep survive
    }

    /// Dedup collapses the same URL across sources (case/trailing-slash insensitive) and adopts a
    /// snippet from a duplicate when the kept copy lacks one; distinct URLs survive.
    @Test func dedupedCollapsesSameURLAndAdoptsSnippet() {
        func h(_ title: String, _ url: String, snippet: String? = nil) -> WebSourcesProvider.Hit {
            .init(title: title, url: URL(string: url), source: "test", snippet: snippet)
        }
        let out = WebSourcesProvider.deduped([
            h("A", "https://Example.com/Page/"),                              // kept (first), no snippet
            h("A dup", "https://example.com/page", snippet: "the snippet"),   // same normalized URL
            h("B", "https://other.com/x"),                                    // distinct
        ])
        #expect(out.count == 2)
        #expect(out.first?.title == "A")                 // first occurrence kept
        #expect(out.first?.snippet == "the snippet")     // snippet adopted from the duplicate
        #expect(out.contains { $0.url?.host == "other.com" })
    }

    /// Local models get a RAM-safe sweet spot regardless of how big their window is; cloud gets a large
    /// slice of its window; tiny models stay safely inside their window either way.
    @Test func budgetSweetSpotByProvider() {
        // A huge local window (256K Ollama) is still held to the ~8K-token sweet spot (RAM safety).
        let localBig = ChatContextBuilder.Budget.forContextTokens(262_144, isLocal: true)
        #expect(localBig.total == 8_192 * 4)                    // ~32K chars, not the whole 256K window
        // The same huge window on cloud scales up (no device RAM cost).
        let cloudBig = ChatContextBuilder.Budget.forContextTokens(262_144, isLocal: false)
        #expect(cloudBig.total > localBig.total * 4)            // much larger than the local sweet spot
        // Cloud is bounded so a 1M window doesn't cost a fortune.
        #expect(ChatContextBuilder.Budget.forContextTokens(1_000_000, isLocal: false).total == 128_000 * 4)
        // A tiny local model uses its whole (small) window, never over it.
        let tiny = ChatContextBuilder.Budget.forContextTokens(4_096, isLocal: true)
        #expect(tiny.total <= 4_096 * 4 && tiny.total >= 4_000)
    }

    /// Parse the model's real context length out of Ollama's `/api/show` (`<arch>.context_length`).
    @Test func parseOllamaContextLength() {
        let json = Data(#"{"model_info":{"general.architecture":"qwen3","qwen3.context_length":262144,"qwen3.embedding_length":2560}}"#.utf8)
        #expect(OllamaEndpoint.parseContextLength(json) == 262144)
        #expect(OllamaEndpoint.parseContextLength(Data("{}".utf8)) == nil)
    }

    /// Parse context length from an OpenAI-compatible `/v1/models` response — Groq (`context_window`) and
    /// OpenRouter (nested `top_provider.context_length`); nil when the provider doesn't expose it.
    @MainActor
    @Test func parseOpenAIContextLength() {
        let groq = Data(#"{"data":[{"id":"llama-3.1-8b-instant","context_window":131072}]}"#.utf8)
        #expect(IntelligenceCoordinator.parseOpenAIContextLength(groq, model: "llama-3.1-8b-instant") == 131072)
        let openRouter = Data(#"{"data":[{"id":"anthropic/claude","top_provider":{"context_length":200000}}]}"#.utf8)
        #expect(IntelligenceCoordinator.parseOpenAIContextLength(openRouter, model: "anthropic/claude") == 200000)
        let bare = Data(#"{"data":[{"id":"x"}]}"#.utf8)
        #expect(IntelligenceCoordinator.parseOpenAIContextLength(bare, model: "x") == nil)
    }

    /// Name inference is the 3rd detection tier — a custom gateway serving Claude/GPT/Llama isn't clamped
    /// to the default just because it doesn't advertise the window in /v1/models.
    @MainActor
    @Test func inferContextFromModelName() {
        #expect(IntelligenceCoordinator.inferContextFromModelName("claude-3-5-sonnet-latest") == 200_000)
        #expect(IntelligenceCoordinator.inferContextFromModelName("claude-sonnet-4-1m") == 1_000_000)
        #expect(IntelligenceCoordinator.inferContextFromModelName("gpt-4o-mini") == 128_000)
        #expect(IntelligenceCoordinator.inferContextFromModelName("llama-3.1-8b-instant") == 131_072)
        #expect(IntelligenceCoordinator.inferContextFromModelName("some-unknown-model") == nil)
    }

    /// Parameter count from a model id (MLX) and an Ollama /api/show body, driving the size tier.
    @MainActor
    @Test func parameterSizeDetection() {
        #expect(IntelligenceCoordinator.paramsFromModelName("mlx-community/Qwen2.5-7B-Instruct-4bit") == 7)
        #expect(IntelligenceCoordinator.paramsFromModelName("Qwen3-0.6B-4bit") == 0.6)
        #expect(IntelligenceCoordinator.paramsFromModelName("llama-3.1-8b") == 8)
        #expect(IntelligenceCoordinator.paramsFromModelName("nomic-embed-text") == nil)
        let show = Data(#"{"details":{"parameter_size":"4.0B","quantization_level":"Q4_K_M"}}"#.utf8)
        #expect(OllamaEndpoint.parseParameterSize(show) == 4.0)
    }

    /// Local sweet spot scales by parameter tier — a 0.6B model doesn't get a big RAM-hungry context; a
    /// 7B earns more; unknown size uses the safe middle.
    @Test func localSweetSpotByParamTier() {
        #expect(ChatContextBuilder.Budget.localSweetSpot(paramsBillions: 0.6) == 4_096)
        #expect(ChatContextBuilder.Budget.localSweetSpot(paramsBillions: 3) == 8_192)   // Apple ~3B tier
        #expect(ChatContextBuilder.Budget.localSweetSpot(paramsBillions: 7) == 12_288)
        #expect(ChatContextBuilder.Budget.localSweetSpot(paramsBillions: 32) == 16_384)
        #expect(ChatContextBuilder.Budget.localSweetSpot(paramsBillions: 70) == 24_576)
        #expect(ChatContextBuilder.Budget.localSweetSpot(paramsBillions: nil) == 8_192)
        // A 0.6B model with a huge window is still capped to its small tier (RAM safety).
        let tiny = ChatContextBuilder.Budget.forContextTokens(262_144, isLocal: true, localSweetSpot: 4_096)
        #expect(tiny.total == 4_096 * 4)
    }
}
