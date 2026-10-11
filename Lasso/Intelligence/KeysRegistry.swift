import Foundation

extension String {
    /// If the string starts with `prefix`, return the remainder as a Substring; else nil.
    func dropPrefixIfPresent(_ prefix: String) -> Substring? {
        hasPrefix(prefix) ? self.dropFirst(prefix.count) : nil
    }
}

/// A capability a model can serve. A single model may report several (e.g. gpt-4o →
/// [.language, .vision]). Used to filter the shared registry into each capability card's list.
enum ModelCapability: String, Codable, Sendable, CaseIterable {
    case language, vision, embedding
}

/// The wire protocol a connection speaks. This is the *transport*, chosen per connection — not a
/// separate model pool: connections of both kinds live in the same registry and their models merge
/// into one picker, so picking a model is still what selects the endpoint (see `KeysRegistry`).
enum ConnectionKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case openAICompatible
    case gemini

    var id: String { rawValue }

    var label: String {
        switch self {
        case .openAICompatible: "OpenAI-compatible"
        case .gemini: "Google Gemini"
        }
    }

    /// Gemini's endpoint is fixed by the provider, so the form never asks for one. OpenAI-compatible
    /// keeps its Base URL field — including for Google's own `/v1beta/openai/` shim, which stays a
    /// perfectly valid OpenAI-compatible connection.
    var hasEditableBaseURL: Bool { self == .openAICompatible }

    /// A connection of this kind always needs a credential.
    var alwaysRequiresKey: Bool { self == .gemini }

    /// Base URL to store when the user can't type one.
    var fixedBaseURL: String? { self == .gemini ? GeminiAPI.baseURL : nil }
}

/// One model advertised by (or manually added to) a registered key. `capabilities` drives which
/// card(s) the model appears in. Codable so the whole registry round-trips through UserDefaults as
/// JSON.
struct RegistryModel: Codable, Equatable, Sendable, Identifiable {
    var name: String
    var tag: String
    var capabilities: Set<ModelCapability>

    // What the endpoint's own model list reported, when it reported anything. nil always means "the
    // provider didn't say", never "no" — Groq and Gemini publish none of this, OpenRouter all of it.
    // Optional so registries saved before these existed decode unchanged.

    /// What the provider offers for free, from its pricing metadata or its documented free plan
    /// (`FreeTierRules`). nil = no rule covers this model, which the fallback pool treats as unknown.
    var freeOffer: FreeOffer?
    /// Produces text and nothing else — a zero-priced music model is not a chat fallback.
    var outputsOnlyText: Bool?
    var acceptsImages: Bool?
    var supportsTools: Bool?
    var contextTokens: Int?
    /// A router that forwards to a model of its own choosing. Its quality and capabilities can't be
    /// known ahead of the request, so it is never a fallback candidate.
    var isRouter: Bool?

    var id: String { name }

    init(name: String, tag: String = "", capabilities: Set<ModelCapability>? = nil) {
        self.name = name
        self.tag = tag
        self.capabilities = capabilities ?? KeysRegistry.inferCapabilities(forModelID: name)
    }
}

/// A single registered OpenAI-compatible endpoint (a "key"): a friendly name, its base URL, whether
/// it needs an API key, whether it's enabled (included in routing), and the models it exposes. The
/// API key *value* is never stored here — it lives in the Keychain under `keys.registry.<id>.key`.
struct RegisteredKey: Codable, Equatable, Sendable, Identifiable {
    var id: String                 // stable UUID string — routing/selection references this, not the name
    var name: String
    var baseURL: String
    var keyNotRequired: Bool
    var enabled: Bool
    var models: [RegistryModel]
    /// Which wire protocol to speak. Decoded leniently so registries written before native Gemini
    /// existed keep working — everything back then was OpenAI-compatible.
    var kind: ConnectionKind
    /// "This key is allowed to use the provider's free tier." Not a list of free models: which models
    /// that covers comes from the provider's own rules (`FreeOffer.freePlan`). Needed because Groq and
    /// Gemini expose no billing information, so nothing an API call returns can prove a key is on the
    /// free plan.
    var freeTier: Bool
    /// When `models` was last filled from the endpoint. nil = never discovered (or a pre-fallback save).
    var modelsCheckedAt: Date?
    /// "Lasso may send a request here when the user's own model is unavailable." Consent is per
    /// connection, not only the global Fallback switch: a free model still receives the conversation,
    /// and which providers may see it is the user's call, one connection at a time. Off by default and
    /// for every connection saved before it existed, a server on this Mac included.
    var useForFallback: Bool

