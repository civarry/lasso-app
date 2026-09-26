import Foundation

// B–D. The free-model pool: which registry models are free (from normalized discovery data), which of
// those fit one request, and in what order to try them. Pure functions over `KeysRegistry`, with no
// provider names and no I/O. The registry itself (`KeysRegistry`, persisted with the connections) is
// the cache: there is no second model database to drift from the configured connections.

// MARK: - Free status

enum FreeSource: String, Equatable, Sendable {
    case providerPricing   // the provider lists every price as zero
    case freePlan          // on the provider's documented free plan, and the key is marked free tier
    case localServer       // the connection is on this Mac
}

enum FreeModelStatus: Equatable, Sendable {
    case confirmed(FreeSource)
    case notFree
    case unknown
}

enum FreeModelDetector {
    /// Free status never looks at whether a request worked, and never at health: a rate-limited free
    /// model is still free. It changes only when a refresh rewrites `freeOffer` or the user flips the
    /// connection's Free tier switch.
    static func status(of model: RegistryModel, on entry: RegisteredKey) -> FreeModelStatus {
        switch model.freeOffer {
        case .always?: return .confirmed(.providerPricing)
        case .never?: return .notFree
        case .freePlan?: return entry.freeTier ? .confirmed(.freePlan) : .unknown
        case nil: return entry.isLocal ? .confirmed(.localServer) : .unknown
        }
    }
}

// MARK: - Size, the one quality signal providers publish consistently

/// A coarse size band, used to keep a fallback close to the primary. Not an intelligence score: no
/// provider in the registry publishes one, and inventing one would pretend to knowledge Lasso doesn't
/// have. Parameter count is the signal that is actually published (in the model id: "gpt-oss-120b",
/// "qwen3-32b"), and family suffixes carry the provider's own positioning ("flash-lite", "mini", "pro").
enum ModelSize: Int, Comparable, Sendable {
    case small = 0, medium = 1, large = 2

    static func < (lhs: ModelSize, rhs: ModelSize) -> Bool { lhs.rawValue < rhs.rawValue }

    static func infer(fromModelID id: String) -> ModelSize? { estimate(fromModelID: id)?.size }

