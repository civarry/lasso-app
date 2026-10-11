import Foundation

// A. Free-model discovery: what each provider says (or documents) about which of its models cost
// nothing. This is the only place that knows provider names. Everything downstream works on the
// normalized `RegistryModel.freeOffer` it writes, so adding a provider means adding a rule here, not
// touching the pool or the fallback loop.

/// What a provider offers for free, normalized. Stored on each discovered model.
enum FreeOffer: String, Codable, Sendable {
    /// Priced at zero for everyone (OpenRouter lists these with every price "0").
    case always
    /// Included in the provider's free plan: free only when the connection's key is on that plan,
    /// which the provider's API can't reveal, so it takes the connection's Free tier switch.
    case freePlan
    /// Priced, or documented as not available on the free plan.
    case never
}

/// A provider whose free offering Lasso has a rule for. Identified by where the connection points.
enum FreeTierProvider: Equatable, Sendable {
    case openRouter
    case groq
    case google

    static func identify(kind: ConnectionKind, baseURL: String) -> FreeTierProvider? {
        if kind == .gemini { return .google }
        let host = (URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines))?.host ?? "").lowercased()
        // The domain or a subdomain of it, never a host that merely ends in the same letters
        // ("notgroq.com" is someone else's server, and its models are not Groq's free plan).
        func within(_ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }
        if within("openrouter.ai") { return .openRouter }
        if within("groq.com") { return .groq }
        if host == "generativelanguage.googleapis.com" { return .google }
        return nil
    }

    static func identify(_ entry: RegisteredKey) -> FreeTierProvider? {
        identify(kind: entry.kind, baseURL: entry.baseURL)
    }

    /// Whether the connection form offers the Free tier switch. OpenRouter prices every model in its
    /// own list, so a switch there would have nothing to decide.
    var hasFreePlanSwitch: Bool { self != .openRouter }

    var displayName: String {
        switch self {
        case .openRouter: "OpenRouter"
        case .groq: "Groq"
        case .google: "Google"
        }
    }
}

enum FreeTierRules {
    /// Fill in `freeOffer` (and drop non-chat models out of chat eligibility) for a model list.
    /// Models the rule doesn't cover keep `freeOffer == nil`, which the pool treats as unknown.
    ///
    /// Runs at discovery and again every time the pool reads the registry, so a rule shipped in an
    /// update applies to lists fetched before it, without waiting for a refresh. That makes it
    /// idempotent by design: each rule sets fields from the model id alone, and never overwrites what
    /// the provider itself reported (OpenRouter's `freeOffer` comes from its `pricing` field, which only
    /// the list parser sees).
    static func annotate(_ models: [RegistryModel], for entry: RegisteredKey) -> [RegistryModel] {
        let provider = FreeTierProvider.identify(entry)
        return models.map { model in
            var model = markNonChat(model)
            switch provider {
            case .openRouter?:
                // The offer is already set from OpenRouter's `pricing` field by the list parser, which
                // only ever writes `always` or `never`. A `freePlan` is a leftover from a rule for the
                // provider this connection pointed at before.
                if model.freeOffer == .freePlan { model.freeOffer = nil }
                if model.name.hasPrefix("openrouter/") { model.isRouter = true }
            case .groq?:
                model = groq(model)
            case .google?:
                model = google(model)
            case nil:
                // No rule: every model stays unknown. Only a rule sets `freePlan`, so one here is left
                // over from a provider the connection pointed at before and must not keep it "free".
                // Offers from the provider's own pricing (`always` / `never`) are kept.
                if model.freeOffer == .freePlan { model.freeOffer = nil }
            }
            return model
        }
    }

    /// Safety classifiers, moderation and guard models answer "safe/unsafe", not the user. Seen in the
    /// live lists: OpenRouter's `nvidia/nemotron-3.5-content-safety:free` (zero-priced, accepts images)
    /// and Groq's `meta-llama/llama-prompt-guard-2-*`.
    private static func markNonChat(_ model: RegistryModel) -> RegistryModel {
        var model = model
        let lower = model.name.lowercased()
        if ["guard", "safety", "moderation", "classifier", "rerank", "embed"].contains(where: lower.contains) {
            model.outputsOnlyText = false
        }
        return model
    }

    // MARK: Groq

    /// Groq's billing FAQ: the Free tier carries no usage charges ("Any usage-based charges stop
    /// immediately" on returning to it), and paid usage needs a payment method on the Developer tier.
    /// So on a free-plan key every model Groq serves is free. Speech, TTS and guard models are not chat
    /// models and never act as a chat fallback. Source: console.groq.com/docs/billing-faqs, 2026-09-15.
    private static func groq(_ model: RegistryModel) -> RegistryModel {
        var model = model
        model.freeOffer = .freePlan
        let lower = model.name.lowercased()
        if ["whisper", "orpheus", "tts"].contains(where: lower.contains) {
            model.outputsOnlyText = false
        }
        // Compound (`groq/compound`, `groq/compound-mini`, the older `compound-beta`) is an agentic
        // system that picks models and runs tools of its own, not a model: what answers can't be known
        // ahead of the request, the same reason OpenRouter's routers are left out.
        if lower.hasPrefix("groq/compound") || lower.hasPrefix("compound-") { model.isRouter = true }
        return model
    }

    // MARK: Google (Gemini API, native or through its OpenAI-compatible endpoint)

    /// The Gemini API pricing page, per model, "Free Tier: Free of charge" versus "Not available",
    /// restricted to text-generation models. Anything not listed stays unknown until this table is
    /// updated: a new model is never assumed free. Source: ai.google.dev/gemini-api/docs/pricing,
    /// 2026-09-15.
    static let googleFreePlanChatModels: Set<String> = [
        "gemini-3.8-flash", "gemini-3.7-flash", "gemini-3.6-flash", "gemini-3.5-flash",
        "gemini-3.5-flash-lite", "gemini-3.1-flash-lite", "gemini-3-flash-preview",
        "gemini-2.5-pro", "gemini-2.5-flash", "gemini-2.5-flash-lite",
    ]
    static let googlePaidOnlyModels: Set<String> = [
        "gemini-3.1-pro-preview", "gemini-3.1-pro-preview-customtools",
        "gemini-3.1-flash-image", "gemini-3.1-flash-lite-image", "gemini-3-pro-image",
        "gemini-2.5-flash-image", "gemini-2.5-pro-preview-tts", "gemini-omni-1.1-flash",
        "gemini-omni-flash-preview", "gemini-2.5-computer-use-preview-10-2025",
    ]
    /// Listed as free on the pricing page but not chat models (speech, live audio, embeddings,
    /// robotics), so they must not become a chat fallback.
    private static let googleNonChatSignals = ["tts", "live", "transcribe", "native-audio", "embedding",
                                               "robotics", "computer-use", "image", "veo", "lyria", "imagen"]

    private static func google(_ model: RegistryModel) -> RegistryModel {
        var model = model
        let id = GeminiAPI.bareModelID(model.name).lowercased()
        if googleNonChatSignals.contains(where: id.contains) { model.outputsOnlyText = false }
        if googlePaidOnlyModels.contains(id) {
            model.freeOffer = .never
        } else if googleFreePlanChatModels.contains(id) || id.hasPrefix("gemma-4") {
            // "Gemma 4: Free of charge" on the same page.
            model.freeOffer = .freePlan
        } else {
            // Google's lists carry no pricing, so any offer on a Google model came from this table. A
            // model dropped from it in an update must stop being free now, not at the next refresh.
            model.freeOffer = nil
        }
        return model
    }
}
