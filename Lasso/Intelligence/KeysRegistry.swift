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

    /// Keychain account for this key's secret.
    var keychainAccount: String { "keys.registry.\(id).key" }

    /// A localhost/loopback endpoint needs no API key. Gemini is always remote.
    var isLocal: Bool { kind == .openAICompatible && KeysRegistry.isLocalURL(baseURL) }

    init(id: String = UUID().uuidString, name: String, baseURL: String,
         keyNotRequired: Bool, enabled: Bool = true, models: [RegistryModel] = [],
         kind: ConnectionKind = .openAICompatible) {
        self.id = id
        self.name = name
        self.baseURL = kind.fixedBaseURL ?? baseURL
        self.keyNotRequired = kind.alwaysRequiresKey ? false : keyNotRequired
        self.enabled = enabled
        self.models = models
        self.kind = kind
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        baseURL = try container.decode(String.self, forKey: .baseURL)
        keyNotRequired = try container.decode(Bool.self, forKey: .keyNotRequired)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        models = try container.decodeIfPresent([RegistryModel].self, forKey: .models) ?? []
        kind = try container.decodeIfPresent(ConnectionKind.self, forKey: .kind) ?? .openAICompatible
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
              var decoded = try? JSONDecoder().decode(KeysRegistry.self, from: data) else {
            return KeysRegistry()
        }
        // Connections have no on/off any more: every configured endpoint contributes its models at
        // once. A connection switched off by the old key-pill UI would otherwise stay invisible
        // forever, with no control left to bring it back — and `groups(for:)` would silently drop it
        // from every model picker. Heal it here, at the one point every reader goes through, and
        // write it back so the fix is permanent rather than per-process.
        if decoded.entries.contains(where: { !$0.enabled }) {
            for index in decoded.entries.indices { decoded.entries[index].enabled = true }
            decoded.save(to: store)
        }
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

    /// Models a connection serves, discovered through whichever protocol it speaks. One place, so
    /// adding a transport doesn't mean hunting down every discovery call site.
    static func discoverModels(for entry: RegisteredKey, apiKey: String) async -> [String] {
        switch entry.kind {
        case .gemini:
            return await GeminiAPI.availableModels(apiKey: apiKey)
        case .openAICompatible:
            guard let url = URL(string: entry.baseURL) else { return [] }
            return await OpenAICompatibleProvider.discoverModels(baseURL: url, apiKey: apiKey)
        }
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

    static func isLocalURL(_ urlString: String) -> Bool {
        let host = (URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines))?.host ?? "").lowercased()
        return host == "localhost" || host == "127.0.0.1" || host == "0.0.0.0" || host == "::1"
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

        // A pure embedding model isn't a chat model; everything else can serve language.
        if !(caps.contains(.embedding) && caps.count == 1) {
            caps.insert(.language)
        }
        if caps.isEmpty { caps.insert(.language) }
        return caps
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