    /// Parameter count when the id states one (`published`, with the count in `billions`); otherwise a
    /// known large family; otherwise the family suffix; otherwise nil (unknown, which is never treated
    /// as small or large). An active-parameter token ("a3b" in "qwen3-30b-a3b") is skipped so an MoE
    /// model is sized by its total.
    static func estimate(fromModelID id: String) -> (size: ModelSize, published: Bool, billions: Double?)? {
        let lower = GeminiAPI.bareModelID(id).lowercased()
        if let regex = try? NSRegularExpression(pattern: #"(?<![a-z0-9.])(\d+(?:\.\d+)?)b(?![a-z0-9])"#),
           let match = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
           let range = Range(match.range(at: 1), in: lower), let billions = Double(lower[range]) {
            return (billions >= 70 ? .large : billions >= 15 ? .medium : .small, true, billions)
        }
        if isKnownLargeFamily(lower) { return (.large, false, nil) }
        let tokens = Set(lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        if !tokens.isDisjoint(with: ["mini", "nano", "lite", "tiny", "small", "micro", "haiku"]) { return (.small, false, nil) }
        if !tokens.isDisjoint(with: ["pro", "opus", "ultra", "large", "max"]) { return (.large, false, nil) }
        if !tokens.isDisjoint(with: ["flash", "sonnet", "medium"]) { return (.medium, false, nil) }
        return nil
    }

    /// Families whose ids carry no parameter count but whose makers publicly document them as large,
    /// hundreds of billions of parameters (DeepSeek V3/R1 671B, Kimi K2 1T, GLM-4.5/4.6 355B, Qwen3
    /// Coder 480B, MiniMax-M1 456B). Without this they read as "unknown" and rank below a 20B model.
    /// The distilled R1s and the GLM "Air" variants are small models sharing the family name.
    private static func isKnownLargeFamily(_ id: String) -> Bool {
        if id.contains("deepseek-v3") || id.contains("deepseek-chat") { return true }
        if id.contains("deepseek-r1") { return !id.contains("distill") }
        if id.contains("glm-4.5") || id.contains("glm-4.6") { return !id.contains("air") }
        return id.contains("kimi-k2") || id.contains("qwen3-coder") || id.contains("minimax-m1")
    }
}

// MARK: - What a request needs

enum ToolNeed: Sendable, Equatable {
    case none
    /// Tools are offered and the model may use them.
    case preferred
    /// The turn depends on a tool (the user asked for a search): a model that can't call it would
    /// answer from stale knowledge instead, so it isn't a fallback for this turn.
    case required
}

struct FallbackNeeds: Equatable, Sendable {
    var images: Bool
    var tools: ToolNeed
    var estimatedTokens: Int
    /// Size of the model the user chose, so a fallback stays close to it. nil when unknown.
    var primarySize: ModelSize?
    /// The model the user chose, normalized (`FreeModelPool.normalizedModelID`), so the same model
    /// served free by another connection can be tried first. nil when there is no cloud model.
    var primaryModel: String?
    /// Base codes of the languages the answer must read or write (a translation's source and target).
    /// Empty when the caller doesn't say. Gates the on-device model, which supports only some.
    var languages: Set<String> = []

    /// Rough input size (4 characters a token, plus a flat allowance per image). Only used to rule out
    /// windows that are plainly too small.
    init(messages: [ChatTurn], tools: ToolNeed, primaryModel: String?) {
        let chars = messages.reduce(0) { $0 + $1.text.count }
        let imageCount = messages.reduce(0) { $0 + $1.imageBase64s.count }
        images = imageCount > 0
        self.tools = tools
        estimatedTokens = chars / 4 + imageCount * 1_000
        primarySize = primaryModel.flatMap(ModelSize.infer(fromModelID:))
        self.primaryModel = primaryModel.map(FreeModelPool.normalizedModelID)
    }

    init(prompt: String, context: String?, primaryModel: String?) {
        images = false
        tools = .none
        estimatedTokens = (prompt.count + (context?.count ?? 0)) / 4
        primarySize = primaryModel.flatMap(ModelSize.infer(fromModelID:))
        self.primaryModel = primaryModel.map(FreeModelPool.normalizedModelID)
    }
}

// MARK: - Candidates

struct FallbackCandidate: Equatable, Sendable {
    var ref: ModelRef
    var connectionName: String
    var kind: ConnectionKind
    var baseURL: String
    var keychainAccount: String
    var source: FreeSource
    var model: RegistryModel

    /// Whether this candidate can run a tool loop. The native Gemini provider has none, whatever the
    /// model supports; an OpenAI-compatible endpoint reports it per model when it reports it at all.
    var toolSupport: Bool? { kind == .gemini ? false : model.supportsTools }

    var size: ModelSize? { ModelSize.infer(fromModelID: model.name) }

    /// The window to trust: reported by the endpoint, else the app's own name-based inference.
    var contextWindow: Int? {
        model.contextTokens ?? IntelligenceCoordinator.inferContextFromModelName(GeminiAPI.bareModelID(model.name))
    }
}

/// Who may use the pool at all. The privacy boundary lives here, testable on its own: only a request
/// that was already going to the cloud may move to another cloud provider, and never in local-only.
enum FallbackPolicy {
    static func poolAllowed(enabled: Bool, localOnly: Bool, primaryIsLocal: Bool) -> Bool {
        enabled && !localOnly && !primaryIsLocal
    }

    /// Whether the on-device model may stand in for a *routed* request: it has to be able to hold the
    /// conversation, and a turn that depends on a tool is not one it can serve (it has no tool loop).
    static func onDeviceCanStandIn(_ needs: FallbackNeeds) -> Bool {
        onDeviceCanHold(needs) && needs.tools != .required
    }

    /// Whether the on-device model could hold this request at all. The prompt was built for the user's
    /// own model, so a long conversation is far past Apple's window: trying it spends a turn to reach
    /// `exceededContextWindowSize`, and the user sees their own model's error a beat later anyway.
    static func onDeviceCanHold(_ needs: FallbackNeeds) -> Bool {
        needs.estimatedTokens <= OnDeviceProvider.inputBudgetTokens
            && OnDeviceProvider.supports(languages: needs.languages)
    }

    /// Whether the selected model counts as local for the pool: on this Mac (the provider says so), or
    /// an OpenAI-compatible server on the user's own network (`KeysRegistry.isPrivateNetworkURL`). The
    /// second isn't "local" for the privacy badge, since the request does leave this Mac, but a user who
    /// runs their model on a LAN box chose to keep the conversation in-house, and a cloud fallback would
    /// quietly undo that.
    static func primaryIsLocal(providerIsLocal: Bool, preferred: ProviderKind, baseURL: String) -> Bool {
        providerIsLocal || (preferred == .openAICompatible && KeysRegistry.isPrivateNetworkURL(baseURL))
    }
}

enum FreeModelPool {
    /// A window the endpoint doesn't report is assumed to be this — the same conservative default the
    /// app uses for an OpenAI-compatible model it can't detect (`effectiveContextTokens`).
    static let unknownWindowAssumption = 32_000

    /// Every confirmed-free chat model on connections the user opted into the fallback ("Use as
    /// fallback"), in connection order. This is the pool: nothing outside it is ever sent a request.
    static func freeModels(in registry: KeysRegistry) -> [FallbackCandidate] {
        confirmedFree(in: registry).filter { registry.key(withID: $0.ref.keyID)?.useForFallback == true }
    }

    /// Every confirmed-free chat model, whether or not its connection is opted in. Describes the models
    /// (the "free" badges, a connection's "N free"), never decides where a request goes.
    ///
    /// The provider rules run here, at read time, as well as at discovery: a rule shipped in an update
    /// then applies to a list fetched before it, without waiting for a refresh. Once per connection.
    static func confirmedFree(in registry: KeysRegistry) -> [FallbackCandidate] {
        registry.entries.filter(\.enabled).flatMap { entry in
            FreeTierRules.annotate(entry.models, for: entry).compactMap { model in candidate(model, on: entry) }
        }
    }

    private static func candidate(_ model: RegistryModel, on entry: RegisteredKey) -> FallbackCandidate? {
        guard model.capabilities.contains(.language), model.outputsOnlyText != false, model.isRouter != true,
              case .confirmed(let source) = FreeModelDetector.status(of: model, on: entry)
        else { return nil }
        return FallbackCandidate(ref: ModelRef(keyID: entry.id, model: model.name),
                                 connectionName: entry.name, kind: entry.kind,
                                 baseURL: entry.baseURL, keychainAccount: entry.keychainAccount,
                                 source: source, model: model)
    }

    /// The tag a model picker shows: "free tier" when it's free because the key is on the provider's
    /// free plan (the user's claim, which Lasso can't check), "free" when the provider prices it at zero
    /// or it runs on this Mac. Describes the model, so it doesn't depend on "Use as fallback".
    ///
    /// - Parameter primary: the selected model. On a Free tier key that it bills
    ///   (`billedConnections`), the plan's models are billed too, so they get no badge.
    static func badge(for ref: ModelRef, in registry: KeysRegistry, primary: ModelRef? = nil) -> String? {
        guard let entry = registry.key(withID: ref.keyID), entry.enabled,
              let model = entry.models.first(where: { $0.name == ref.model }),
              let free = FreeTierRules.annotate([model], for: entry).first.flatMap({ candidate($0, on: entry) }),
              !isBilled(free, billed: billedConnections(in: registry, primary: primary))
        else { return nil }
        return badge(for: free.source)
    }

    /// Every badge in the registry at once, for a picker that lists hundreds of models.
    static func badges(in registry: KeysRegistry, primary: ModelRef? = nil) -> [ModelRef: String] {
        let billed = billedConnections(in: registry, primary: primary)
        return Dictionary(confirmedFree(in: registry).filter { !isBilled($0, billed: billed) }
                            .map { ($0.ref, badge(for: $0.source)) },
                          uniquingKeysWith: { first, _ in first })
    }

    /// A free-plan model on a connection whose key is being billed: not free for this user right now.
    private static func isBilled(_ candidate: FallbackCandidate, billed: Set<String>) -> Bool {
        candidate.source == .freePlan && billed.contains(candidate.ref.keyID)
    }

    private static func badge(for source: FreeSource) -> String {
        source == .freePlan ? "free tier" : "free"
    }

    /// Connections whose key is being billed right now although they're marked Free tier: the selected
    /// model is on that connection and the provider documents it as not on the free plan. A request to
    /// it proves the key has billing, so the plan's "free" models there would be billed too.
    static func billedConnections(in registry: KeysRegistry, primary: ModelRef?) -> Set<String> {
        guard let primary, let entry = registry.key(withID: primary.keyID), entry.freeTier,
              let model = entry.models.first(where: { $0.name == primary.model }),
              FreeTierRules.annotate([model], for: entry).first?.freeOffer == .never
        else { return [] }
        return [entry.id]
    }

    /// Same model, any connection: "openai/gpt-oss-120b:free" on OpenRouter and "openai/gpt-oss-120b" on
    /// Groq are one model. Lowercased, without Gemini's "models/", a vendor path, or a ":free" suffix.
    static func normalizedModelID(_ id: String) -> String {
        var id = GeminiAPI.bareModelID(id.lowercased())
        if let slash = id.lastIndex(of: "/") { id = String(id[id.index(after: slash)...]) }
        if id.hasSuffix(":free") { id.removeLast(":free".count) }
        return id
    }

    /// Why a candidate was left out of one request. Kept so tests and logs can say which rule applied.
    enum Exclusion: String, Equatable, Sendable {
        case alreadyTried, benched, billedKey, cannotReadImages, cannotCallTools, contextTooSmall,
             muchSmallerThanPrimary
    }

    static func exclusion(of candidate: FallbackCandidate, needs: FallbackNeeds, tried: Set<ModelRef>,
                          billed: Set<String> = [], isBenched: (ModelRef) -> Bool) -> Exclusion? {
        if tried.contains(candidate.ref) { return .alreadyTried }
        if isBenched(candidate.ref) { return .benched }
        if isBilled(candidate, billed: billed) { return .billedKey }
        if needs.images, !(candidate.model.acceptsImages ?? candidate.model.capabilities.contains(.vision)) {
            return .cannotReadImages
        }
        if needs.tools == .required, candidate.toolSupport == false { return .cannotCallTools }
        let needed = needs.estimatedTokens + ChatContextBuilder.Budget.outputReserveTokens
        if needed > (candidate.contextWindow ?? unknownWindowAssumption) { return .contextTooSmall }
        // Two bands down (a small model standing in for a large one) is a different answer, not a
        // fallback. One band down is allowed: it's usually the only free option, and still close.
        if let primary = needs.primarySize, let size = candidate.size, size.rawValue + 2 <= primary.rawValue {
            return .muchSmallerThanPrimary
        }
        return nil
    }

    /// The models to try for one request, best first.
    ///
    /// Order, most important first:
    /// 1. The selected model itself, served by another connection: the closest possible stand-in.
    /// 2. Size band: large, medium, unknown, small. Quality beats diversity, so a large model from the
    ///    connection that just failed still outranks a small one elsewhere.
    /// 3. Within a band, a size the provider published (a parameter count) before one read off a
    ///    family name: "120b" is evidence, "pro" is positioning.
    /// 4. Tool support when tools are in play: known yes, unknown, known no.
    /// 5. Connections not yet tried in this request, so a shared rate limit isn't hit three times.
    /// 6. More published parameters first (a 120B before a 70B in the large band).
    /// 7. Alternating between connections, then the order connections were added.
    ///
    /// - Parameter billed: connections whose free-plan models would be billed (`billedConnections`).
    static func candidates(in registry: KeysRegistry, needs: FallbackNeeds, excluding tried: Set<ModelRef>,
                           billed: Set<String> = [], isBenched: (ModelRef) -> Bool) -> [FallbackCandidate] {
        let triedConnections = Set(tried.map(\.keyID))
        let connectionIndex = Dictionary(registry.entries.enumerated().map { ($1.id, $0) },
                                         uniquingKeysWith: { first, _ in first })
        var excluded: [Exclusion: Int] = [:]
        let eligible = freeModels(in: registry).filter {
            guard let reason = exclusion(of: $0, needs: needs, tried: tried, billed: billed, isBenched: isBenched)
            else { return true }
            excluded[reason, default: 0] += 1
            return false
        }
        if !excluded.isEmpty {
            let counts = excluded.sorted { $0.key.rawValue < $1.key.rawValue }
                .map { "\($0.key.rawValue)=\($0.value)" }.joined(separator: " ")
            Log.intelligence.debug("free pool · \(eligible.count, privacy: .public) eligible, excluded \(counts, privacy: .public)")
        }

        struct Ranked { var candidate: FallbackCandidate; var key: [Int] }
        var positionInGroup: [String: Int] = [:]
        let ranked = eligible.map { candidate -> Ranked in
            let estimate = ModelSize.estimate(fromModelID: candidate.model.name)
            let band = sizeRank(estimate?.size)
            let group = "\(candidate.ref.keyID)|\(band)"
            let position = positionInGroup[group, default: 0]
            positionInGroup[group] = position + 1
            let sameModel = needs.primaryModel.map { $0 == normalizedModelID(candidate.model.name) } ?? false
            return Ranked(candidate: candidate, key: [
                sameModel ? 0 : 1,
                -band,
                estimate?.published == true ? 0 : 1,
                needs.tools == .none ? 0 : toolRank(candidate.toolSupport),
                triedConnections.contains(candidate.ref.keyID) ? 1 : 0,
                -Int(((estimate?.billions ?? 0) * 1_000).rounded()),
                position,
                connectionIndex[candidate.ref.keyID] ?? .max,
            ])
        }
        return ranked.sorted { $0.key.lexicographicallyPrecedes($1.key) }.map(\.candidate)
    }

    private static func sizeRank(_ size: ModelSize?) -> Int {
        switch size {
        case .large?: 3
        case .medium?: 2
        case nil: 1
        case .small?: 0
        }
    }

    private static func toolRank(_ support: Bool?) -> Int {
        switch support {
        case true?: 0
        case nil: 1
        case false?: 2
        }
    }

    /// The pool entry a routed request may actually use, re-checked against *this* request. Skipping the
    /// model the user chose must not also skip the checks that protect the answer: the stand-in still has
    /// to be free, opted in, healthy, unbilled and able to serve this request. nil sends the request down
    /// the normal path instead.
    static func substitute(_ ref: ModelRef, in registry: KeysRegistry, needs: FallbackNeeds,
                           billed: Set<String>, isBenched: (ModelRef) -> Bool) -> FallbackCandidate? {
        guard let fresh = freeModels(in: registry).first(where: { $0.ref == ref }),
              exclusion(of: fresh, needs: needs, tried: [], billed: billed, isBenched: isBenched) == nil
        else { return nil }
        return fresh
    }

    /// "12 free models across 3 connections" plus the oldest check among connections that contribute.
    /// A billed Free tier key's plan models are left out, as the pool leaves them out (`primary`).
    static func summary(of registry: KeysRegistry, primary: ModelRef? = nil)
        -> (models: Int, connections: Int, oldestCheck: Date?) {
        let billed = billedConnections(in: registry, primary: primary)
        let free = freeModels(in: registry).filter { !isBilled($0, billed: billed) }
        let keyIDs = Set(free.map(\.ref.keyID))
        let checks = registry.entries.filter { keyIDs.contains($0.id) }.compactMap(\.modelsCheckedAt)
        return (free.count, keyIDs.count, checks.min())
    }

    /// Connections that serve models but contribute nothing to the pool, split by what would change
    /// that: turning on Use as fallback, turning on Free tier (both, for some), or nothing Lasso can do
    /// yet (no free-model rule for the provider).
    static func nonContributing(in registry: KeysRegistry)
        -> (needsFreeTier: [RegisteredKey], unsupported: [RegisteredKey], notOptedIn: [RegisteredKey]) {
        let contributing = Set(freeModels(in: registry).map(\.ref.keyID))
        let wouldContribute = Set(confirmedFree(in: registry).map(\.ref.keyID))
        let idle = registry.entries.filter { $0.enabled && !$0.models.isEmpty && !contributing.contains($0.id) }
            .map { entry in
                var annotated = entry
                annotated.models = FreeTierRules.annotate(entry.models, for: entry)
                return annotated
            }
        let needsFreeTier = idle.filter { entry in
            !entry.freeTier && entry.models.contains { $0.freeOffer == .freePlan }
        }
        let unsupported = idle.filter { entry in
            !entry.isLocal && entry.models.allSatisfy { $0.freeOffer == nil }
        }
        let needsFreeTierIDs = Set(needsFreeTier.map(\.id))
        let notOptedIn = idle.filter { entry in
            !entry.useForFallback && (wouldContribute.contains(entry.id) || needsFreeTierIDs.contains(entry.id))
        }
        let byID = Dictionary(registry.entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func original(_ list: [RegisteredKey]) -> [RegisteredKey] { list.compactMap { byID[$0.id] } }
        return (original(needsFreeTier), original(unsupported), original(notOptedIn))
    }
}