    /// Keychain account for this key's secret.
    var keychainAccount: String { "keys.registry.\(id).key" }

    /// A localhost/loopback endpoint needs no API key. Gemini is always remote.
    var isLocal: Bool { kind == .openAICompatible && KeysRegistry.isLocalURL(baseURL) }

    init(id: String = UUID().uuidString, name: String, baseURL: String,
         keyNotRequired: Bool, enabled: Bool = true, models: [RegistryModel] = [],
         kind: ConnectionKind = .openAICompatible, freeTier: Bool = false,
         modelsCheckedAt: Date? = nil, useForFallback: Bool = false) {
        self.id = id
        self.name = name
        self.baseURL = kind.fixedBaseURL ?? baseURL
        self.keyNotRequired = kind.alwaysRequiresKey ? false : keyNotRequired
        self.enabled = enabled
        self.models = models
        self.kind = kind
        self.freeTier = freeTier
        self.modelsCheckedAt = modelsCheckedAt
        self.useForFallback = useForFallback
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        baseURL = try container.decode(String.self, forKey: .baseURL)
        keyNotRequired = try container.decode(Bool.self, forKey: .keyNotRequired)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        // Lists saved before `isChatModel` tagged speech and image models as chat models; correct them
        // here, where every reader loads them, instead of waiting for the next model refresh.
        models = (try container.decodeIfPresent([RegistryModel].self, forKey: .models) ?? []).map { model in
            guard !KeysRegistry.isChatModel(model.name) else { return model }
            var corrected = model
            corrected.capabilities.remove(.language)
            corrected.capabilities.remove(.vision)
            return corrected
        }
        kind = try container.decodeIfPresent(ConnectionKind.self, forKey: .kind) ?? .openAICompatible
        freeTier = try container.decodeIfPresent(Bool.self, forKey: .freeTier) ?? false
        modelsCheckedAt = try container.decodeIfPresent(Date.self, forKey: .modelsCheckedAt)
        useForFallback = try container.decodeIfPresent(Bool.self, forKey: .useForFallback) ?? false
    }
}

/// A grouped, capability-filtered view of the merged model list — one group per enabled key, plus a
/// synthetic "Manually added" group. Consumed by the model picker UI.
struct RegistryModelGroup: Identifiable, Equatable {
    var keyID: String        // "" for the Manually added group
    var name: String
    var models: [RegistryModel]
    var id: String { keyID.isEmpty ? "__manual__" : keyID }
}

/// The single, app-level registry of OpenAI-compatible keys shared by the Language, Image, and
/// Embedding model cards. There is exactly one of these; all three cards render *filtered views* of
/// the same merged model list (no per-card duplication).
///
/// Persistence: JSON in UserDefaults under `storeKey`. A `versionKey` flag records that the new-format
/// store exists — its absence on launch triggers the one-time clean-break migration off the old
/// per-service scheme.
struct KeysRegistry: Codable, Equatable, Sendable {
    var entries: [RegisteredKey]

    /// Synthetic group holding models the user typed by hand — they have no backing key, so they'd
    /// otherwise have nowhere to live in the merged structure.
    var manualModels: [RegistryModel]

    static let storeKey = "intelligence.keys.registry"
    static let versionKey = "intelligence.keys.registry.version"
    static let noticeKey = "intelligence.keys.registry.migrationNoticePending"
    static let currentVersion = 1

    init(entries: [RegisteredKey] = [], manualModels: [RegistryModel] = []) {
        self.entries = entries
        self.manualModels = manualModels
    }

    // MARK: - Load / save

    /// `store` is injectable so tests can round-trip through a scratch domain instead of the user's
    /// real settings.
    static func load(from store: UserDefaults = .standard) -> KeysRegistry {
        guard let data = store.data(forKey: storeKey),
              let decoded = try? JSONDecoder().decode(KeysRegistry.self, from: data) else {
            return KeysRegistry()
        }
        // `enabled` is the Connections sheet's on/off switch: off hides a connection's models from
        // every picker and stops routing, fallback and refresh from using it, without removing it.
        // (An earlier version had no switch and forced every connection back on here; the switch
        // brings it back, so off has to stick.)
        return decoded
    }

