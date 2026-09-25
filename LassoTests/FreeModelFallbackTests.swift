import Testing
import Foundation
@testable import Lasso

/// Free-model fallback. The detection cases pin the claim the feature must never get wrong (free is not
/// "the call worked"); the quality cases pin that a fallback stays close to the chosen model; the driver
/// and refresher cases run the real loops against fake providers, because loops like these read
/// correctly long before they behave correctly.
struct FreeModelFallbackTests {

    // MARK: - A. Discovery rules

    /// Four entries trimmed from OpenRouter's live `/api/v1/models` (2026-09-14): a free vision model,
    /// a zero-priced *music* model, the auto-router (price "-1" = variable), and a priced model whose
    /// `pricing` carries an `overrides` list.
    static let openRouterFixture = #"""
    {"data":[
     {"id":"inclusionai/ling-3.0-flash-vl:free","pricing":{"prompt":"0","completion":"0"},"context_length":262144,
      "architecture":{"modality":"text+image+video->text","input_modalities":["text","image","video"],"output_modalities":["text"]},
      "supported_parameters":["max_tokens","temperature","tool_choice","tools"],"top_provider":{"context_length":262144}},
     {"id":"google/lyria-3-clip-preview","pricing":{"prompt":"0","completion":"0"},"context_length":1048576,
      "architecture":{"input_modalities":["text","image"],"output_modalities":["text","audio"]},
      "supported_parameters":["max_tokens","temperature"]},
     {"id":"openrouter/auto","pricing":{"prompt":"-1","completion":"-1"},"context_length":2000000,
      "architecture":{"input_modalities":["text","image"],"output_modalities":["text","image"]},
      "supported_parameters":["tools"]},
     {"id":"~openai/gpt-astra-latest","pricing":{"prompt":"0.00001","completion":"0.00005","web_search":"0.01",
      "overrides":[{"min_prompt_tokens":272000,"prompt":"0.00002"}]},"context_length":400000,
      "architecture":{"input_modalities":["text","image"],"output_modalities":["text"]},"supported_parameters":["tools"]}
    ]}
    """#

    private func openRouterModels() throws -> [RegistryModel] {
        try #require(KeysRegistry.parseOpenAIModelList(Data(Self.openRouterFixture.utf8)))
    }

    @Test func openRouterPricingIsReadNotGuessed() throws {
        let models = Dictionary(uniqueKeysWithValues: try openRouterModels().map { ($0.name, $0) })
        let free = try #require(models["inclusionai/ling-3.0-flash-vl:free"])
        #expect(free.freeOffer == .always)
        #expect(free.outputsOnlyText == true)
        #expect(free.acceptsImages == true)
        #expect(free.supportsTools == true)
        #expect(free.contextTokens == 262_144)
        #expect(models["google/lyria-3-clip-preview"]?.freeOffer == .always)
        #expect(models["google/lyria-3-clip-preview"]?.outputsOnlyText == false)
        #expect(models["openrouter/auto"]?.freeOffer == .never, "variable price (-1) is not free")
        #expect(models["~openai/gpt-astra-latest"]?.freeOffer == .never)
    }

    /// Groq's list has ids and a context window, nothing about price. The parser must not invent one;
    /// the Groq rule then marks its models as on the free plan, and non-chat models as non-chat.
    @Test func groqModelsAreOnTheFreePlanAndSpeechModelsAreNotChat() throws {
        let body = #"{"data":[{"id":"openai/gpt-oss-120b","context_window":131072},{"id":"whisper-large-v3"}]}"#
        let parsed = try #require(KeysRegistry.parseOpenAIModelList(Data(body.utf8)))
        #expect(parsed.allSatisfy { $0.freeOffer == nil })
        let annotated = FreeTierRules.annotate(parsed, for: groqEntry(models: [], freeTier: false))
        #expect(annotated.map(\.freeOffer) == [.freePlan, .freePlan])
        #expect(annotated.first { $0.name == "whisper-large-v3" }?.outputsOnlyText == false)
    }

    /// Google publishes a per-model free-tier table. Listed free → free plan, listed "Not available" →
    /// never, not listed → unknown. Same rule through the native API and the OpenAI-compatible shim.
    @Test func googleFollowsItsPublishedFreeTierTable() {
        let names = ["models/gemini-2.5-pro", "models/gemini-3.1-pro-preview", "models/gemini-9-ultra",
                     "models/gemini-2.5-flash-preview-tts", "gemini-3.8-flash"]
        for entry in [RegisteredKey(name: "Gemini", baseURL: "", keyNotRequired: false, kind: .gemini),
                      RegisteredKey(name: "AIStudio", baseURL: "https://generativelanguage.googleapis.com/v1beta/openai/",
                                    keyNotRequired: false)] {
            let offers = FreeTierRules.annotate(names.map { RegistryModel(name: $0) }, for: entry)
            #expect(offers.map(\.freeOffer) == [.freePlan, .never, nil, nil, .freePlan], "\(entry.name)")
            #expect(offers[3].outputsOnlyText == false, "a TTS model is never a chat fallback")
        }
    }

    /// Seen in OpenRouter's live list: a zero-priced safety classifier that accepts images, and a
    /// zero-priced router that picks a free model at random. Neither may stand in for the user's model.
    @Test func classifiersAndRoutersNeverBecomeFallbacks() {
        var classifier = RegistryModel(name: "nvidia/nemotron-3.5-content-safety:free")
        classifier.freeOffer = .always; classifier.acceptsImages = true
        var router = RegistryModel(name: "openrouter/free"); router.freeOffer = .always
        var real = RegistryModel(name: "google/gemma-4-31b-it:free"); real.freeOffer = .always
        let annotated = FreeTierRules.annotate([classifier, router, real], for: openRouterEntry([]))
        let registry = KeysRegistry(entries: [openRouterEntry(annotated)])
        #expect(FreeModelPool.freeModels(in: registry).map(\.ref.model) == ["google/gemma-4-31b-it:free"])
    }

    @Test func aProviderWithoutARuleStaysUnknown() {
        let custom = RegisteredKey(name: "Work AI", baseURL: "https://ai.example.com/v1", keyNotRequired: false,
                                   freeTier: true)
        let models = FreeTierRules.annotate([RegistryModel(name: "llama-3.3-70b")], for: custom)
        #expect(models.first?.freeOffer == nil)
        #expect(FreeModelDetector.status(of: models[0], on: custom) == .unknown,
                "the Free tier switch unlocks a provider's documented plan, it doesn't declare models free")
    }

    // MARK: - B. Free status

    @Test func freeStatusThreeStates() {
        var onPlan = RegistryModel(name: "openai/gpt-oss-120b"); onPlan.freeOffer = .freePlan
        var priced = RegistryModel(name: "gemini-3.1-pro-preview"); priced.freeOffer = .never
        var zero = RegistryModel(name: "x:free"); zero.freeOffer = .always
        let off = groqEntry(models: [], freeTier: false), on = groqEntry(models: [], freeTier: true)

        #expect(FreeModelDetector.status(of: onPlan, on: off) == .unknown, "a key not known to be on the free plan")
        #expect(FreeModelDetector.status(of: onPlan, on: on) == .confirmed(.freePlan))
        #expect(FreeModelDetector.status(of: priced, on: on) == .notFree, "the switch can't make a paid model free")
        #expect(FreeModelDetector.status(of: zero, on: off) == .confirmed(.providerPricing))
        let lmStudio = RegisteredKey(name: "LM Studio", baseURL: "http://localhost:1234/v1", keyNotRequired: true)
        #expect(FreeModelDetector.status(of: RegistryModel(name: "qwen"), on: lmStudio) == .confirmed(.localServer))
    }

    @Test func unknownAndPaidModelsNeverEnterThePool() throws {
        let registry = KeysRegistry(entries: [openRouterEntry(try openRouterModels()),
                                              groqEntry(models: groqModels(), freeTier: false)])
        #expect(FreeModelPool.freeModels(in: registry).map(\.ref.model) == ["inclusionai/ling-3.0-flash-vl:free"])
    }

    @MainActor @Test func aRateLimitedFreeModelIsStillFreeJustBenched() {
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let health = ModelHealth(now: { clock })
        let registry = KeysRegistry(entries: [groqEntry(models: groqModels(), freeTier: true)])
        let big = ModelRef(keyID: "groq", model: "openai/gpt-oss-120b")
        let needs = FallbackNeeds(prompt: "hi", context: nil, primaryModel: nil)

        health.record(.rateLimited, for: big)
        #expect(health.availability(of: big) == .rateLimited)
        #expect(FreeModelPool.freeModels(in: registry).map(\.ref).contains(big), "free status is untouched")
        #expect(!FreeModelPool.candidates(in: registry, needs: needs, excluding: [], isBenched: { health.isBenched($0) })
            .map(\.ref).contains(big))

        clock += ModelHealth.Cooldown.rateLimited + 1
        #expect(health.availability(of: big) == .healthy)
        #expect(FreeModelPool.candidates(in: registry, needs: needs, excluding: [], isBenched: { health.isBenched($0) })
            .first?.ref == big)
    }

    // MARK: - C/D. Quality, capabilities, ranking

    @Test func sizeBandsComeFromPublishedParameterCountsAndFamilyNames() {
        let cases: [(String, ModelSize?)] = [
            ("openai/gpt-oss-120b", .large), ("llama-3.3-70b-versatile", .large), ("qwen3-235b-a22b", .large),
            ("openai/gpt-oss-20b", .medium), ("qwen/qwen3.8-27b", .medium), ("qwen3-30b-a3b", .medium),
            ("llama-3.1-8b-instant", .small), ("gemma-3-4b-it", .small),
            ("models/gemini-2.5-pro", .large), ("gemini-2.5-flash", .medium), ("gemini-2.5-flash-lite", .small),
            ("claude-3-5-haiku-latest", .small), ("gpt-4o-mini", .small),
            ("groq/compound", nil), ("kimi-k2", .large), ("deepseek/deepseek-chat-v3-0324:free", .large),
            ("deepseek-r1-distill-qwen-14b", .small), ("z-ai/glm-4.5-air:free", nil), ("z-ai/glm-4.6", .large),
            ("qwen/qwen3-coder:free", .large), ("minimax/minimax-m1", .large), ("deepseek/deepseek-r1:free", .large),
        ]
        for (id, size) in cases { #expect(ModelSize.infer(fromModelID: id) == size, "\(id)") }
    }

    /// The spec's example: a strong primary, a strong compatible free model A, a weak compatible B, an
    /// incompatible C. A is chosen; B isn't a stand-in for a large model; C is never chosen.
    @Test func aStrongPrimaryFallsBackToTheStrongCompatibleModel() {
        var a = RegistryModel(name: "llama-3.3-70b-versatile"); a.contextTokens = 131_072
        var b = RegistryModel(name: "llama-3.1-8b-instant"); b.contextTokens = 131_072
        var c = RegistryModel(name: "qwen3-235b-a22b"); c.contextTokens = 4_096
        let registry = KeysRegistry(entries: [groqEntry(models: FreeTierRules.annotate([b, c, a], for: groqEntry()),
                                                        freeTier: true)])
        let needs = FallbackNeeds(prompt: String(repeating: "a", count: 16_000), context: nil,
                                  primaryModel: "openai/gpt-oss-120b")

        let order = FreeModelPool.candidates(in: registry, needs: needs, excluding: [], isBenched: { _ in false })
        #expect(order.map(\.ref.model) == ["llama-3.3-70b-versatile"])
        let byName = Dictionary(uniqueKeysWithValues: FreeModelPool.freeModels(in: registry).map { ($0.ref.model, $0) })
        #expect(FreeModelPool.exclusion(of: byName["llama-3.1-8b-instant"]!, needs: needs, tried: [],
                                        isBenched: { _ in false }) == .muchSmallerThanPrimary)
        #expect(FreeModelPool.exclusion(of: byName["qwen3-235b-a22b"]!, needs: needs, tried: [],
                                        isBenched: { _ in false }) == .contextTooSmall)
    }

    @Test func aMediumPrimaryMayUseASmallModelButOnlyAfterStrongerOnes() {
        let registry = KeysRegistry(entries: [groqEntry(models: groqModels(), freeTier: true)])
        let needs = FallbackNeeds(prompt: "hi", context: nil, primaryModel: "openai/gpt-oss-20b")
        #expect(FreeModelPool.candidates(in: registry, needs: needs, excluding: [], isBenched: { _ in false })
            .map(\.ref.model) == ["openai/gpt-oss-120b", "qwen/qwen3.8-27b", "llama-3.1-8b-instant"])
    }

    /// Diversity decides between comparable models; it never promotes a weaker one.
    @Test func providerDiversityBreaksTiesButNeverOverridesSize() {
        var orLarge = RegistryModel(name: "meta-llama/llama-3.3-70b-instruct:free"); orLarge.freeOffer = .always
        var orSmall = RegistryModel(name: "google/gemma-3-4b-it:free"); orSmall.freeOffer = .always
        let registry = KeysRegistry(entries: [openRouterEntry([orLarge, orSmall]),
                                              groqEntry(models: groqModels(), freeTier: true)])
        let needs = FallbackNeeds(prompt: "hi", context: nil, primaryModel: nil)
        // The primary was an OpenRouter model that just hit OpenRouter's limit.
        let tried: Set<ModelRef> = [ModelRef(keyID: "or", model: "some/primary")]
        let order = FreeModelPool.candidates(in: registry, needs: needs, excluding: tried, isBenched: { _ in false })
            .map(\.ref.model)
        #expect(order == ["openai/gpt-oss-120b", "meta-llama/llama-3.3-70b-instruct:free",
                          "qwen/qwen3.8-27b", "llama-3.1-8b-instant", "google/gemma-3-4b-it:free"])
    }

    /// Within a band, a published parameter count is stronger evidence than a family name. Live, this
    /// is "nemotron-3-super-120b" versus "nex-n2.5-pro".
    @Test func aPublishedSizeOutranksOneReadFromAName() {
        var named = RegistryModel(name: "nex-agi/nex-n2.5-pro:free"); named.freeOffer = .always
        var published = RegistryModel(name: "nvidia/nemotron-3-super-120b-a12b:free"); published.freeOffer = .always
        let registry = KeysRegistry(entries: [openRouterEntry([named, published])])
        let needs = FallbackNeeds(prompt: "hi", context: nil, primaryModel: nil)
        #expect(FreeModelPool.candidates(in: registry, needs: needs, excluding: [], isBenched: { _ in false })
            .map(\.ref.model) == ["nvidia/nemotron-3-super-120b-a12b:free", "nex-agi/nex-n2.5-pro:free"])
    }

    @Test func imageRequestsOnlyReachModelsThatReadImages() throws {
        let registry = KeysRegistry(entries: [groqEntry(models: groqModels(), freeTier: true),
                                              openRouterEntry(try openRouterModels())])
        let image = FallbackNeeds(messages: [ChatTurn(role: .user, text: "what is this", imageBase64s: ["x"])],
                                  tools: .none, primaryModel: nil)
        #expect(FreeModelPool.candidates(in: registry, needs: image, excluding: [], isBenched: { _ in false })
            .map(\.ref.model) == ["inclusionai/ling-3.0-flash-vl:free"])
    }

    @Test func contextMustFitTheConversationPlusTheReply() {
        var roomy = RegistryModel(name: "roomy-70b"); roomy.freeOffer = .always; roomy.contextTokens = 200_000
        var tight = RegistryModel(name: "tight-70b"); tight.freeOffer = .always; tight.contextTokens = 100_000
        let unreported = RegistryModel(name: "mystery-70b")   // no window, none inferable from the name
        var mystery = unreported; mystery.freeOffer = .always
        var gemini = RegistryModel(name: "models/gemini-2.5-flash"); gemini.freeOffer = .always
        let registry = KeysRegistry(entries: [openRouterEntry([roomy, tight, mystery, gemini])])

        // 100K tokens of conversation doesn't fit a 100K window once the reply needs room too.
        let big = FallbackNeeds(prompt: String(repeating: "a", count: 400_000), context: nil, primaryModel: nil)
        #expect(Set(FreeModelPool.candidates(in: registry, needs: big, excluding: [], isBenched: { _ in false })
            .map(\.ref.model)) == ["roomy-70b", "models/gemini-2.5-flash"],
                "an unreported window is assumed small; Gemini's is inferred from its name")

        let small = FallbackNeeds(prompt: "hi", context: nil, primaryModel: nil)
        #expect(FreeModelPool.candidates(in: registry, needs: small, excluding: [], isBenched: { _ in false }).count == 4)
    }

    @Test func requiredToolsExcludeModelsThatCantCallThemAndPreferredToolsRankThemFirst() {
        var withTools = RegistryModel(name: "a/tools-70b:free"); withTools.freeOffer = .always; withTools.supportsTools = true
        var noTools = RegistryModel(name: "b/plain-70b:free"); noTools.freeOffer = .always; noTools.supportsTools = false
        var unknown = RegistryModel(name: "c/quiet-70b:free"); unknown.freeOffer = .always
        let gemini = RegisteredKey(id: "gm", name: "Gemini", baseURL: "", keyNotRequired: false,
                                   models: FreeTierRules.annotate([RegistryModel(name: "models/gemini-2.5-pro")],
                                                                  for: RegisteredKey(name: "", baseURL: "", keyNotRequired: false, kind: .gemini)),
                                   kind: .gemini, freeTier: true, useForFallback: true)
        let registry = KeysRegistry(entries: [openRouterEntry([noTools, unknown, withTools]), gemini])

        let required = FallbackNeeds(messages: [ChatTurn(role: .user, text: "search the news")], tools: .required, primaryModel: nil)
        #expect(FreeModelPool.candidates(in: registry, needs: required, excluding: [], isBenched: { _ in false })
            .map(\.ref.model) == ["a/tools-70b:free", "c/quiet-70b:free"],
                "no known-toolless model, and no native Gemini (it has no tool loop)")

        let preferred = FallbackNeeds(messages: [ChatTurn(role: .user, text: "hi")], tools: .preferred, primaryModel: nil)
        #expect(FreeModelPool.candidates(in: registry, needs: preferred, excluding: [], isBenched: { _ in false })
            .map(\.ref.model).first == "a/tools-70b:free")
    }

    @Test func thePrivacyBoundary() {
        #expect(FallbackPolicy.poolAllowed(enabled: true, localOnly: false, primaryIsLocal: false))
        #expect(!FallbackPolicy.poolAllowed(enabled: false, localOnly: false, primaryIsLocal: false))
        #expect(!FallbackPolicy.poolAllowed(enabled: true, localOnly: true, primaryIsLocal: false))
        #expect(!FallbackPolicy.poolAllowed(enabled: true, localOnly: false, primaryIsLocal: true))
    }

    @Test func settingsCanSayWhyAConnectionContributesNothing() throws {
        let custom = RegisteredKey(id: "c", name: "Work AI", baseURL: "https://ai.example.com/v1", keyNotRequired: false,
                                   models: [RegistryModel(name: "llama")])
        let lmStudio = RegisteredKey(name: "LM Studio", baseURL: "http://localhost:1234/v1", keyNotRequired: true,
                                     models: [RegistryModel(name: "qwen")])
        let registry = KeysRegistry(entries: [openRouterEntry(try openRouterModels()),
                                              groqEntry(models: groqModels(), freeTier: false), custom, lmStudio])
        let idle = FreeModelPool.nonContributing(in: registry)
        #expect(idle.needsFreeTier.map(\.name) == ["Groq"])
        #expect(idle.unsupported.map(\.name) == ["Work AI"])
        #expect(idle.notOptedIn.map(\.name) == ["LM Studio"], "a server on this Mac is free, but still needs consent")
    }

    // MARK: - F. Failures and health

    @Test func failuresClassifyFromTheWayProvidersReportThem() {
        #expect(ModelFailure.classify(IntelligenceError.server("Groq HTTP 429 at https://x. Rate limited — try again shortly.")) == .rateLimited)
        #expect(ModelFailure.classify(IntelligenceError.server("Google Gemini HTTP 404. That model isn't available to this key.")) == .modelGone)
        #expect(ModelFailure.classify(IntelligenceError.server("OpenRouter HTTP 401 at https://x. Check the API key.")) == .unauthorized)
        #expect(ModelFailure.classify(IntelligenceError.server("Groq HTTP 413 at https://x.")) == .rejected)
        #expect(ModelFailure.classify(IntelligenceError.server("Anthropic returned HTTP 529. Check the API key and model.")) == .unavailable)
        #expect(ModelFailure.classify(URLError(.cannotConnectToHost)) == .connectionDown)
        #expect(ModelFailure.classify(URLError(.timedOut)) == .unavailable)
        #expect(ModelFailure.classify(CancellationError()) == .cancelled)
        #expect(!ModelFailure.unauthorized.triggersFallback && !ModelFailure.rejected.triggersFallback)
    }

    @MainActor @Test func rateLimitsBenchAModelThenItsConnection() {
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let health = ModelHealth(now: { clock })
        let a = ModelRef(keyID: "or", model: "a:free"), b = ModelRef(keyID: "or", model: "b:free")
        let c = ModelRef(keyID: "or", model: "c:free")

        health.record(.rateLimited, for: a)
        #expect(health.isBenched(a))
        #expect(!health.isBenched(c), "one 429 is that model's limit, not the account's")

        health.record(.rateLimited, for: b)
        #expect(health.availability(of: c) == .rateLimited, "two models capped on one connection: the shared cap")

        clock += ModelHealth.Cooldown.connectionRateLimited + 1
        #expect(!health.isBenched(a) && !health.isBenched(c), "cooldowns end on their own")

        // Any other 400 may be about this one request: bench it, but on a timer.
        health.record(.rejected, for: b)
        #expect(health.availability(of: b) == .unavailable)
        clock += ModelHealth.Cooldown.unavailable + 1
        #expect(!health.isBenched(b))

        health.record(.modelGone, for: a)
        health.record(.unauthorized, for: ModelRef(keyID: "groq", model: "x"))
        clock += 86_400
        #expect(health.availability(of: a) == .missing, "a withdrawn model doesn't come back on a timer")
        #expect(health.availability(of: ModelRef(keyID: "groq", model: "y")) == .credentialsRejected)
        health.clearRefreshMarks()
        #expect(!health.isBenched(a))
        #expect(!health.isBenched(ModelRef(keyID: "groq", model: "y")))
    }

    // MARK: - E. The failover loop, run

    @MainActor @Test func aRateLimitedPrimaryIsAnsweredByTheNextHealthyFreeModel() async throws {
        let primary = FakeProvider(name: "Groq · llama", outcome: .fail("Groq HTTP 429 at x."))
        let first = candidate("or", "a:free"), second = candidate("gm", "b")
        let providers = ["a:free": FakeProvider(name: "OpenRouter · a:free", outcome: .fail("OpenRouter HTTP 503 at x.")),
                         "b": FakeProvider(name: "Gemini · b", outcome: .answer(["Hello", " there"]))]
        let health = ModelHealth()
        var attempted: [String] = []
        var served: [String] = []
        var notices: [FallbackNotice] = []
        let driver = makeDriver(health: health, pool: [first, second], providers: providers)

        let text = try await collect(driver.stream(primary: primary, primaryRef: ModelRef(keyID: "groq", model: "llama"),
                                                   needs: textNeeds, label: "test",
                                                   onAttempt: { provider, _ in attempted.append(provider.name) },
                                                   onServe: { served.append($0.name) },
                                                   onFallback: { notices.append($0) },
                                                   open: { $0.respond(prompt: "q", context: nil) }))

        #expect(text == "Hello there", "the stream is only the model's answer; the notice travels beside it")
        #expect(notices == [FallbackNotice(answeredBy: "Gemini · b", insteadOf: "Groq · llama", onDevice: false,
                                           reason: .rateLimited)],
                "one notice, for the model that answered, not for the candidate that also failed")
        #expect(notices.first?.text == "Answered by Gemini · b because Groq · llama was temporarily unavailable")
        #expect(attempted == ["Groq · llama", "OpenRouter · a:free", "Gemini · b"])
        #expect(served == ["Gemini · b"], "attribution never names a candidate that failed")
        #expect(health.availability(of: ModelRef(keyID: "groq", model: "llama")) == .rateLimited)
        #expect(health.availability(of: first.ref) == .unavailable)
    }

    /// The request reaches the fallback exactly as it reached the primary.
    @MainActor @Test func theFallbackReceivesTheOriginalRequestUnchanged() async throws {
        let recorder = PromptRecorder()
        let primary = FakeProvider(name: "P", outcome: .fail("HTTP 503"), recorder: recorder)
        let driver = makeDriver(pool: [candidate("or", "a")],
                                providers: ["a": FakeProvider(name: "A", outcome: .answer(["ok"]), recorder: recorder)])
        let messages = [ChatTurn(role: .system, text: "sys"), ChatTurn(role: .user, text: "Explain monads, briefly.")]
        _ = try await collect(driver.stream(primary: primary, primaryRef: nil, needs: textNeeds, label: "test",
                                            onServe: { _ in }, open: { $0.respond(messages: messages) }))
        #expect(await recorder.prompts == ["Explain monads, briefly.", "Explain monads, briefly."])
    }

    @MainActor @Test func aLocalPrimaryNeverReachesThePool() async throws {
        let primary = FakeProvider(name: "Ollama · qwen", isLocal: true, outcome: .fail("Ollama HTTP 503"))
        var builtPool = false
        let driver = makeDriver(pool: [candidate("or", "a:free")], providers: [:],
                                poolAllowed: { FallbackPolicy.poolAllowed(enabled: true, localOnly: false, primaryIsLocal: $0.isLocal) },
                                onMake: { builtPool = true },
                                lastResort: FakeProvider(name: "Apple", isLocal: true, outcome: .answer(["ok"])))

        var notices: [FallbackNotice] = []
        let text = try await collect(driver.stream(primary: primary, primaryRef: nil, needs: textNeeds, label: "test",
                                                   onServe: { _ in }, onFallback: { notices.append($0) },
                                                   open: { $0.respond(prompt: "q", context: nil) }))
        #expect(!builtPool)
        #expect(text == "ok")
        #expect(notices.map(\.onDevice) == [true])
    }

    @MainActor @Test func aBadKeyOrOversizedPromptIsReportedNotPaperedOver() async {
        for message in ["Groq HTTP 401 at x. Check the API key.", "Groq HTTP 413 at x."] {
            let primary = FakeProvider(name: "Groq · llama", outcome: .fail(message))
            var builtPool = false
            let driver = makeDriver(pool: [candidate("or", "a:free")], providers: [:], onMake: { builtPool = true },
                                    lastResort: FakeProvider(name: "Apple", isLocal: true, outcome: .answer(["no"])))
            await #expect(throws: IntelligenceError.self) {
                _ = try await collect(driver.stream(primary: primary, primaryRef: nil, needs: textNeeds, label: "test",
                                                    onServe: { _ in }, open: { $0.respond(prompt: "q", context: nil) }))
            }
            #expect(!builtPool, "\(message)")
        }
    }

    @MainActor @Test func aFailureAfterTheFirstTokenNeverSplicesAnotherModel() async {
        let primary = FakeProvider(name: "Groq · llama", outcome: .answerThenFail("Hel", "Groq HTTP 503 at x."))
        var builtPool = false
        let driver = makeDriver(pool: [candidate("or", "a:free")], providers: [:], onMake: { builtPool = true })
        await #expect(throws: IntelligenceError.self) {
            _ = try await collect(driver.stream(primary: primary, primaryRef: nil, needs: textNeeds, label: "test",
                                                onServe: { _ in }, open: { $0.respond(prompt: "q", context: nil) }))
        }
        #expect(!builtPool)
    }

    @MainActor @Test func attemptsAreCappedThenOnDeviceThenTheUsersOwnError() async {
        let primary = FakeProvider(name: "Groq · llama", outcome: .fail("Groq HTTP 429 at x."))
        let providers = ["a": FakeProvider(name: "A", outcome: .fail("A HTTP 503")),
                         "b": FakeProvider(name: "B", outcome: .fail("B HTTP 503")),
                         "c": FakeProvider(name: "C", outcome: .fail("C HTTP 503")),
                         "d": FakeProvider(name: "D", outcome: .answer(["never reached"]))]
        var made = 0
        var backgroundRefreshes = 0
        let driver = makeDriver(pool: ["a", "b", "c", "d"].map { candidate($0, $0) }, providers: providers,
                                onMake: { made += 1 })
        driver.refreshInBackground = { backgroundRefreshes += 1 }
        do {
            _ = try await collect(driver.stream(primary: primary, primaryRef: nil, needs: textNeeds, label: "test",
                                                onServe: { _ in }, open: { $0.respond(prompt: "q", context: nil) }))
            Issue.record("expected the primary's error")
        } catch {
            #expect(error.localizedDescription.hasPrefix("Groq HTTP 429"))
        }
        #expect(made == FallbackDriver.maxPoolAttempts)
        #expect(backgroundRefreshes == 1, "several candidates failed: re-check the providers for next time")
    }

    /// An empty pool used to block the request on a round of `/models` calls. Now the refresh is for
    /// next time: this request goes on-device at once, and asks for candidates only once.
    @MainActor @Test func anEmptyPoolSchedulesABackgroundRefreshAndDoesNotWait() async throws {
        let primary = FakeProvider(name: "Groq · llama", outcome: .fail("Groq HTTP 429 at x."))
        var refreshes = 0
        var asked = 0
        let driver = makeDriver(pool: [], providers: [:],
                                lastResort: FakeProvider(name: "Apple", isLocal: true, outcome: .answer(["on-device"])))
        driver.candidates = { _, _ in asked += 1; return [] }
        driver.refreshInBackground = { refreshes += 1 }

        let text = try await collect(driver.stream(primary: primary, primaryRef: nil, needs: textNeeds, label: "test",
                                                   onServe: { _ in }, open: { $0.respond(prompt: "q", context: nil) }))
        #expect(text == "on-device")
        #expect(refreshes == 1)
        #expect(asked == 1, "the pool isn't re-read after the refresh: this request didn't wait for it")
    }

    // MARK: - F. Refresh

    /// Three requests noticing a stale pool at once must share one round of `/models` calls. Without the
    /// stored in-flight task, each passes the check before any suspends and each refreshes.
    @MainActor @Test func concurrentRefreshesShareOneRoundOfDiscovery() async {
        let store = ScratchDefaults()
        KeysRegistry(entries: [groqEntry(models: groqModels(), freeTier: true)]).save(to: store.defaults)

        let calls = CallCounter()
        let refresher = FreeModelRefresher(store: store.defaults, discover: { _, _ in
            await calls.increment()
            try? await Task.sleep(for: .milliseconds(50))
            return [RegistryModel(name: "llama-4-scout")]
        }, keyValue: { _ in "" })

        async let one: Bool = refresher.refreshIfDue()
        async let two: Bool = refresher.refreshIfDue()
        async let three: Bool = refresher.refreshIfDue()
        _ = await (one, two, three)

        #expect(await calls.count == 1)
        let saved = KeysRegistry.load(from: store.defaults).entries.first
        #expect(saved?.models.map(\.name) == ["llama-4-scout"])
        #expect(saved?.modelsCheckedAt != nil)
    }

    @MainActor @Test func automaticRefreshesAreRateLimitedAndStalenessIsADay() async {
        let store = ScratchDefaults()
        var clock = Date(timeIntervalSince1970: 1_000_000)
        KeysRegistry(entries: [groqEntry(models: groqModels(), freeTier: true)]).save(to: store.defaults)
        let calls = CallCounter()
        let refresher = FreeModelRefresher(store: store.defaults, discover: { _, _ in
            await calls.increment(); return [RegistryModel(name: "m")]
        }, keyValue: { _ in "" }, now: { clock })

        #expect(refresher.isStale, "never checked")
        #expect(await refresher.refreshIfDue())
        #expect(!refresher.isStale)
        clock += 60
        #expect(await refresher.refreshIfDue() == false, "a failing provider mustn't be re-scanned on every request")
        clock += FreeModelRefresher.minimumInterval
        #expect(await refresher.refreshIfDue())
        #expect(await calls.count == 2)
        clock += FreeModelRefresher.staleAfter + 1
        #expect(refresher.isStale)
    }

    /// A refresh reconciles: new free models join, models that stopped being free leave, models the
    /// rule no longer covers become unknown, and what the user owns (Free tier) is untouched.
    @MainActor @Test func aRefreshRebuildsThePoolFromWhatProvidersServeNow() async {
        let store = ScratchDefaults()
        var wasFree = RegistryModel(name: "old/model:free"); wasFree.freeOffer = .always
        var stillFree = RegistryModel(name: "kept/model-70b:free"); stillFree.freeOffer = .always
        KeysRegistry(entries: [openRouterEntry([wasFree, stillFree])]).save(to: store.defaults)

        let refresher = FreeModelRefresher(store: store.defaults, discover: { _, _ in
            var nowPriced = RegistryModel(name: "old/model:free"); nowPriced.freeOffer = .never
            var kept = RegistryModel(name: "kept/model-70b:free"); kept.freeOffer = .always
            var added = RegistryModel(name: "new/model-120b:free"); added.freeOffer = .always
            return [nowPriced, kept, added, RegistryModel(name: "unlisted/model")]
        }, keyValue: { _ in "" })
        await refresher.refresh()

        let registry = KeysRegistry.load(from: store.defaults)
        #expect(Set(FreeModelPool.freeModels(in: registry).map(\.ref.model)) == ["kept/model-70b:free", "new/model-120b:free"])
    }

    /// Settings can save while a background refresh waits on the network. The refresh must not bring
    /// back a connection the user just removed, overwrite a Free tier switch they just flipped, or wipe
    /// a good list with a failed fetch.
    @MainActor @Test func aRefreshKeepsChangesTheUserMadeWhileItRan() async {
        let store = ScratchDefaults()
        let suite = store.suite
        let kept = RegisteredKey(id: "kept", name: "Gemini", baseURL: "", keyNotRequired: false,
                                 models: [RegistryModel(name: "models/gemini-3-flash")], kind: .gemini)
        KeysRegistry(entries: [groqEntry(models: groqModels(), freeTier: false), kept,
                               openRouterEntry([])]).save(to: store.defaults)

        let refresher = FreeModelRefresher(store: store.defaults, discover: { entry, _ in
            await MainActor.run {
                let defaults = UserDefaults(suiteName: suite)!
                var registry = KeysRegistry.load(from: defaults)
                registry.entries.removeAll { $0.id == "groq" }
                if let i = registry.entries.firstIndex(where: { $0.id == "or" }) { registry.entries[i].freeTier = true }
                registry.save(to: defaults)
            }
            return entry.id == "kept" ? nil : [RegistryModel(name: "resurrected")]
        }, keyValue: { _ in "" })
        await refresher.refresh()

        let entries = KeysRegistry.load(from: store.defaults).entries
        #expect(entries.map(\.id) == ["kept", "or"])
        #expect(entries.first?.models.map(\.name) == ["models/gemini-3-flash"])
        #expect(entries.last?.freeTier == true)
    }

    // MARK: - Review fixes: timing

    /// The 30 s budget used to start with the request, so a primary that timed out at 59 s (URLSession's
    /// usual 60) left no time for any candidate. It now starts at the primary's failure.
    @MainActor @Test func thePoolBudgetStartsWhenThePrimaryFails() async throws {
        let clock = TestClock()
        let primary = FakeProvider(name: "P", outcome: .fail("P HTTP 503"))
        let driver = makeDriver(pool: [candidate("or", "a")],
                                providers: ["a": FakeProvider(name: "A", outcome: .answer(["from A"]))])
        driver.now = { clock.time }
        let text = try await collect(driver.stream(
            primary: primary, primaryRef: nil, needs: textNeeds, label: "test",
            onAttempt: { provider, _ in if provider.name == "P" { clock.time += 59 } },   // the primary takes 59 s to fail
            onServe: { _ in }, open: { $0.respond(prompt: "q", context: nil) }))
        #expect(text == "from A")
    }

    @MainActor @Test func thePoolBudgetStillEndsThirtySecondsAfterThePrimaryFails() async throws {
        let clock = TestClock()
        var made: [String] = []
        let driver = makeDriver(pool: [candidate("or", "a"), candidate("gm", "b")],
                                providers: ["a": FakeProvider(name: "A", outcome: .fail("A HTTP 503")),
                                            "b": FakeProvider(name: "B", outcome: .answer(["from B"]))],
                                lastResort: FakeProvider(name: "Apple", isLocal: true, outcome: .answer(["on-device"])))
        let make = driver.makeProvider
        driver.makeProvider = { made.append($0.ref.model); return make($0) }
        driver.now = { clock.time }
        let text = try await collect(driver.stream(
            primary: FakeProvider(name: "P", outcome: .fail("P HTTP 503")), primaryRef: nil, needs: textNeeds,
            label: "test", onAttempt: { provider, _ in if provider.name == "A" { clock.time += FallbackDriver.poolDeadline + 1 } },
            onServe: { _ in }, open: { $0.respond(prompt: "q", context: nil) }))
        #expect(made == ["a"])
        #expect(text == "on-device")
    }

    @MainActor @Test func aCandidateProviderHasTheShorterTimeoutAndHonoursToolSupport() throws {
        var toolless = candidate("or", "plain-70b:free")
        toolless.model.supportsTools = false
        let plain = try #require(IntelligenceCoordinator.provider(for: toolless, keyValue: { _ in "k" })
                                    as? OpenAICompatibleProvider)
        #expect(plain.requestTimeout == FallbackDriver.candidateTimeout)
        #expect(FallbackDriver.candidateTimeout == 20)
        #expect(!plain.supportsTools, "a model that can't call tools answers without them")

        let unknown = try #require(IntelligenceCoordinator.provider(for: candidate("or", "quiet-70b:free"),
                                                                    keyValue: { _ in "k" }) as? OpenAICompatibleProvider)
        #expect(unknown.supportsTools, "unreported tool support keeps the tool loop")

        let gemini = try #require(IntelligenceCoordinator.provider(for: candidate("gm", "models/gemini-2.5-flash", kind: .gemini),
                                                                   keyValue: { _ in "k" }) as? GeminiProvider)
        #expect(gemini.requestTimeout == FallbackDriver.candidateTimeout)
        #expect(OpenAICompatibleProvider(baseURL: URL(string: "https://x")!, apiKey: "", model: "m",
                                         displayName: "X").requestTimeout == 60, "the selected model keeps 60 s")
    }

    // MARK: - Review fixes: consent, privacy, cost

    @Test func aConnectionNotOptedInSendsNothingEvenOnThisMac() {
        var free = RegistryModel(name: "a/model-70b:free"); free.freeOffer = .always
        let lmStudio = RegisteredKey(id: "lm", name: "LM Studio", baseURL: "http://localhost:1234/v1",
                                     keyNotRequired: true, models: [RegistryModel(name: "qwen-32b")])
        var lmOptedIn = lmStudio; lmOptedIn.useForFallback = true
        let registry = KeysRegistry(entries: [openRouterEntry([free], useForFallback: false), lmStudio])
        #expect(FreeModelPool.freeModels(in: registry).isEmpty)
        #expect(FreeModelPool.candidates(in: registry, needs: textNeeds, excluding: [], isBenched: { _ in false }).isEmpty)
        #expect(FreeModelPool.confirmedFree(in: registry).count == 2, "they are still free, just not the user's pick")
        #expect(FreeModelPool.freeModels(in: KeysRegistry(entries: [lmOptedIn])).map(\.source) == [.localServer])
    }

    /// A Free tier Groq key whose selected model is paid-only is a billed key: its "free plan" models
    /// would be billed too, so they leave the pool. OpenRouter's zero-priced models are unaffected.
    @Test func aBilledFreeTierKeyContributesNoFreePlanModels() {
        let google = RegisteredKey(id: "gm", name: "Gemini", baseURL: "", keyNotRequired: false,
                                   models: FreeTierRules.annotate([RegistryModel(name: "models/gemini-3.1-pro-preview"),
                                                                   RegistryModel(name: "models/gemini-2.5-flash")],
                                                                  for: RegisteredKey(name: "", baseURL: "", keyNotRequired: false, kind: .gemini)),
                                   kind: .gemini, freeTier: true, useForFallback: true)
        var zero = RegistryModel(name: "b/zero-70b:free"); zero.freeOffer = .always
        let registry = KeysRegistry(entries: [google, openRouterEntry([zero])])
        let paidPrimary = ModelRef(keyID: "gm", model: "models/gemini-3.1-pro-preview")
        let billed = FreeModelPool.billedConnections(in: registry, primary: paidPrimary)
        #expect(billed == ["gm"])
        #expect(FreeModelPool.billedConnections(in: registry, primary: ModelRef(keyID: "gm", model: "models/gemini-2.5-flash")).isEmpty)
        #expect(FreeModelPool.billedConnections(in: registry, primary: nil).isEmpty)
        let list = FreeModelPool.candidates(in: registry, needs: textNeeds, excluding: [], billed: billed,
                                            isBenched: { _ in false })
        #expect(list.map(\.ref.model) == ["b/zero-70b:free"])
        let flash = FreeModelPool.freeModels(in: registry).first { $0.ref.model == "models/gemini-2.5-flash" }!
        #expect(FreeModelPool.exclusion(of: flash, needs: textNeeds, tried: [], billed: billed,
                                        isBenched: { _ in false }) == .billedKey)
    }

    @Test func badgesSayWhyAModelIsFreeWhetherOrNotItIsAFallback() {
        var zero = RegistryModel(name: "a/zero:free"); zero.freeOffer = .always
        var priced = RegistryModel(name: "a/priced"); priced.freeOffer = .never
        let registry = KeysRegistry(entries: [
            openRouterEntry([zero, priced], useForFallback: false),
            groqEntry(models: groqModels(), freeTier: true, useForFallback: false),
            RegisteredKey(id: "lm", name: "LM Studio", baseURL: "http://127.0.0.1:1234/v1", keyNotRequired: true,
                          models: [RegistryModel(name: "qwen")]),
        ])
        #expect(FreeModelPool.badge(for: ModelRef(keyID: "or", model: "a/zero:free"), in: registry) == "free")
        #expect(FreeModelPool.badge(for: ModelRef(keyID: "or", model: "a/priced"), in: registry) == nil)
        #expect(FreeModelPool.badge(for: ModelRef(keyID: "groq", model: "openai/gpt-oss-120b"), in: registry) == "free tier")
        #expect(FreeModelPool.badge(for: ModelRef(keyID: "groq", model: "whisper-large-v3"), in: registry) == nil)
        #expect(FreeModelPool.badge(for: ModelRef(keyID: "lm", model: "qwen"), in: registry) == "free")
        // The bulk form the pickers use agrees with the single one.
        let all = FreeModelPool.badges(in: registry)
        for entry in registry.entries {
            for model in entry.models {
                let ref = ModelRef(keyID: entry.id, model: model.name)
                #expect(all[ref] == FreeModelPool.badge(for: ref, in: registry), "\(ref.model)")
            }
        }
    }

    @MainActor @Test func privateNetworkAddresses() {
        let local = ["http://localhost:1234/v1", "http://127.0.0.1:8080", "http://127.5.0.1", "http://0.0.0.0:8000",
                     "http://10.0.0.5/v1", "http://172.16.0.1", "http://172.31.255.255", "http://192.168.1.20:11434/v1",
                     "http://169.254.10.10", "http://100.64.0.1", "http://100.127.255.254", "http://studio.local:1234/v1",
                     "http://[::1]:8080/v1", "http://[fd12:3456::1]/v1", "http://[fc00::1]", "http://[fe80::1%25en0]:80/",
                     "http://[::ffff:192.168.1.5]/v1", "http://mac-studio:1234/v1", "http://ollama:11434",
                     "http://box.tail1234.ts.net:8080/v1", "http://nas.home.arpa/v1", "http://llm.lan:8000",
                     "http://gpu.corp.internal/v1"]
        let remote = ["https://api.groq.com/openai/v1", "https://openrouter.ai/api/v1", "http://172.32.0.1",
                      "http://172.15.0.1", "http://100.128.0.1", "http://100.63.0.1", "http://192.169.0.1",
                      "http://8.8.8.8", "http://[2001:db8::1]", "http://[fec0::1]", "http://local.example.com",
                      "https://api.groq.com", "https://openrouter.ai", "http://134744072", "http://lan.example.com",
                      "http://internal.example.com", "https://ts.net.example.com", "not a url", ""]
        for url in local { #expect(KeysRegistry.isPrivateNetworkURL(url), "\(url)") }
        for url in remote { #expect(!KeysRegistry.isPrivateNetworkURL(url), "\(url)") }
    }

    /// A LAN server is not "on this Mac" for the privacy badge, but the fallback treats it as local:
    /// a conversation the user kept in-house doesn't get retried in the cloud. Tested on the pure helper
    /// the coordinator calls, because the coordinator itself reads `UserDefaults.standard`.
    @MainActor @Test func aPrimaryOnTheUsersOwnNetworkNeverReachesThePool() {
        let lan = "http://192.168.1.20:1234/v1"
        #expect(!OpenAICompatibleProvider(baseURL: URL(string: lan)!, apiKey: "", model: "m", displayName: "LAN").isLocal)
        #expect(FallbackPolicy.primaryIsLocal(providerIsLocal: false, preferred: .openAICompatible, baseURL: lan))
        #expect(!FallbackPolicy.primaryIsLocal(providerIsLocal: false, preferred: .openAICompatible,
                                               baseURL: "https://api.groq.com/openai/v1"))
        #expect(!FallbackPolicy.primaryIsLocal(providerIsLocal: false, preferred: .anthropic, baseURL: lan),
                "the stored URL only describes the OpenAI-compatible selection")
        #expect(FallbackPolicy.primaryIsLocal(providerIsLocal: true, preferred: .ollama, baseURL: ""))
        #expect(OpenAICompatibleProvider(baseURL: URL(string: "http://0.0.0.0:8000/v1")!, apiKey: "", model: "m",
                                         displayName: "Local").isLocal, "the same loopback rule as the registry")
    }

    /// Local-only switched on while a candidate runs: the next cloud attempt must not start.
    @MainActor @Test func turningOnLocalOnlyMidChainStopsFurtherCloudAttempts() async throws {
        var allowed = true
        var made = 0
        let driver = makeDriver(pool: [candidate("or", "a"), candidate("gm", "b")],
                                providers: ["a": FakeProvider(name: "A", outcome: .fail("A HTTP 503")),
                                            "b": FakeProvider(name: "B", outcome: .answer(["cloud"]))],
                                poolAllowed: { _ in allowed },
                                onMake: { made += 1; allowed = false },
                                lastResort: FakeProvider(name: "Apple", isLocal: true, outcome: .answer(["local"])))
        let text = try await collect(driver.stream(primary: FakeProvider(name: "P", outcome: .fail("P HTTP 429")),
                                                   primaryRef: nil, needs: textNeeds, label: "test", onServe: { _ in },
                                                   open: { $0.respond(prompt: "q", context: nil) }))
        #expect(made == 1)
        #expect(text == "local")
    }

    // MARK: - Review fixes: classification and notices

    /// The old substring test read "api key" as a bad key, and these real messages all contain it.
    @MainActor @Test func transientErrorsAreRecognisedInTheFormatsProvidersActuallySend() {
        let transient = ["OpenRouter HTTP 503 at https://x. Check the API key, base URL, and model.",
                         "Anthropic returned HTTP 429. Check the API key and model.",
                         "Anthropic returned HTTP 529. Check the API key and model.",
                         "Ollama returned HTTP 500. Is `ollama serve` running and is qwen pulled?",
                         "Request timeout"]
        for message in transient {
            #expect(IntelligenceCoordinator.isTransient(IntelligenceError.server(message)), "\(message)")
        }
        #expect(IntelligenceCoordinator.isTransient(URLError(.timedOut)))
        #expect(!IntelligenceCoordinator.isTransient(IntelligenceError.server("OpenRouter HTTP 401 at https://x. Check the API key.")))
        #expect(!IntelligenceCoordinator.isTransient(IntelligenceError.server("Groq HTTP 413 at https://x. Check the API key, base URL, and model.")))
        #expect(!IntelligenceCoordinator.isTransient(CancellationError()))
        #expect(!IntelligenceCoordinator.isTransient(URLError(.cancelled)))
    }

    /// Groq's free plan answers an over-budget request with 413 and a tokens-per-minute message.
    @Test func aTokensPerMinute413IsARateLimit() {
        let tpm = "Groq HTTP 413 at https://api.groq.com/openai/v1/chat/completions. Check the API key, base URL, and "
            + "model. Request too large for model `openai/gpt-oss-120b` in organization `org_1` service tier "
            + "`on_demand` on tokens per minute (TPM): Limit 8000, Requested 12000."
        #expect(ModelFailure.classify(IntelligenceError.server(tpm)) == .rateLimited)
        #expect(ModelFailure.classify(IntelligenceError.server("X HTTP 413 at x. Payload tokens per minute exceeded")) == .rateLimited)
        #expect(ModelFailure.classify(IntelligenceError.server("Groq HTTP 413 at x. Request entity too large.")) == .rejected)
        #expect(ModelFailure.classify(IntelligenceError.emptyResponse("A")) == .unavailable)
    }

    @MainActor @Test func aMissingModelIsReportedAsMissingNotAsAnOutage() async throws {
        var notices: [FallbackNotice] = []
        let driver = makeDriver(pool: [candidate("or", "a")],
                                providers: ["a": FakeProvider(name: "A", outcome: .answer(["ok"]))])
        _ = try await collect(driver.stream(primary: FakeProvider(name: "Groq · llama", outcome: .fail("Groq HTTP 404 at x.")),
                                            primaryRef: nil, needs: textNeeds, label: "test", onServe: { _ in },
                                            onFallback: { notices.append($0) },
                                            open: { $0.respond(prompt: "q", context: nil) }))
        #expect(notices.map(\.reason) == [.modelGone])
        #expect(notices.first?.reasonText == "Groq · llama wasn't found (check the model name and base URL)")
        #expect(notices.first?.text == "Answered by A because Groq · llama wasn't found (check the model name and base URL)")
    }

    // MARK: - Review fixes: ranking

    @Test func theSameModelOnAnotherConnectionIsTriedFirst() {
        var bigger = RegistryModel(name: "qwen/qwen3-235b-a22b:free"); bigger.freeOffer = .always
        var same = RegistryModel(name: "openai/gpt-oss-120b:free"); same.freeOffer = .always
        let registry = KeysRegistry(entries: [openRouterEntry([bigger, same])])
        let needs = FallbackNeeds(prompt: "hi", context: nil, primaryModel: "openai/gpt-oss-120b")
        #expect(FreeModelPool.candidates(in: registry, needs: needs, excluding: [], isBenched: { _ in false })
            .map(\.ref.model) == ["openai/gpt-oss-120b:free", "qwen/qwen3-235b-a22b:free"])
        #expect(FreeModelPool.normalizedModelID("models/Gemini-2.5-Flash") == "gemini-2.5-flash")
        #expect(FreeModelPool.normalizedModelID("meta-llama/llama-3.3-70b-instruct:free") == "llama-3.3-70b-instruct")
        #expect(FreeModelPool.normalizedModelID("openai/gpt-oss-120b") == FreeModelPool.normalizedModelID("gpt-oss-120b:free"))
    }

    @Test func moreParametersRankFirstWithinABand() {
        var seventy = RegistryModel(name: "meta-llama/llama-3.3-70b-instruct:free"); seventy.freeOffer = .always
        var big = RegistryModel(name: "nvidia/nemotron-3-super-120b-a12b:free"); big.freeOffer = .always
        let registry = KeysRegistry(entries: [openRouterEntry([seventy, big])])
        #expect(FreeModelPool.candidates(in: registry, needs: textNeeds, excluding: [], isBenched: { _ in false })
            .map(\.ref.model) == ["nvidia/nemotron-3-super-120b-a12b:free", "meta-llama/llama-3.3-70b-instruct:free"])
        #expect(ModelSize.estimate(fromModelID: "qwen3-30b-a3b")?.billions == 30)
    }

    // MARK: - Review fixes: tools

    @MainActor @Test func aTurnThatNeedsItsToolNeverFallsBackToTheToollessOnDeviceModel() async {
        var askedLastResort = false
        let driver = makeDriver(pool: [], providers: [:])
        driver.lastResort = { _, _ in askedLastResort = true
            return FakeProvider(name: "Apple", isLocal: true, outcome: .answer(["stale"])) }
        let needs = FallbackNeeds(messages: [ChatTurn(role: .user, text: "search the news")], tools: .required, primaryModel: nil)
        do {
            _ = try await collect(driver.stream(primary: FakeProvider(name: "P", outcome: .fail("P HTTP 429 at x.")),
                                                primaryRef: nil, needs: needs, label: "test", onServe: { _ in },
                                                open: { $0.respond(prompt: "q", context: nil) }))
            Issue.record("expected the selected model's error")
        } catch {
            #expect(error.localizedDescription.hasPrefix("P HTTP 429"))
        }
        #expect(!askedLastResort)
    }

    @MainActor @Test func aRetriedToolCallRunsItsSearchOnce() async {
        let memo = ChatController.ToolCallMemo()
        var runs = 0
        let search = ToolCall(id: "1", name: "web_search", argumentsJSON: #"{"query":"f1 winner"}"#)
        let retry = ToolCall(id: "call_9", name: "web_search", argumentsJSON: #"{"query":"f1 winner"}"#)
        let other = ToolCall(id: "2", name: "web_search", argumentsJSON: #"{"query":"weather"}"#)
        let first = await memo.result(for: search) { runs += 1; return "evidence" }
        let second = await memo.result(for: retry) { runs += 1; return "again" }
        #expect(first == "evidence" && second == "evidence")
        #expect(runs == 1)
        _ = await memo.result(for: other) { runs += 1; return "sunny" }
        #expect(runs == 2, "a different query is a different search")
    }

    /// Another model writes the same arguments with different spacing or key order.
    @MainActor @Test func theToolMemoComparesArgumentsAsJSONNotText() async {
        let memo = ChatController.ToolCallMemo()
        var runs = 0
        let spellings = [#"{"query": "x"}"#, #"{"query":"x"}"#, #"{ "query" : "x" }"#]
        for (i, json) in spellings.enumerated() {
            _ = await memo.result(for: ToolCall(id: "\(i)", name: "web_search", argumentsJSON: json)) { runs += 1; return "e" }
        }
        #expect(runs == 1)
        let orders = [#"{"query":"x","region":"ph"}"#, #"{"region": "ph", "query": "x"}"#]
        for (i, json) in orders.enumerated() {
            _ = await memo.result(for: ToolCall(id: "o\(i)", name: "web_search", argumentsJSON: json)) { runs += 1; return "e" }
        }
        #expect(runs == 2, "two keys in either order are one call")
        #expect(ChatController.ToolCallMemo.canonicalArguments("not json") == "not json")
    }

    // MARK: - Review fixes: the loop's edges

    @MainActor @Test func anEmptyCandidateStreamMovesToTheNextCandidate() async throws {
        let health = ModelHealth()
        var made = 0
        let driver = makeDriver(health: health, pool: [candidate("or", "a"), candidate("gm", "b")],
                                providers: ["a": FakeProvider(name: "A", outcome: .answer([])),
                                            "b": FakeProvider(name: "B", outcome: .answer(["from B"]))],
                                onMake: { made += 1 })
        let text = try await collect(driver.stream(primary: FakeProvider(name: "P", outcome: .fail("P HTTP 503")),
                                                   primaryRef: nil, needs: textNeeds, label: "test", onServe: { _ in },
                                                   open: { $0.respond(prompt: "q", context: nil) }))
        #expect(text == "from B")
        #expect(made == 2)
        #expect(health.availability(of: ModelRef(keyID: "or", model: "a")) == .unavailable)
    }

    @MainActor @Test func anEmptyPrimaryStreamIsStillTheAnswer() async throws {
        var made = 0
        var served: [String] = []
        let driver = makeDriver(pool: [candidate("or", "a")], providers: [:], onMake: { made += 1 })
        let text = try await collect(driver.stream(primary: FakeProvider(name: "P", outcome: .answer([])),
                                                   primaryRef: nil, needs: textNeeds, label: "test",
                                                   onServe: { served.append($0.name) },
                                                   open: { $0.respond(prompt: "q", context: nil) }))
        #expect(text.isEmpty && made == 0)
        #expect(served == ["P"])
    }

    /// The user stops the reply while a candidate is still waiting. Nothing new starts, and the
    /// abandoned candidate isn't benched: an empty stream from a cancelled request says nothing about it.
    @MainActor @Test func cancellingMidChainStartsNothingNewAndRecordsNothing() async throws {
        let health = ModelHealth()
        var made = 0
        var askedLastResort = false
        let driver = makeDriver(health: health, pool: [candidate("or", "a"), candidate("gm", "b")],
                                providers: ["a": FakeProvider(name: "A", outcome: .hang),
                                            "b": FakeProvider(name: "B", outcome: .answer(["from B"]))],
                                onMake: { made += 1 })
        driver.lastResort = { _, _ in askedLastResort = true; return nil }
        let stream = driver.stream(primary: FakeProvider(name: "P", outcome: .fail("P HTTP 503")), primaryRef: nil,
                                   needs: textNeeds, label: "test", onServe: { _ in },
                                   open: { $0.respond(prompt: "q", context: nil) })
        let consumer = Task { @MainActor in
            var text = ""
            do { for try await delta in stream { text += delta } } catch {}
            return text
        }
        for _ in 0..<400 where made == 0 { try await Task.sleep(for: .milliseconds(5)) }
        try await Task.sleep(for: .milliseconds(50))   // A is now waiting on its first token
        consumer.cancel()
        #expect(await consumer.value.isEmpty)
        try await Task.sleep(for: .milliseconds(200))  // let the driver's own task wind down
        #expect(made == 1)
        #expect(!askedLastResort)
        #expect(!health.isBenched(ModelRef(keyID: "or", model: "a")))
    }

    /// A paid primary's own 429 plus one free model's 429 on the same connection isn't the shared free
    /// cap: the connection's other free models stay available.
    @MainActor @Test func thePrimarysRateLimitDoesNotCountTowardTheConnectionsSharedCap() async throws {
        let health = ModelHealth()
        let driver = makeDriver(health: health, pool: [candidate("or", "a:free"), candidate("gm", "b")],
                                providers: ["a:free": FakeProvider(name: "A", outcome: .fail("OpenRouter HTTP 429 at x.")),
                                            "b": FakeProvider(name: "B", outcome: .answer(["ok"]))])
        _ = try await collect(driver.stream(primary: FakeProvider(name: "OpenRouter · paid", outcome: .fail("OpenRouter HTTP 429 at x.")),
                                            primaryRef: ModelRef(keyID: "or", model: "paid"), needs: textNeeds,
                                            label: "test", onServe: { _ in },
                                            open: { $0.respond(prompt: "q", context: nil) }))
        #expect(health.availability(of: ModelRef(keyID: "or", model: "paid")) == .rateLimited)
        #expect(health.availability(of: ModelRef(keyID: "or", model: "c:free")) == .healthy)
    }

    /// Only the selected model's attempt is marked selected; the answering model is served at its first
    /// token, after every attempt; the notice follows it.
    @MainActor @Test func attributionIsSetOnlyAtTheAnsweringModelsFirstToken() async throws {
        var events: [String] = []
        let driver = makeDriver(pool: [candidate("or", "a"), candidate("gm", "b")],
                                providers: ["a": FakeProvider(name: "A", outcome: .fail("A HTTP 503")),
                                            "b": FakeProvider(name: "B", outcome: .answer(["x", "y"]))])
        let stream = driver.stream(primary: FakeProvider(name: "P", outcome: .fail("P HTTP 429")), primaryRef: nil,
                                   needs: textNeeds, label: "test",
                                   onAttempt: { events.append("attempt \($0.name)\($1 ? " (selected)" : "")") },
                                   onServe: { events.append("serve \($0.name)") },
                                   onFallback: { events.append("notice \($0.answeredBy)") },
                                   open: { $0.respond(prompt: "q", context: nil) })
        for try await delta in stream { events.append("token \(delta)") }
        #expect(events == ["attempt P (selected)", "attempt A", "attempt B", "serve B", "notice B", "token x", "token y"])
    }

    /// The footer's history under the coordinator's rule (attribute the selected model when it is tried,
    /// then whoever answers at their first token): it names the selected model while the chain runs,
    /// never the candidate or the on-device model that failed, and ends on the one that answered.
    @MainActor @Test func theFooterNamesTheSelectedModelThenOnlyTheModelThatAnswered() async throws {
        var attributed: [String] = []
        var atCandidateAttempt: [String?] = []
        let driver = makeDriver(pool: [candidate("or", "a")],
                                providers: ["a": FakeProvider(name: "A", outcome: .fail("A HTTP 503"))],
                                lastResort: FakeProvider(name: "Apple", isLocal: true, outcome: .answer(["ok"])))
        _ = try await collect(driver.stream(
            primary: FakeProvider(name: "P", outcome: .fail("P HTTP 429")), primaryRef: nil, needs: textNeeds,
            label: "test",
            onAttempt: { provider, isSelected in
                if isSelected { attributed.append(provider.name) } else { atCandidateAttempt.append(attributed.last) }
            },
            onServe: { attributed.append($0.name) },
            open: { $0.respond(prompt: "q", context: nil) }))
        #expect(atCandidateAttempt == ["P", "P"], "while A and on-device are tried, the footer names the selected model")
        #expect(attributed == ["P", "Apple"], "A failed and is never named")
    }

    @MainActor @Test func theScopeLimitsHowFarARequestFallsBack() async {
        for scope in [FallbackScope.none, .onDeviceOnly] {
            var made = 0
            var askedLastResort = false
            let driver = makeDriver(pool: [candidate("or", "a")],
                                    providers: ["a": FakeProvider(name: "A", outcome: .answer(["cloud"]))],
                                    onMake: { made += 1 })
            driver.lastResort = { _, _ in askedLastResort = true
                return FakeProvider(name: "Apple", isLocal: true, outcome: .answer(["local"])) }
            let result = try? await collect(driver.stream(
                primary: FakeProvider(name: "P", outcome: .fail("P HTTP 503")), primaryRef: nil, needs: textNeeds,
                label: "test", scope: scope, onServe: { _ in }, open: { $0.respond(prompt: "q", context: nil) }))
            #expect(made == 0, "\(scope): never the pool")
            if scope == .none {
                #expect(result == nil && !askedLastResort, "no retry at all: the summarizer's error surfaces")
            } else {
                #expect(result == "local")
            }
        }
    }

    // MARK: - Review fixes: rules at read time, refresh, hosts

    /// A list saved before a rule existed (or changed) is judged by today's rule, without a refresh.
    @Test func providerRulesApplyToListsSavedBeforeThem() {
        let stale = [RegistryModel(name: "openai/gpt-oss-120b"), RegistryModel(name: "groq/compound"),
                     RegistryModel(name: "compound-beta")]
        let groq = groqEntry(models: stale, freeTier: true)   // saved with no freeOffer at all
        #expect(FreeModelPool.freeModels(in: KeysRegistry(entries: [groq])).map(\.ref.model) == ["openai/gpt-oss-120b"],
                "Groq's rule applies at read time; Compound is an agentic system, not a model")

        var dropped = RegistryModel(name: "models/gemini-1.0-pro"); dropped.freeOffer = .freePlan
        let google = RegisteredKey(id: "gm", name: "Gemini", baseURL: "", keyNotRequired: false, models: [dropped],
                                   kind: .gemini, freeTier: true, useForFallback: true)
        #expect(FreeModelPool.freeModels(in: KeysRegistry(entries: [google])).isEmpty,
                "a model the shipped table no longer lists stops being free now")

        let once = FreeTierRules.annotate(stale, for: groq)
        #expect(FreeTierRules.annotate(once, for: groq) == once, "annotating twice changes nothing")
        var priced = RegistryModel(name: "x/priced"); priced.freeOffer = .never
        #expect(FreeTierRules.annotate([priced], for: openRouterEntry([])).first?.freeOffer == .never,
                "OpenRouter's offer comes from its pricing and is never overwritten")
    }

    @Test func providerHostsMatchTheDomainNotJustItsLastLetters() {
        #expect(FreeTierProvider.identify(kind: .openAICompatible, baseURL: "https://api.groq.com/openai/v1") == .groq)
        #expect(FreeTierProvider.identify(kind: .openAICompatible, baseURL: "https://groq.com/v1") == .groq)
        #expect(FreeTierProvider.identify(kind: .openAICompatible, baseURL: "https://notgroq.com/v1") == nil)
        #expect(FreeTierProvider.identify(kind: .openAICompatible, baseURL: "https://openrouter.ai/api/v1") == .openRouter)
        #expect(FreeTierProvider.identify(kind: .openAICompatible, baseURL: "https://fakeopenrouter.ai/api/v1") == nil)
    }

    /// The user re-keys a connection while a refresh waits on the network: the list fetched with the old
    /// key isn't written over the connection that now uses a new one.
    @MainActor @Test func aRefreshDoesNotWriteBackAListFetchedWithAnOldKey() async {
        let store = ScratchDefaults()
        KeysRegistry(entries: [groqEntry(models: groqModels(), freeTier: true)]).save(to: store.defaults)
        let keys = KeyBox(value: "old")
        let refresher = FreeModelRefresher(store: store.defaults, discover: { _, _ in
            await MainActor.run { keys.value = "new" }
            return [RegistryModel(name: "seen-with-old-key")]
        }, keyValue: { _ in keys.value })
        await refresher.refresh()
        let saved = KeysRegistry.load(from: store.defaults).entries.first
        #expect(saved?.models.map(\.name) == groqModels().map(\.name))
    }

    @MainActor @Test func aCloseTagInsideCodeIsTextNotReasoning() {
        let inline = "Models end their reasoning with `</think>` before the answer."
        #expect(ChatController.splitReasoning(inline) == ("", inline, false))
        let fenced = "Example:\n```\nthinking...\n</think>\nanswer\n```"
        #expect(ChatController.splitReasoning(fenced).answer == fenced)
        #expect(ChatController.splitReasoning("Plan it.\n</think>\n42").answer == "42", "real markup still splits")
    }

    @MainActor @Test func theFallbackCaptionNamesWhatToTurnOnInOneShortSentence() {
        var zero = RegistryModel(name: "a/zero-70b:free"); zero.freeOffer = .always
        let registry = KeysRegistry(entries: [
            openRouterEntry([zero], useForFallback: false),
            groqEntry(models: groqModels(), freeTier: false, useForFallback: false),
            RegisteredKey(id: "c", name: "Work AI", baseURL: "https://ai.example.com/v1", keyNotRequired: false,
                          models: [RegistryModel(name: "llama")]),
        ])
        let caption = SettingsView.autoFallbackStatus(registry: registry, primary: nil, now: Date())
        #expect(caption == "No free models found. Turn on Use as fallback for OpenRouter and Groq, and Free tier "
                + "for Groq in Manage connections. Lasso can't detect free models on Work AI yet.")
        #expect(!caption.contains("—") && !caption.hasSuffix(".."))

        let google = RegisteredKey(id: "gm", name: "Gemini", baseURL: "", keyNotRequired: false,
                                   models: [RegistryModel(name: "models/gemini-3.1-pro-preview"),
                                            RegistryModel(name: "models/gemini-2.5-flash")],
                                   kind: .gemini, freeTier: true, useForFallback: true)
        let billed = SettingsView.autoFallbackStatus(registry: KeysRegistry(entries: [google]),
                                                     primary: ModelRef(keyID: "gm", model: "models/gemini-3.1-pro-preview"),
                                                     now: Date())
        #expect(billed.hasSuffix("Gemini is marked Free tier but your selected model there is paid-only, so the key is billed."))
    }

    // MARK: - Round 2

    /// Verbatim from the live run (`howOpenRouterReportsAModelThatDoesNotExist`).
    @Test func openRoutersInvalidModelIDIsAMissingModel() {
        let live = "OpenRouter HTTP 400 at https://openrouter.ai/api/v1/chat/completions. Check the API key, base URL, "
            + "and model. lasso-live-test/does-not-exist:free is not a valid model ID"
        #expect(ModelFailure.classify(IntelligenceError.server(live)) == .modelGone)
        #expect(ModelFailure.classify(IntelligenceError.server("OpenRouter HTTP 400 at x. Check the API key, base URL, and model.")) == .rejected)
        #expect(ModelFailure.classify(IntelligenceError.server("X HTTP 400 at x. messages: Field required")) == .rejected)
    }

    /// A Free tier Gemini key billed by its paid-only selected model: its plan models aren't free, so
    /// the pickers don't say so, and the caption doesn't count them. Zero-priced models elsewhere keep theirs.
    @Test func aBilledKeysPlanModelsGetNoBadgeAndAreNotCounted() {
        let google = RegisteredKey(id: "gm", name: "Gemini", baseURL: "", keyNotRequired: false,
                                   models: [RegistryModel(name: "models/gemini-3.1-pro-preview"),
                                            RegistryModel(name: "models/gemini-2.5-flash")],
                                   kind: .gemini, freeTier: true, useForFallback: true)
        var zero = RegistryModel(name: "b/zero-70b:free"); zero.freeOffer = .always
        let registry = KeysRegistry(entries: [google, openRouterEntry([zero])])
        let paid = ModelRef(keyID: "gm", model: "models/gemini-3.1-pro-preview")
        let flash = ModelRef(keyID: "gm", model: "models/gemini-2.5-flash")
        let openRouter = ModelRef(keyID: "or", model: "b/zero-70b:free")

        #expect(FreeModelPool.badge(for: flash, in: registry) == "free tier")
        #expect(FreeModelPool.badge(for: flash, in: registry, primary: paid) == nil)
        #expect(FreeModelPool.badge(for: openRouter, in: registry, primary: paid) == "free")
        let badges = FreeModelPool.badges(in: registry, primary: paid)
        #expect(badges[flash] == nil && badges[openRouter] == "free")
        #expect(FreeModelPool.badges(in: registry, primary: flash)[flash] == "free tier", "a free selected model bills nothing")

        #expect(FreeModelPool.summary(of: registry).models == 2)
        let billed = FreeModelPool.summary(of: registry, primary: paid)
        #expect(billed.models == 1 && billed.connections == 1)
        #expect(SettingsView.autoFallbackStatus(registry: registry, primary: paid, now: Date())
            .hasPrefix("1 free model across 1 connection"))
    }

    /// A connection repointed from Groq to a provider without a rule keeps its old list until the next
    /// refresh. The Groq rule's `freePlan` must not keep those models "free"; a provider's own pricing stays.
    @Test func aRepointedConnectionDropsFreePlanLabelsOnlyARuleCouldSet() {
        var planned = RegistryModel(name: "openai/gpt-oss-120b"); planned.freeOffer = .freePlan
        var zero = RegistryModel(name: "z/zero:free"); zero.freeOffer = .always
        var priced = RegistryModel(name: "p/priced"); priced.freeOffer = .never
        let custom = RegisteredKey(id: "c", name: "Work AI", baseURL: "https://ai.example.com/v1", keyNotRequired: false,
                                   models: [planned, zero, priced], freeTier: true, useForFallback: true)
        #expect(FreeTierRules.annotate(custom.models, for: custom).map(\.freeOffer) == [nil, .always, .never])
        #expect(FreeModelPool.freeModels(in: KeysRegistry(entries: [custom])).map(\.ref.model) == ["z/zero:free"])
        var repointedToOpenRouter = custom; repointedToOpenRouter.baseURL = "https://openrouter.ai/api/v1"
        #expect(FreeTierRules.annotate([planned], for: repointedToOpenRouter).first?.freeOffer == nil)

        #expect(!ConnectionsSheet.freeTierToSave(kind: .openAICompatible, baseURL: "https://ai.example.com/v1", switchOn: true))
        #expect(!ConnectionsSheet.freeTierToSave(kind: .openAICompatible, baseURL: "https://openrouter.ai/api/v1", switchOn: true))
        #expect(ConnectionsSheet.freeTierToSave(kind: .openAICompatible, baseURL: "https://api.groq.com/openai/v1", switchOn: true))
        #expect(ConnectionsSheet.freeTierToSave(kind: .gemini, baseURL: "", switchOn: true))
        #expect(!ConnectionsSheet.freeTierToSave(kind: .gemini, baseURL: "", switchOn: false))
    }

    // MARK: - Helpers

    private var textNeeds: FallbackNeeds { FallbackNeeds(prompt: "q", context: nil, primaryModel: nil) }

    private func groqEntry(models: [RegistryModel] = [], freeTier: Bool = false,
                           useForFallback: Bool = true) -> RegisteredKey {
        RegisteredKey(id: "groq", name: "Groq", baseURL: "https://api.groq.com/openai/v1", keyNotRequired: false,
                      models: models, freeTier: freeTier, useForFallback: useForFallback)
    }

    /// Groq's chat models as its list reports them, with the Groq rule applied.
    private func groqModels() -> [RegistryModel] {
        let raw: [(String, Int)] = [("llama-3.1-8b-instant", 131_072), ("openai/gpt-oss-120b", 131_072),
                                    ("qwen/qwen3.8-27b", 131_072), ("whisper-large-v3", 0)]
        return FreeTierRules.annotate(raw.map { name, window in
            var model = RegistryModel(name: name)
            if window > 0 { model.contextTokens = window }
            return model
        }, for: groqEntry())
    }

    private func openRouterEntry(_ models: [RegistryModel], useForFallback: Bool = true) -> RegisteredKey {
        RegisteredKey(id: "or", name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1", keyNotRequired: false,
                      models: models, useForFallback: useForFallback)
    }

    private func candidate(_ keyID: String, _ model: String, kind: ConnectionKind = .openAICompatible)
        -> FallbackCandidate {
        FallbackCandidate(ref: ModelRef(keyID: keyID, model: model), connectionName: keyID, kind: kind,
                          baseURL: "https://example.com/v1", keychainAccount: "", source: .providerPricing,
                          model: RegistryModel(name: model))
    }

    @MainActor
    private func makeDriver(health: ModelHealth = ModelHealth(), pool: [FallbackCandidate],
                            providers: [String: FakeProvider],
                            poolAllowed: @escaping (IntelligenceProvider) -> Bool = { _ in true },
                            onMake: @escaping () -> Void = {},
                            lastResort: FakeProvider? = nil) -> FallbackDriver {
        FallbackDriver(
            health: health,
            poolAllowed: poolAllowed,
            candidates: { _, tried in pool.filter { !tried.contains($0.ref) && !health.isBenched($0.ref) } },
            refreshInBackground: {},
            makeProvider: { candidate in
                onMake()
                return providers[candidate.ref.model] ?? FakeProvider(name: "missing", outcome: .fail("HTTP 500"))
            },
            lastResort: { _, _ in lastResort })
    }

    @MainActor
    private func collect(_ stream: AsyncThrowingStream<String, Error>) async throws -> String {
        var text = ""
        for try await delta in stream { text += delta }
        return text
    }
}

@MainActor
private final class TestClock {
    var time = Date(timeIntervalSince1970: 1_000_000)
}

@MainActor
private final class KeyBox {
    var value: String
    init(value: String) { self.value = value }
}

/// A throwaway `UserDefaults` domain, removed when the value is released.
final class ScratchDefaults {
    let suite = "FreeModelFallbackTests.\(UUID().uuidString)"
    lazy var defaults = UserDefaults(suiteName: suite)!
    deinit { UserDefaults().removePersistentDomain(forName: suite) }
}

private actor CallCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

private actor PromptRecorder {
    private(set) var prompts: [String] = []
    func record(_ prompt: String) { prompts.append(prompt) }
}

private struct FakeProvider: IntelligenceProvider {
    enum Outcome: Sendable {
        case answer([String])
        case fail(String)
        case answerThenFail(String, String)
        /// Says nothing for a long time, like a request stuck waiting on a slow provider.
        case hang
    }

    let name: String
    var isLocal = false
    let outcome: Outcome
    let recorder: PromptRecorder?
    let isAppleOnDevice = false

    init(name: String, isLocal: Bool = false, outcome: Outcome, recorder: PromptRecorder? = nil) {
        self.name = name
        self.isLocal = isLocal
        self.outcome = outcome
        self.recorder = recorder
    }

    func checkAvailability() async -> Bool { true }

    func respond(prompt: String, context: String?) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await recorder?.record(prompt)
                switch outcome {
                case .answer(let deltas):
                    deltas.forEach { continuation.yield($0) }
                    continuation.finish()
                case .fail(let message):
                    continuation.finish(throwing: IntelligenceError.server(message))
                case .answerThenFail(let delta, let message):
                    continuation.yield(delta)
                    continuation.finish(throwing: IntelligenceError.server(message))
                case .hang:
                    try? await Task.sleep(for: .seconds(10))
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// What reaches the chat bubble. A fallback often lands on a different model family than the one the
/// user picked, and those families format their output differently; these cases come from real streams.
@MainActor
struct ModelOutputHygieneTests {

    @Test func everyReasoningBlockIsSeparatedNotJustTheFirst() {
        // A reasoning model in a tool loop thinks again after the tool result; both rounds share a stream.
        let split = ChatController.splitReasoning("<think>search first</think><think>got it</think>Lando Norris won.")
        #expect(split.answer == "Lando Norris won.")
        #expect(split.reasoning == "search first\n\ngot it")
        #expect(!split.thinking)
    }

    @Test func aCloseTagWithoutAnOpenTagStillMarksReasoning() {
        // Templates that open the block inside the prompt stream only the close tag.
        let split = ChatController.splitReasoning("Okay, the user wants a number.\n</think>\n391")
        #expect(split.answer == "391")
        #expect(split.reasoning == "Okay, the user wants a number.")
    }

    @Test func anOpenBlockStreamsAsThinking() {
        let split = ChatController.splitReasoning("<think>still working")
        #expect(split.thinking && split.answer.isEmpty && split.reasoning == "still working")
        #expect(ChatController.splitReasoning("Plain answer.") == ("", "Plain answer.", false))
    }

    /// Verbatim shape from OpenRouter's nemotron-3-super-120b:free, delivered in awkward pieces.
    @Test func aToolCallWrittenAsTextBecomesARealCallAndLeavesTheReply() {
        var extractor = TextToolCallExtractor(toolNames: ["web_search"])
        let pieces = ["Let me check. <tool", "_call>\n<function=web_search>\n<parameter=query>\n2025 F1 ",
                      "winner\n</parameter>\n</function>\n</tool_call>\n"]
        let visible = pieces.map { extractor.consume($0) }.joined()
        let (tail, calls) = extractor.finish()
        #expect(visible + tail == "Let me check. ")
        #expect(calls.map(\.name) == ["web_search"])
        #expect(calls.first?.argumentsJSON == #"{"query":"2025 F1 winner"}"#)
    }

    @Test func theJSONFormAndUnclosedBlocksAreCallsToo() {
        var json = TextToolCallExtractor(toolNames: ["web_search"])
        _ = json.consume(#"<tool_call>{"name":"web_search","arguments":{"query":"weather"}}</tool_call>"#)
        #expect(json.finish().calls.first?.argumentsJSON == #"{"query":"weather"}"#)

        var unclosed = TextToolCallExtractor(toolNames: ["web_search"])
        #expect(unclosed.consume("<tool_call>\n<function=web_search>\n<parameter=query>x</parameter>\n</function>").isEmpty)
        #expect(unclosed.finish().calls.count == 1)
    }

    @Test func ordinaryTextIsNeverSwallowed() {
        var extractor = TextToolCallExtractor(toolNames: ["web_search"])
        let visible = ["If a < b and b <", " c then a < c. <b>bold</b>"].map { extractor.consume($0) }.joined()
        let (tail, calls) = extractor.finish()
        #expect(visible + tail == "If a < b and b < c then a < c. <b>bold</b>")
        #expect(calls.isEmpty)

        var unknown = TextToolCallExtractor(toolNames: ["web_search"])
        let block = "<tool_call>\n<function=delete_files>\n</function>\n</tool_call>"
        #expect(unknown.consume(block) + unknown.finish().text == block, "a tool that wasn't offered stays visible text")
    }

    /// Verbatim from a live OpenRouter stream: HTTP 200, then an error event and no choices.
    @Test func anErrorInsideA200StreamIsAnErrorWithItsStatus() throws {
        let event = #"{"id":"gen-1","choices":[],"error":{"code":502,"message":"Upstream error from Nvidia: Service temporarily overloaded","metadata":{"error_type":"provider_unavailable"}}}"#
        let json = try #require(try JSONSerialization.jsonObject(with: Data(event.utf8)) as? [String: Any])
        let error = try #require(OpenAICompatibleProvider.streamError(in: json, displayName: "OpenRouter"))
        #expect(ModelFailure.classify(error) == .unavailable)
        #expect(OpenAICompatibleProvider.streamError(in: ["choices": []], displayName: "OpenRouter") == nil)
    }
}

/// Racing a slow selected model. Timing-based tests of a race are flaky by construction, so every
/// provider here waits on a gate the test opens: each ordering (who answers first, who fails mid-race)
/// is set by the test, not by the scheduler.
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct SlowModelRaceTests {

    @Test func aSlowSelectedModelIsRacedAndTheFirstToAnswerWins() async throws {
        let rig = RaceRig()
        let selected = rig.provider("Groq · big", gate: Gate())          // never opened: it's slow
        rig.candidates = ["a": rig.provider("OpenRouter · a", outcome: .answer(["fast"]))]
        rig.raceGate.openNow()

        let text = try await rig.run(selected)

        #expect(text == "fast")
        #expect(rig.notices.map(\.reasonText) == ["Groq · big hadn't started answering after 15 s"])
        #expect(rig.outcome == .substituteAnswered(rig.poolCandidate("a"), selectedFailed: false),
                "it lost on time, it did not fail: the circuit treats those differently")
        #expect(rig.served == ["OpenRouter · a"])
        #expect(await rig.log.waitForCancel("Groq · big"), "the loser is cancelled")
        #expect(!rig.health.isBenched(RaceRig.selectedRef), "losing a race says nothing about a model's health")
    }

    @Test func aSlowModelThatStartsAnsweringFirstStillWins() async throws {
        let rig = RaceRig()
        let selectedGate = Gate()
        let selected = rig.provider("Groq · big", gate: selectedGate, outcome: .answer(["mine"]))
        rig.candidates = ["a": rig.provider("OpenRouter · a", gate: Gate(), outcome: .answer(["theirs"]))]
        rig.raceGate.openNow()
        rig.onLaunch = { selectedGate.openNow() }   // the selected model answers once the racer is running

        let text = try await rig.run(selected)

        #expect(text == "mine")
        #expect(rig.notices.isEmpty, "the user's own model answered")
        #expect(rig.launched == ["a"], "a racer did start")
        #expect(await rig.log.waitForCancel("OpenRouter · a"))
    }

    @Test func neverRacingMeansNoCandidateWhileTheModelIsMerelySlow() async throws {
        for (race, poolAllowed) in [(TimeInterval?.none, true), (15, false)] {
            let rig = RaceRig(raceAfter: race, poolAllowed: poolAllowed)
            let gate = Gate()
            let selected = rig.provider("Ollama · local", gate: gate, outcome: .answer(["mine"]))
            rig.candidates = ["a": rig.provider("OpenRouter · a", outcome: .answer(["theirs"]))]
            rig.raceGate.openNow()
            Task { try? await Task.sleep(for: .milliseconds(50)); gate.openNow() }
            #expect(try await rig.run(selected) == "mine")
            #expect(rig.launched.isEmpty, "race: \(String(describing: race)), pool allowed: \(poolAllowed)")
        }
    }

    @Test func aBadKeyMidRaceEndsTheRequestAndCancelsTheRacer() async {
        let rig = RaceRig()
        let selectedGate = Gate()
        let selected = rig.provider("Groq · big", gate: selectedGate,
                                    outcome: .fail("Groq HTTP 401 at x. Check the API key."))
        rig.candidates = ["a": rig.provider("OpenRouter · a", gate: Gate(), outcome: .answer(["theirs"]))]
        rig.raceGate.openNow()
        rig.onLaunch = { selectedGate.openNow() }

        await #expect(throws: IntelligenceError.self) { _ = try await rig.run(selected) }
        #expect(await rig.log.waitForCancel("OpenRouter · a"))
        #expect(rig.notices.isEmpty)
    }

    @Test func whenTheSelectedModelFailsMidRaceTheRacerCarriesOnAndTheNoticeSaysWhy() async throws {
        let rig = RaceRig()
        let selectedGate = Gate(), racerGate = Gate()
        let selected = rig.provider("Groq · big", gate: selectedGate, outcome: .fail("Groq HTTP 503 at x."))
        rig.candidates = ["a": rig.provider("OpenRouter · a", gate: racerGate, outcome: .answer(["fast"]))]
        rig.raceGate.openNow()
        rig.onLaunch = {
            selectedGate.openNow()
            Task { try? await Task.sleep(for: .milliseconds(30)); racerGate.openNow() }
        }

        #expect(try await rig.run(selected) == "fast")
        #expect(rig.launched == ["a"], "the running racer is used; no second candidate is needed")
        #expect(rig.notices.map(\.reasonText) == ["Groq · big was temporarily unavailable"])
    }

    @Test func aRacerThatFailsIsReplacedWhileTheSelectedModelIsStillSlow() async throws {
        let rig = RaceRig()
        let selected = rig.provider("Groq · big", gate: Gate())
        rig.candidates = ["a": rig.provider("OpenRouter · a", outcome: .fail("OpenRouter HTTP 503 at x.")),
                          "b": rig.provider("Gemini · b", outcome: .answer(["second"]))]
        rig.raceGate.openNow()

        #expect(try await rig.run(selected) == "second")
        #expect(rig.launched == ["a", "b"])
        #expect(rig.notices.first?.slowAfter == 15)
    }

    @Test func stoppingTheReplyMidRaceStopsEveryModel() async throws {
        let rig = RaceRig()
        let selected = rig.provider("Groq · big", gate: Gate())
        rig.candidates = ["a": rig.provider("OpenRouter · a", gate: Gate(), outcome: .answer(["x"]))]
        rig.raceGate.openNow()
        let started = Gate()
        rig.onLaunch = { started.openNow() }

        let consumer = Task { try await rig.run(selected) }
        await started.wait()
        consumer.cancel()
        _ = try? await consumer.value
        #expect(await rig.log.waitForCancel("Groq · big"))
        #expect(await rig.log.waitForCancel("OpenRouter · a"))
    }

    /// The loser stops at the winner's first word, not when the winner finishes: a paid selected model
    /// that lost must not keep generating (and billing) through the whole of someone else's answer.
    @Test func theLoserIsStoppedAtTheWinnersFirstWordNotItsLast() async throws {
        let rig = RaceRig()
        let restOfAnswer = Gate()
        let selected = rig.provider("Groq · big", gate: Gate())
        rig.candidates = ["a": rig.provider("OpenRouter · a", outcome: .answerThenHold("fast", restOfAnswer))]
        rig.raceGate.openNow()

        let consumer = Task { try await rig.run(selected) }
        #expect(await rig.log.waitForCancel("Groq · big"), "cancelled while the winner is still mid-answer")
        restOfAnswer.openNow()
        #expect(try await consumer.value == "fast and the rest")
    }

    @Test func theSlowNoticeWording() {
        let notice = FallbackNotice(answeredBy: "B", insteadOf: "A", onDevice: false, reason: .other, slowAfter: 15)
        #expect(notice.text == "Answered by B because A hadn't started answering after 15 s")
    }
}

struct RaceTimedOut: Error {}

/// A one-shot latch: `wait()` suspends until `openNow()`, and returns at once after it.
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func openNow() {
        lock.lock()
        open = true
        let pending = waiters
        waiters = []
        lock.unlock()
        pending.forEach { $0.resume() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if open { lock.unlock(); continuation.resume() } else { waiters.append(continuation); lock.unlock() }
        }
    }
}

actor RaceLog {
    private var cancelled: Set<String> = []
    func cancel(_ name: String) { cancelled.insert(name) }
    /// Cancellation lands asynchronously (the provider's stream is torn down on another task).
    func waitForCancel(_ name: String) async -> Bool {
        for _ in 0..<200 {
            if cancelled.contains(name) { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }
}

@MainActor
private final class RaceRig {
    static let selectedRef = ModelRef(keyID: "groq", model: "big")
    let health = ModelHealth()
    let log = RaceLog()
    let raceGate = Gate()
    var candidates: [String: GatedProvider] = [:]
    var launched: [String] = []
    var served: [String] = []
    var notices: [FallbackNotice] = []
    var onLaunch: () -> Void = {}
    var outcome: RequestOutcome?
    private let raceAfter: TimeInterval?
    private let poolAllowed: Bool

    init(raceAfter: TimeInterval? = 15, poolAllowed: Bool = true) {
        self.raceAfter = raceAfter
        self.poolAllowed = poolAllowed
    }

    /// The pool entry `run` builds for a candidate name, so a test can compare against the reported outcome.
    func poolCandidate(_ model: String) -> FallbackCandidate {
        FallbackCandidate(ref: ModelRef(keyID: model, model: model), connectionName: model, kind: .openAICompatible,
                          baseURL: "https://example.com/v1", keychainAccount: "", source: .providerPricing,
                          model: RegistryModel(name: model))
    }

    func provider(_ name: String, gate: Gate? = nil, outcome: GatedProvider.Outcome = .answer(["late"])) -> GatedProvider {
        GatedProvider(name: name, gate: gate, outcome: outcome, log: log)
    }

    func run(_ selected: GatedProvider) async throws -> String {
        let order = candidates.keys.sorted()
        let pool = order.map { poolCandidate($0) }
        let raceGate = self.raceGate
        let health = self.health
        let driver = FallbackDriver(
            health: health,
            poolAllowed: { [poolAllowed] _ in poolAllowed },
            candidates: { _, tried in pool.filter { !tried.contains($0.ref) && !health.isBenched($0.ref) } },
            refreshInBackground: {},
            makeProvider: { [unowned self] candidate in
                self.launched.append(candidate.ref.model)
                self.onLaunch()
                return self.candidates[candidate.ref.model]!
            },
            lastResort: { _, _ in nil },
            raceAfter: { [raceAfter] in raceAfter },
            sleep: { _ in await raceGate.wait() })
        let stream = driver.stream(
            primary: selected, primaryRef: Self.selectedRef,
            needs: FallbackNeeds(prompt: "q", context: nil, primaryModel: nil), label: "race",
            onOutcome: { [unowned self] outcome, _ in self.outcome = outcome },
            onServe: { [unowned self] in self.served.append($0.name) },
            onFallback: { [unowned self] in self.notices.append($0) },
            open: { $0.respond(prompt: "q", context: nil) })
        // A broken race tends to wait forever rather than fail. Bound it, so a regression is a red test
        // with a reason instead of a hung run.
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                var text = ""
                for try await delta in stream { text += delta }
                return text
            }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                throw RaceTimedOut()
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
}

private struct GatedProvider: IntelligenceProvider {
    enum Outcome: Sendable {
        case answer([String])
        case fail(String)
        /// Says its first words, then holds the rest until the gate opens: an answer still streaming.
        case answerThenHold(String, Gate)
    }

    let name: String
    let gate: Gate?
    let outcome: Outcome
    let log: RaceLog
    let isLocal = false
    let isAppleOnDevice = false

    func checkAvailability() async -> Bool { true }

    func respond(prompt: String, context: String?) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await gate?.wait()
                if Task.isCancelled { continuation.finish(); return }
                switch outcome {
                case .answer(let deltas):
                    deltas.forEach { continuation.yield($0) }
                    continuation.finish()
                case .fail(let message):
                    continuation.finish(throwing: IntelligenceError.server(message))
                case .answerThenHold(let first, let rest):
                    continuation.yield(first)
                    await rest.wait()
                    continuation.yield(" and the rest")
                    continuation.finish()
                }
            }
            continuation.onTermination = { [log, name] reason in
                task.cancel()
                if case .cancelled = reason { Task { await log.cancel(name) } }
            }
        }
    }
}

/// Routing around a model that keeps missing. The circuit is what makes the feature stop costing the
/// user a wait on every message once their model is plainly down.
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct PrimaryCircuitTests {
    private let key = "openAICompatible|groq\tbig"
    private let name = "Groq · big"

    private func candidate(_ model: String) -> FallbackCandidate {
        FallbackCandidate(ref: ModelRef(keyID: "or", model: model), connectionName: "OpenRouter",
                          kind: .openAICompatible, baseURL: "https://example.com/v1", keychainAccount: "",
                          source: .providerPricing, model: RegistryModel(name: model))
    }

    /// A miss where the selected model actually failed (the common case in these tests).
    private func miss(_ circuit: PrimaryCircuit, substitute: FallbackCandidate?, routed: Bool = false,
                      failed: Bool = true) {
        circuit.record(primaryKey: key, primaryName: name,
                       outcome: .substituteAnswered(substitute, selectedFailed: failed),
                       answeredBy: substitute.map { "OpenRouter · \($0.ref.model)" } ?? "Apple", routed: routed)
    }

    @Test func twoMissesInARowRouteAroundTheSelectedModel() {
        let clock = TestClock()
        let circuit = PrimaryCircuit(now: { clock.time })
        let free = candidate("a:free")

        miss(circuit, substitute: free)
        #expect(circuit.route(primaryKey: key) == nil, "one miss can be a blip")
        miss(circuit, substitute: free)

        let routed = circuit.route(primaryKey: key)
        #expect(routed?.mode == .routeAround)
        #expect(routed?.substitute == free)
        #expect(routed?.primaryName == name)
        #expect(routed?.retryAt == clock.time + PrimaryCircuit.firstCooldown)
    }

    @Test func oneAnswerFromTheSelectedModelClearsTheCount() {
        let circuit = PrimaryCircuit()
        miss(circuit, substitute: candidate("a:free"))
        circuit.record(primaryKey: key, primaryName: name, outcome: .selectedAnswered, answeredBy: name, routed: false)
        miss(circuit, substitute: candidate("a:free"))
        #expect(circuit.route(primaryKey: key) == nil)
    }

    @Test func missesFurtherApartThanTheWindowAreNotInARow() {
        let clock = TestClock()
        let circuit = PrimaryCircuit(now: { clock.time })
        miss(circuit, substitute: candidate("a:free"))
        clock.time += PrimaryCircuit.missWindow + 1
        miss(circuit, substitute: candidate("a:free"))
        #expect(circuit.route(primaryKey: key) == nil)
    }

    /// A bad key is the user's to fix. Routing around it would hide the problem and keep spending free
    /// quota; a cancelled reply says nothing either.
    @Test func failuresTheUserMustFixNeverRouteAround() {
        let circuit = PrimaryCircuit()
        for _ in 0..<5 {
            circuit.record(primaryKey: key, primaryName: name, outcome: .notCounted, answeredBy: nil, routed: false)
        }
        #expect(circuit.route(primaryKey: key) == nil)
    }

    /// Nothing answered at all still counts against the selected model, but with nothing to route to
    /// there is nowhere to go.
    @Test func missesWithNothingAnsweringDontRouteUntilSomethingHasAnswered() {
        let circuit = PrimaryCircuit()
        circuit.record(primaryKey: key, primaryName: name, outcome: .selectedMissed, answeredBy: nil, routed: false)
        circuit.record(primaryKey: key, primaryName: name, outcome: .selectedMissed, answeredBy: nil, routed: false)
        #expect(circuit.route(primaryKey: key) == nil)
    }

    @Test func afterTheCooldownTheSelectedModelGetsAnotherChanceAndAnAnswerClosesIt() {
        let clock = TestClock()
        let circuit = PrimaryCircuit(now: { clock.time })
        let free = candidate("a:free")
        miss(circuit, substitute: free); miss(circuit, substitute: free)

        clock.time += PrimaryCircuit.firstCooldown + 1
        #expect(circuit.route(primaryKey: key) == nil, "the cooldown is over: try the user's model")
        circuit.record(primaryKey: key, primaryName: name, outcome: .selectedAnswered, answeredBy: name, routed: false)
        #expect(circuit.routed == nil, "it answered: back to normal")
    }

    @Test func aSecondChanceThatMissesWaitsTwiceAsLongUpToTheCap() {
        let clock = TestClock()
        let circuit = PrimaryCircuit(now: { clock.time })
        let free = candidate("a:free")
        miss(circuit, substitute: free); miss(circuit, substitute: free)

        var expected = PrimaryCircuit.firstCooldown
        for _ in 0..<5 {
            clock.time = circuit.routed!.retryAt + 1
            #expect(circuit.route(primaryKey: key) == nil)
            miss(circuit, substitute: free)
            expected = min(expected * 2, PrimaryCircuit.maxCooldown)
            #expect(circuit.routed?.retryAt == clock.time + expected)
        }
        #expect(expected == PrimaryCircuit.maxCooldown)
    }

    @Test func aRoutedRequestJudgesTheStandInOnlyAndFollowsItWhenItMoves() {
        let clock = TestClock()
        let circuit = PrimaryCircuit(now: { clock.time })
        let first = candidate("a:free"), second = candidate("b:free")
        miss(circuit, substitute: first); miss(circuit, substitute: first)
        let retryAt = circuit.routed!.retryAt

        // The stand-in answered: nothing changes.
        circuit.record(primaryKey: key, primaryName: name, outcome: .selectedAnswered,
                       answeredBy: "OpenRouter · a:free", routed: true)
        #expect(circuit.routed?.retryAt == retryAt, "the user's model wasn't asked, so it isn't forgiven")
        #expect(circuit.routed?.substitute == first)

        // The stand-in failed and another free model answered: follow that one.
        miss(circuit, substitute: second, routed: true)
        #expect(circuit.routed?.substitute == second)
    }

    @Test func pickingADifferentModelStartsOver() {
        let circuit = PrimaryCircuit()
        let free = candidate("a:free")
        miss(circuit, substitute: free); miss(circuit, substitute: free)
        #expect(circuit.route(primaryKey: key) != nil)
        #expect(circuit.route(primaryKey: "openAICompatible|or\tother") == nil)
        circuit.record(primaryKey: "openAICompatible|or\tother", primaryName: "OpenRouter · other",
                       outcome: .selectedAnswered, answeredBy: "OpenRouter · other", routed: false)
        #expect(circuit.routed == nil)
    }

    /// Being slow is not being broken. A model that keeps losing the race on time keeps its place: the
    /// stand-in starts with the request instead, so the user stops paying the wait but still gets their
    /// own model whenever it is ready in time.
    @Test func losingOnTimeRacesTheModelInsteadOfSkippingIt() {
        let circuit = PrimaryCircuit()
        let free = candidate("a:free")
        miss(circuit, substitute: free, failed: false)
        miss(circuit, substitute: free, failed: false)

        #expect(circuit.route(primaryKey: key) == nil, "the user's model still gets every request")
        #expect(circuit.racesImmediately(primaryKey: key))
        #expect(circuit.routed?.mode == .raceImmediately, "the Chat bar still says what is happening")
    }

    @Test func oneRealFailureAmongSlowLossesSkipsTheModel() {
        let circuit = PrimaryCircuit()
        let free = candidate("a:free")
        miss(circuit, substitute: free, failed: false)
        miss(circuit, substitute: free, failed: true)
        #expect(circuit.route(primaryKey: key)?.mode == .routeAround)
        #expect(!circuit.racesImmediately(primaryKey: key))
    }

    @Test func aRacingCircuitThatLaterFailsSwitchesToSkipping() {
        let clock = TestClock()
        let circuit = PrimaryCircuit(now: { clock.time })
        let free = candidate("a:free")
        miss(circuit, substitute: free, failed: false); miss(circuit, substitute: free, failed: false)
        clock.time = circuit.routed!.retryAt + 1
        #expect(!circuit.racesImmediately(primaryKey: key), "cooldown over: back to the normal wait")
        miss(circuit, substitute: free, failed: true)
        #expect(circuit.routed?.mode == .routeAround)
    }

    @Test func tryAgainSendsTheNextRequestToTheSelectedModel() {
        let clock = TestClock()
        let circuit = PrimaryCircuit(now: { clock.time })
        let free = candidate("a:free")
        miss(circuit, substitute: free); miss(circuit, substitute: free)
        #expect(circuit.route(primaryKey: key) != nil)
        circuit.retryNow()
        #expect(circuit.route(primaryKey: key) == nil)
    }
}

/// What the driver reports back about a request. The circuit acts on these, so a wrong one would either
/// route around a healthy model or never route around a dead one.
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct RequestOutcomeTests {
    private func pick(_ keyID: String, _ model: String) -> FallbackCandidate {
        FallbackCandidate(ref: ModelRef(keyID: keyID, model: model), connectionName: keyID, kind: .openAICompatible,
                          baseURL: "https://example.com/v1", keychainAccount: "", source: .providerPricing,
                          model: RegistryModel(name: model))
    }

    private func run(primary: FakeProvider, primaryRef: ModelRef = ModelRef(keyID: "groq", model: "big"),
                     pool: [FallbackCandidate] = [],
                     providers: [String: FakeProvider] = [:], lastResort: FakeProvider? = nil,
                     routedFrom: String? = nil, exclude: Set<ModelRef> = [])
        async -> (text: String?, outcome: RequestOutcome?, answeredBy: String?, notices: [FallbackNotice], tried: [String]) {
        let health = ModelHealth()
        var outcome: RequestOutcome?
        var answeredBy: String?
        var notices: [FallbackNotice] = []
        var tried: [String] = []
        let driver = FallbackDriver(
            health: health,
            poolAllowed: { _ in true },
            candidates: { _, alreadyTried in pool.filter { !alreadyTried.contains($0.ref) } },
            refreshInBackground: {},
            makeProvider: { candidate in
                tried.append(candidate.ref.model)
                return providers[candidate.ref.model] ?? FakeProvider(name: candidate.ref.model, outcome: .fail("HTTP 500"))
            },
            lastResort: { _, _ in lastResort })
        let stream = driver.stream(
            primary: primary, primaryRef: primaryRef,
            needs: FallbackNeeds(prompt: "q", context: nil, primaryModel: nil), label: "outcome",
            routedFrom: routedFrom, exclude: exclude,
            onOutcome: { outcome = $0; answeredBy = $1 },
            onServe: { _ in }, onFallback: { notices.append($0) },
            open: { $0.respond(prompt: "q", context: nil) })
        var text: String? = ""
        do { for try await delta in stream { text! += delta } } catch { text = nil }
        return (text, outcome, answeredBy, notices, tried)
    }

    @Test func theSelectedModelAnswering() async {
        let result = await run(primary: FakeProvider(name: "Groq · big", outcome: .answer(["hi"])))
        #expect(result.outcome == .selectedAnswered)
        #expect(result.answeredBy == "Groq · big")
    }

    @Test func aFreeModelAnsweringNamesWhichOne() async {
        let free = pick("or", "a:free")
        let result = await run(primary: FakeProvider(name: "Groq · big", outcome: .fail("Groq HTTP 429 at x.")),
                               pool: [free], providers: ["a:free": FakeProvider(name: "OpenRouter · a:free", outcome: .answer(["hi"]))])
        #expect(result.outcome == .substituteAnswered(free, selectedFailed: true))
        #expect(result.answeredBy == "OpenRouter · a:free")
    }

    @Test func theOnDeviceModelAnsweringHasNoCandidate() async {
        let result = await run(primary: FakeProvider(name: "Groq · big", outcome: .fail("Groq HTTP 429 at x.")),
                               lastResort: FakeProvider(name: "Apple", isLocal: true, outcome: .answer(["hi"])))
        #expect(result.outcome == .substituteAnswered(nil, selectedFailed: true))
    }

    @Test func aFailureTheUserMustFixIsNotHeldAgainstTheModel() async {
        for message in ["Groq HTTP 401 at x. Check the API key.", "Groq HTTP 413 at x."] {
            let result = await run(primary: FakeProvider(name: "Groq · big", outcome: .fail(message)))
            #expect(result.outcome == .notCounted, "\(message)")
        }
    }

    @Test func aFallbackWorthyFailureWithNothingLeftIsAMiss() async {
        let result = await run(primary: FakeProvider(name: "Groq · big", outcome: .fail("Groq HTTP 503 at x.")))
        #expect(result.outcome == .selectedMissed)
        #expect(result.text == nil, "the selected model's error still surfaces")
    }

    /// While routing around a model, the stand-in is what the request starts with, but every notice must
    /// still name the model being skipped, and that model must never be offered as a candidate.
    @Test func aRoutedRequestNamesTheSkippedModelAndNeverTriesIt() async {
        let skipped = ModelRef(keyID: "groq", model: "big")
        let result = await run(primary: FakeProvider(name: "OpenRouter · a:free", outcome: .answer(["hi"])),
                               primaryRef: ModelRef(keyID: "or", model: "a:free"),
                               pool: [pick("groq", "big"), pick("or", "b:free")],
                               routedFrom: "Groq · big", exclude: [skipped])
        #expect(result.text == "hi")
        #expect(result.notices.map(\.text) == ["Answered by OpenRouter · a:free because Groq · big isn't responding, so it's being skipped for now"])
        #expect(result.tried.isEmpty)
        #expect(result.outcome == .selectedAnswered, "the stand-in answered; the skipped model wasn't asked")
    }

    @Test func aRoutedRequestFallsOnToAnotherFreeModelWithoutTheSkippedOne() async {
        let skipped = ModelRef(keyID: "groq", model: "big")
        let second = pick("or", "b:free")
        let result = await run(primary: FakeProvider(name: "OpenRouter · a:free", outcome: .fail("OpenRouter HTTP 503 at x.")),
                               primaryRef: ModelRef(keyID: "or", model: "a:free"),
                               pool: [pick("groq", "big"), second],
                               providers: ["b:free": FakeProvider(name: "OpenRouter · b:free", outcome: .answer(["hi"]))],
                               routedFrom: "Groq · big", exclude: [skipped])
        #expect(result.tried == ["b:free"], "the model being routed around is never a candidate")
        #expect(result.outcome == .substituteAnswered(second, selectedFailed: true))
        #expect(result.notices.first?.insteadOf == "Groq · big")
    }
}

/// The on-device stand-in. It holds about 2K tokens of input once its reply is reserved, and it is
/// handed a prompt written for the user's own model, so both of these matter in practice.
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct OnDeviceStandInTests {

    private func needs(tokens: Int) -> FallbackNeeds {
        FallbackNeeds(prompt: String(repeating: "a", count: tokens * 4), context: nil, primaryModel: nil)
    }

    @Test func aConversationPastItsWindowSkipsItRatherThanSpendingATurn() {
        #expect(FallbackPolicy.onDeviceCanHold(needs(tokens: 500)))
        #expect(FallbackPolicy.onDeviceCanHold(needs(tokens: OnDeviceProvider.inputBudgetTokens)))
        #expect(!FallbackPolicy.onDeviceCanHold(needs(tokens: OnDeviceProvider.inputBudgetTokens + 1)))
        #expect(!FallbackPolicy.onDeviceCanHold(needs(tokens: 30_000)), "a long chat on a big cloud model")
        #expect(OnDeviceProvider.inputBudgetTokens + 2_048 == OnDeviceProvider.contextTokens,
                "input budget and the reserved reply fill the window exactly")
    }

    /// Without this, the model is handed a conversation it never took part in and answers as if the last
    /// message started a new one.
    @Test func itIsToldItIsStandingInAndForWhom() {
        let base = "You are Lasso's assistant."
        let plain = OnDeviceProvider.withStandInNote(base, standingInFor: nil)
        #expect(plain == base, "no note when it is the model the user picked")

        let standIn = OnDeviceProvider.withStandInNote(base, standingInFor: "Groq · openai/gpt-oss-120b")
        #expect(standIn.hasPrefix(base), "the conversation's own instructions still come first")
        #expect(standIn.contains("in place of Groq · openai/gpt-oss-120b"))
        #expect(standIn.contains("read the messages above and continue it"))
        #expect(standIn.count - base.count < 500, "a note, not a second system prompt")
    }
}

/// Routing around a model must not route around the checks that protect the answer. Without these, a
/// stand-in chosen days ago keeps serving requests it cannot serve: images it cannot read, searches it
/// cannot run, conversations it cannot hold, or a key that turned out to be billed.
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct RoutedSubstituteTests {
    private func registry(_ models: [RegistryModel]) -> KeysRegistry {
        KeysRegistry(entries: [RegisteredKey(id: "or", name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1",
                                             keyNotRequired: false, models: models, useForFallback: true)])
    }

    private func freeModel(_ name: String, images: Bool = true, tools: Bool = true, context: Int = 200_000) -> RegistryModel {
        var model = RegistryModel(name: name)
        model.freeOffer = .always
        model.acceptsImages = images
        model.supportsTools = tools
        model.contextTokens = context
        return model
    }

    private var ref: ModelRef { ModelRef(keyID: "or", model: "stand-in-70b:free") }

    private func substitute(_ registry: KeysRegistry, _ needs: FallbackNeeds,
                            billed: Set<String> = [], benched: Bool = false) -> FallbackCandidate? {
        FreeModelPool.substitute(ref, in: registry, needs: needs, billed: billed, isBenched: { _ in benched })
    }

    @Test func aUsableStandInIsReturned() {
        let text = FallbackNeeds(prompt: "hi", context: nil, primaryModel: nil)
        #expect(substitute(registry([freeModel("stand-in-70b:free")]), text)?.ref == ref)
    }

    @Test func theRequestsOwnRequirementsStillApply() {
        let images = FallbackNeeds(messages: [ChatTurn(role: .user, text: "what is this", imageBase64s: ["x"])],
                                   tools: .none, primaryModel: nil)
        #expect(substitute(registry([freeModel("stand-in-70b:free", images: false)]), images) == nil,
                "a text-only stand-in must not be handed an image")

        let search = FallbackNeeds(messages: [ChatTurn(role: .user, text: "search the news")],
                                   tools: .required, primaryModel: nil)
        #expect(substitute(registry([freeModel("stand-in-70b:free", tools: false)]), search) == nil,
                "a stand-in that cannot search must not answer a search turn")

        let long = FallbackNeeds(prompt: String(repeating: "a", count: 400_000), context: nil, primaryModel: nil)
        #expect(substitute(registry([freeModel("stand-in-70b:free", context: 8_000)]), long) == nil)
    }

    @Test func aStandInThatLeftThePoolOrWentQuietIsDropped() {
        let text = FallbackNeeds(prompt: "hi", context: nil, primaryModel: nil)
        #expect(substitute(registry([freeModel("stand-in-70b:free")]), text, benched: true) == nil)
        // A zero-priced model stays free even on a billed key: only a free-*plan* model (Groq or Google,
        // where free depends on the Free tier switch) is dropped when the key is proven billed.
        #expect(substitute(registry([freeModel("stand-in-70b:free")]), text, billed: ["or"])?.ref == ref,
                "a price of zero is free whoever holds the key")

        var groqModel = RegistryModel(name: "openai/gpt-oss-120b")
        groqModel.contextTokens = 131_072
        let groq = KeysRegistry(entries: [RegisteredKey(id: "groq", name: "Groq",
                                                        baseURL: "https://api.groq.com/openai/v1",
                                                        keyNotRequired: false, models: [groqModel],
                                                        freeTier: true, useForFallback: true)])
        let groqRef = ModelRef(keyID: "groq", model: "openai/gpt-oss-120b")
        #expect(FreeModelPool.substitute(groqRef, in: groq, needs: text, billed: [], isBenched: { _ in false })?.ref == groqRef)
        #expect(FreeModelPool.substitute(groqRef, in: groq, needs: text, billed: ["groq"], isBenched: { _ in false }) == nil,
                "the selected model on that key is paid-only, so the key is billed")
        #expect(substitute(registry([freeModel("someone-else:free")]), text) == nil, "no longer in the pool")

        var optedOut = registry([freeModel("stand-in-70b:free")])
        optedOut.entries[0].useForFallback = false
        #expect(substitute(optedOut, text) == nil, "consent was withdrawn")
    }

    @Test func theOnDeviceStandInKeepsItsOwnTwoRules() {
        let small = FallbackNeeds(prompt: "hi", context: nil, primaryModel: nil)
        #expect(FallbackPolicy.onDeviceCanStandIn(small))

        let long = FallbackNeeds(prompt: String(repeating: "a", count: 40_000), context: nil, primaryModel: nil)
        #expect(!FallbackPolicy.onDeviceCanStandIn(long), "it would fail on every message until the cooldown ended")

        let search = FallbackNeeds(messages: [ChatTurn(role: .user, text: "search")], tools: .required, primaryModel: nil)
        #expect(!FallbackPolicy.onDeviceCanStandIn(search), "it has no tool loop")
    }
}