    func save(to store: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            store.set(data, forKey: Self.storeKey)
        }
        store.set(Self.currentVersion, forKey: Self.versionKey)
    }

    // MARK: - Lookup helpers

    func key(withID id: String) -> RegisteredKey? { entries.first { $0.id == id } }

    /// The enabled key that exposes `modelName` (first match wins — the same-named model under two
    /// keys is kept as two separate group entries, and selection carries the exact key id, so a
    /// name-only lookup is only a fallback when the id is unknown).
    func enabledKey(exposingModel modelName: String) -> RegisteredKey? {
        entries.first { $0.enabled && $0.models.contains { $0.name == modelName } }
    }

    /// Grouped, capability-filtered merged list: one group per enabled key that has at least one
    /// matching model, then the "Manually added" group. Empty groups are dropped.
    func groups(for capability: ModelCapability) -> [RegistryModelGroup] {
        var out: [RegistryModelGroup] = []
        for entry in entries where entry.enabled {
            let matched = entry.models.filter { $0.capabilities.contains(capability) }
            if !matched.isEmpty {
                out.append(RegistryModelGroup(keyID: entry.id, name: entry.name, models: matched))
            }
        }
        let matchedManual = manualModels.filter { $0.capabilities.contains(capability) }
        if !matchedManual.isEmpty {
            out.append(RegistryModelGroup(keyID: "", name: "Manually added", models: matchedManual))
        }
        return out
    }

    /// Flat list of (keyID, model) pairs for a capability — used to pick a fallback selection when the
    /// current one becomes unreachable. keyID is "" for manual models.
    func flatSelectable(for capability: ModelCapability) -> [(keyID: String, model: RegistryModel)] {
        groups(for: capability).flatMap { grp in grp.models.map { (grp.keyID, $0) } }
    }

    var hasAnyEnabledKey: Bool { entries.contains { $0.enabled } }

    /// Models a connection serves, discovered through whichever protocol it speaks, with whatever the
    /// endpoint reports about each (pricing, modalities, tools, context). One place, so adding a
    /// transport doesn't mean hunting down every discovery call site.
    ///
    /// nil means the request failed — distinct from an endpoint that genuinely lists nothing, so a
    /// background refresh can keep the last good list instead of wiping it on a network blip.
    static func discoverModels(for entry: RegisteredKey, apiKey: String) async -> [RegistryModel]? {
        guard !PrivacyMode.localOnly || entry.isLocal else { return nil }
        let models: [RegistryModel]?
        switch entry.kind {
        case .gemini:
            models = await GeminiAPI.discoverModels(apiKey: apiKey)
        case .openAICompatible:
            guard let url = URL(string: entry.baseURL) else { return nil }
            models = await OpenAICompatibleProvider.discoverModels(baseURL: url, apiKey: apiKey)
        }
        return models.map { FreeTierRules.annotate($0, for: entry) }
    }

    /// Parse an OpenAI-style `GET /models` body. Every field beyond `id` is optional on the wire:
    /// OpenRouter sends `pricing`, `architecture` and `supported_parameters`; Groq sends
    /// `context_window`; a bare server sends ids only. Absent stays nil. Internal for tests.
    static func parseOpenAIModelList(_ data: Data) -> [RegistryModel]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["data"] as? [[String: Any]] else { return nil }
        return list.compactMap { entry -> RegistryModel? in
            guard let id = entry["id"] as? String else { return nil }
            var model = RegistryModel(name: id)
            if let pricing = entry["pricing"] as? [String: Any] {
                // Only the flat string prices count; `overrides` is a list of long-prompt tiers.
                let prices = pricing.values.compactMap { value -> Decimal? in
                    guard let string = value as? String else { return nil }
                    return Decimal(string: string, locale: Locale(identifier: "en_US_POSIX"))
                }
                // Every price exactly zero is free for everyone. A negative price is OpenRouter's
                // "variable" marker (its auto-router), so it counts as priced.
                if pricing["prompt"] != nil, pricing["completion"] != nil, !prices.isEmpty {
                    model.freeOffer = prices.allSatisfy { $0 == 0 } ? .always : .never
                }
            }
            if let arch = entry["architecture"] as? [String: Any] {
                if let outputs = arch["output_modalities"] as? [String] {
                    model.outputsOnlyText = outputs == ["text"]
                }
                if let inputs = arch["input_modalities"] as? [String] {
                    model.acceptsImages = inputs.contains("image")
                }
            }
            if let params = entry["supported_parameters"] as? [String] {
                model.supportsTools = params.contains("tools")
            }
            for key in ["context_length", "context_window", "max_context_length"] {
                if let n = entry[key] as? Int, n > 0 { model.contextTokens = n; break }
            }
            return model
        }.sorted { $0.name < $1.name }
    }

    /// Whether a connection answers right now — the Connections row's test, per protocol.
    static func reachable(_ entry: RegisteredKey, apiKey: String) async -> Bool {
        if !entry.keyNotRequired, apiKey.isEmpty { return false }
        switch entry.kind {
        case .gemini:
            return !(await GeminiAPI.availableModels(apiKey: apiKey)).isEmpty
        case .openAICompatible:
            guard let url = URL(string: entry.baseURL) else { return false }
            let models = await OpenAICompatibleProvider.availableModels(baseURL: url, apiKey: apiKey)
            return !models.isEmpty || entry.isLocal
        }
    }

    // MARK: - Static utilities

    /// This Mac only (loopback). Drives the privacy badge ("on this Mac") and the no-key default.
    static func isLocalURL(_ urlString: String) -> Bool {
        let host = host(of: urlString)
        return host == "localhost" || host == "127.0.0.1" || host == "0.0.0.0" || host == "::1"
    }

    /// This Mac or a network the user is on: loopback, the RFC 1918 ranges, link-local, carrier-grade
    /// NAT (100.64/10, which Tailscale uses), IPv6 unique-local and link-local, and names only a local
    /// resolver answers: a single-label host ("mac-studio"), mDNS `.local`, Tailscale's `.ts.net`, and
    /// the home/private-use suffixes `.home.arpa` (RFC 8375), `.lan`, and `.internal`.
    ///
    /// Not "local" in the privacy badge's sense (the request does leave this Mac), but a server on the
    /// user's own network is still their machine. For the free-model fallback that difference decides
    /// everything: a request the user kept in-house mustn't be retried on a cloud provider.
    static func isPrivateNetworkURL(_ urlString: String) -> Bool {
        var host = host(of: urlString)
        guard !host.isEmpty else { return false }
        if let zone = host.firstIndex(of: "%") { host = String(host[..<zone]) }   // fe80::1%en0
        if host == "localhost" { return true }
        if [".local", ".ts.net", ".home.arpa", ".lan", ".internal"].contains(where: host.hasSuffix) { return true }
        // A dotless name can only come from the local resolver's search domain. A letter is required so
        // a decimal-encoded IPv4 ("http://134744072") isn't mistaken for one.
        if !host.contains("."), !host.contains(":"), host.contains(where: \.isLetter) { return true }
        if host.contains(":") {
            // IPv4-mapped IPv6 ("::ffff:192.168.1.5") is the IPv4 address it carries.
            if host.contains("."), let v4 = host.split(separator: ":").last { return isPrivateIPv4(String(v4)) }
            if host == "::1" { return true }
            let first = host.split(separator: ":", omittingEmptySubsequences: false).first ?? ""
            guard !first.isEmpty, let hextet = UInt16(first, radix: 16) else { return false }
            return hextet & 0xFE00 == 0xFC00      // fc00::/7, unique local
                || hextet & 0xFFC0 == 0xFE80      // fe80::/10, link local
        }
        return isPrivateIPv4(host)
    }

    private static func isPrivateIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false).compactMap { UInt8($0) }
        guard parts.count == 4 else { return false }
        let (a, b) = (parts[0], parts[1])
        return a == 127                                  // loopback
            || parts == [0, 0, 0, 0]
            || a == 10                                   // 10/8
            || (a == 172 && (16...31).contains(b))       // 172.16/12
            || (a == 192 && b == 168)                    // 192.168/16
            || (a == 169 && b == 254)                    // 169.254/16, link local
            || (a == 100 && (64...127).contains(b))      // 100.64/10, carrier-grade NAT
    }

    private static func host(of urlString: String) -> String {
        (URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines))?.host ?? "").lowercased()
    }

    /// Infer a model's capabilities from its id, since the `/models` endpoint doesn't report them.
    /// Defaults to `[.language]`. Embedding/vision are additive where the name signals them.
    static func inferCapabilities(forModelID id: String) -> Set<ModelCapability> {
        let lower = id.lowercased()
        var caps: Set<ModelCapability> = []

        let embeddingSignals = ["embed", "bge", "gte-", "e5-", "text-embedding", "nomic-embed"]
        if embeddingSignals.contains(where: lower.contains) {
            caps.insert(.embedding)
        }

        let visionSignals = ["-vl", "vl-", "vision", "gpt-4o", "gpt-4.1", "gpt-4-turbo",
                             "llava", "moondream", "qwen2-vl", "qwen2.5-vl", "pixtral",
                             "gemini", "claude-3", "claude-sonnet", "claude-opus", "internvl"]
        if visionSignals.contains(where: lower.contains) {
            caps.insert(.vision)
        }

        // A pure embedding model isn't a chat model, and neither is one that transcribes, speaks,
        // draws or classifies; everything else can serve language.
        if !(caps.contains(.embedding) && caps.count == 1), isChatModel(id) {
            caps.insert(.language)
        }
        if caps.isEmpty, isChatModel(id) { caps.insert(.language) }
        if !isChatModel(id) { caps.remove(.vision) }
        return caps
    }

    /// False for models `/chat/completions` rejects: speech-to-text (Whisper, `-transcribe`), speech
    /// (`-tts`, Orpheus, Gemini native audio), image and video generators, and guard/moderation
    /// classifiers. Groq's Whisper sat in the Language picker; picked, every message failed with "does
    /// not support chat completions". Groq and Gemini report no modalities, so the id decides.
    static func isChatModel(_ id: String) -> Bool {
        let lower = id.lowercased()
        let nonChat = ["whisper", "transcribe", "-tts", "tts-", "orpheus", "native-audio", "prompt-guard",
                       "moderation", "-image", "gpt-image", "dall-e", "flux", "imagen", "stable-diffusion",
                       "sdxl", "recraft", "seedream", "veo-", "lyria"]
        return !nonChat.contains { lower.contains($0) }
    }

    /// Delete every pre-registry key (UserDefaults + Keychain) from the old per-service scheme. Called
    /// once on the clean-break migration so the old settings don't linger orphaned.
    static func purgeLegacyStore() {
        let d = UserDefaults.standard
        let legacyServices = ["openai", "groq", "openrouter", "custom"]
        for s in legacyServices {
            d.removeObject(forKey: "intelligence.openai.svc.\(s).model")
            d.removeObject(forKey: "intelligence.openai.svc.\(s).context")
            d.removeObject(forKey: "intelligence.vision.openai.svc.\(s).model")
            d.removeObject(forKey: "intelligence.embedding.openai.svc.\(s).model")
            Keychain.delete("openai.svc.\(s).key")
        }
        for defaultsKey in [
            "intelligence.openai.service", "intelligence.openai.customBaseURL",
            "intelligence.openai.baseURL", "intelligence.openai.model",
            "intelligence.vision.openai.service", "intelligence.vision.openai.customBaseURL",
            "intelligence.vision.openai.baseURL", "intelligence.vision.openai.model",
            "intelligence.embedding.openai.service", "intelligence.embedding.openai.customBaseURL",
            "intelligence.embedding.openai.baseURL", "intelligence.embedding.openAIModel",
        ] {
            d.removeObject(forKey: defaultsKey)
        }
        for account in ["openai.apiKey", "vision.openai.apiKey", "embedding.openai.apiKey"] {
            Keychain.delete(account)
        }
    }

    /// One-time clean-break migration. Runs when the new store's version flag is absent: purges the
    /// old per-service keys and arms a one-time in-app notice telling the user to re-add their
    /// language-model connection under Intelligence.
    ///
    /// Returns true if the migration just ran (so callers can persist a fresh empty registry).
    @discardableResult
    static func migrateIfNeeded() -> Bool {
        let d = UserDefaults.standard
        guard d.object(forKey: versionKey) == nil else { return false }

        // Only bother the user with the notice if they actually had a cloud/custom connection worth
        // re-adding — a fresh install has nothing to lose.
        let hadConnection = d.string(forKey: "intelligence.openai.model")?.isEmpty == false
            || ["openai", "groq", "openrouter", "custom"].contains {
                d.string(forKey: "intelligence.openai.svc.\($0).model")?.isEmpty == false
            }

        purgeLegacyStore()
        KeysRegistry().save()   // writes the version flag so this never runs again
        if hadConnection { d.set(true, forKey: noticeKey) }
        return true
    }
}
