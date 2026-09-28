import Testing
import Foundation
@testable import Lasso

/// The connection registry. The cases here are the ones that silently drop a user's endpoint out of
/// every model picker rather than failing loudly, which is exactly the class of bug that survives a
/// green build.
struct KeysRegistryTests {

    /// Run a body against a scratch `UserDefaults` domain so a test never touches real settings.
    private func withScratchDefaults(_ body: (UserDefaults) -> Void) {
        let suite = "KeysRegistryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        body(defaults)
    }

    private func allEnabled(_ registry: KeysRegistry) -> Bool {
        !registry.entries.contains { !$0.enabled }
    }

    // MARK: - On/off

    /// A connection can be switched off to hide its models without removing it. (An earlier version had
    /// no switch and forced every connection back on at load; with the switch back, off has to stick.)
    @Test func aSwitchedOffConnectionStaysOffAndKeepsItsModels() {
        withScratchDefaults { defaults in
            let registry = KeysRegistry(entries: [
                RegisteredKey(name: "Groq", baseURL: "https://api.groq.com/openai/v1",
                              keyNotRequired: false, enabled: false,
                              models: [RegistryModel(name: "llama-4-scout")]),
                RegisteredKey(name: "AIStudio", baseURL: "https://example.com/v1",
                              keyNotRequired: false, enabled: true,
                              models: [RegistryModel(name: "gemini-3.6-flash")]),
            ])
            registry.save(to: defaults)

            let loaded = KeysRegistry.load(from: defaults)
            let groq = try? #require(loaded.entries.first { $0.name == "Groq" })
            #expect(groq?.enabled == false)
            #expect(groq?.models.map(\.name) == ["llama-4-scout"])          // kept, just hidden
            #expect(loaded.groups(for: .language).map(\.name) == ["AIStudio"])
            #expect(loaded.enabledKey(exposingModel: "llama-4-scout") == nil)
        }
    }

    @Test func switchingItBackOnRestoresItsModels() {
        withScratchDefaults { defaults in
            var registry = KeysRegistry(entries: [
                RegisteredKey(name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1",
                              keyNotRequired: false, enabled: false,
                              models: [RegistryModel(name: "openai/gpt-5")]),
            ])
            registry.save(to: defaults)
            #expect(KeysRegistry.load(from: defaults).groups(for: .language).isEmpty)

            registry.entries[0].enabled = true
            registry.save(to: defaults)
            #expect(KeysRegistry.load(from: defaults).groups(for: .language).map(\.name) == ["OpenRouter"])
        }
    }

    /// Switching a provider off also stops Lasso contacting it: the daily model-list refresh skips it,
    /// and an old list on a switched-off connection doesn't make the registry "stale".
    @MainActor
    @Test func theRefresherNeverContactsASwitchedOffConnection() async {
        let suite = "KeysRegistryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        KeysRegistry(entries: [
            RegisteredKey(name: "Off", baseURL: "https://off.example.com/v1", keyNotRequired: true, enabled: false),
            RegisteredKey(name: "On", baseURL: "https://on.example.com/v1", keyNotRequired: true, enabled: true,
                          modelsCheckedAt: Date()),
        ]).save(to: defaults)

        let asked = Asked()
        let refresher = FreeModelRefresher(store: defaults, discover: { entry, _ in
            await asked.add(entry.name); return [RegistryModel(name: "m")]
        }, keyValue: { _ in "" })
        #expect(!refresher.isStale, "a never-checked switched-off connection made the registry stale")
        await refresher.refresh()
        #expect(await asked.names == ["On"])
    }

    // MARK: - Aggregation

    /// The model list is the union of every connection's models, one group each — the property the
    /// whole omni-router design rests on.
    @Test func groupsAggregateAcrossEveryConnection() {
        withScratchDefaults { defaults in
            let registry = KeysRegistry(entries: [
                RegisteredKey(name: "Google", baseURL: "https://a/v1", keyNotRequired: false,
                              models: [RegistryModel(name: "gemini-3.6-flash"),
                                       RegistryModel(name: "gemini-3.6-pro")]),
                RegisteredKey(name: "Groq", baseURL: "https://b/v1", keyNotRequired: false,
                              models: [RegistryModel(name: "llama-4-scout")]),
            ])
            registry.save(to: defaults)

            let groups = KeysRegistry.load(from: defaults).groups(for: .language)

            #expect(groups.count == 2)
            #expect(groups.flatMap { $0.models.map(\.name) }.count == 3)
        }
    }

    /// Two connections can serve the same model name; selection carries the key id so the request
    /// still reaches the right endpoint.
    @Test func sameModelNameUnderTwoConnectionsStaysDistinct() {
        withScratchDefaults { defaults in
            let shared = RegistryModel(name: "gpt-4o")
            let registry = KeysRegistry(entries: [
                RegisteredKey(name: "Work", baseURL: "https://work/v1", keyNotRequired: false,
                              models: [shared]),
                RegisteredKey(name: "Personal", baseURL: "https://personal/v1", keyNotRequired: false,
                              models: [shared]),
            ])
            registry.save(to: defaults)

            let flat = KeysRegistry.load(from: defaults).flatSelectable(for: .language)

            #expect(flat.count == 2)
            #expect(Set(flat.map(\.keyID)).count == 2)
        }
    }

    // MARK: - Capability filtering

    /// A pure embedding model isn't a chat model, so it must not reach the Language picker.
    @Test func embeddingOnlyModelsStayOutOfTheLanguageList() {
        let caps = KeysRegistry.inferCapabilities(forModelID: "text-embedding-3-small")
        #expect(caps == [.embedding])
        #expect(!caps.contains(.language))
    }
}

/// The native Gemini transport. A connection's `kind` decides the wire format while its models stay
/// in the one shared pool, so the cases that matter are the ones where the two could diverge.
struct GeminiProviderTests {

    // MARK: - Schema migration

    /// A registry written before native Gemini existed has no `kind` field at all. Decoding must not
    /// fail, and must not silently reclassify an existing endpoint as something it isn't.
    @Test func aRegistryWrittenBeforeGeminiDecodesAsOpenAICompatible() throws {
        let legacy = """
        {"entries":[{"id":"A1","name":"Groq","baseURL":"https://api.groq.com/openai/v1",
        "keyNotRequired":false,"enabled":true,"models":[]}],"manualModels":[]}
        """
        let registry = try JSONDecoder().decode(KeysRegistry.self, from: Data(legacy.utf8))

        #expect(registry.entries.count == 1)
        #expect(registry.entries[0].kind == .openAICompatible)
        #expect(registry.entries[0].baseURL == "https://api.groq.com/openai/v1")
    }

    /// Google's OpenAI compatibility layer must stay an ordinary OpenAI-compatible connection — the
    /// native provider is an addition, not a replacement, and pointing one at the other's endpoint is
    /// exactly what this change must not do.
    @Test func googlesOpenAICompatibilityLayerStaysOpenAICompatible() {
        let entry = RegisteredKey(name: "AIStudio",
                                  baseURL: "https://generativelanguage.googleapis.com/v1beta/openai/",
                                  keyNotRequired: false)
        #expect(entry.kind == .openAICompatible)
        #expect(entry.kind.hasEditableBaseURL)
    }

    /// A native connection supplies its own endpoint and always needs a key, so the form can't leave
    /// it half-configured.
    @Test func aNativeConnectionFixesItsEndpointAndRequiresAKey() {
        let entry = RegisteredKey(name: "Gemini", baseURL: "", keyNotRequired: true, kind: .gemini)

        #expect(entry.baseURL == GeminiAPI.baseURL)
        #expect(!entry.keyNotRequired)
        #expect(!entry.kind.hasEditableBaseURL)
        #expect(!entry.isLocal)
    }

    // MARK: - Native wire format

    /// Ids arrive fully qualified from `/models`, and the same model may already be stored bare from
    /// the compatibility layer. Both have to build one URL, not `models/models/…`.
    @Test func modelIDsNormalizeWhicheverFormTheyArriveIn() {
        #expect(GeminiAPI.bareModelID("models/gemini-3.6-flash") == "gemini-3.6-flash")
        #expect(GeminiAPI.bareModelID("gemini-3.6-flash") == "gemini-3.6-flash")

        let qualified = GeminiAPI.endpoint(model: "models/gemini-3.6-flash", method: "generateContent")
        let bare = GeminiAPI.endpoint(model: "gemini-3.6-flash", method: "generateContent")
        #expect(qualified == bare)
        #expect(qualified?.absoluteString
                == "\(GeminiAPI.baseURL)/models/gemini-3.6-flash:generateContent")
    }

    /// Gemini takes the system prompt out of band and calls the assistant "model" — the two places an
    /// OpenAI-shaped message array silently means the wrong thing.
    @Test func turnsTranslateIntoGeminiRolesWithSystemHoisted() {
        let wire = GeminiAPI.wire([
            ChatTurn(role: .system, text: "be terse"),
            ChatTurn(role: .user, text: "hello"),
            ChatTurn(role: .assistant, text: "hi"),
        ], fallbackSystem: "unused")

        #expect(wire.system == "be terse")
        #expect(wire.contents.count == 2)                       // the system turn is not a content
        #expect(wire.contents[0]["role"] as? String == "user")
        #expect(wire.contents[1]["role"] as? String == "model")  // not "assistant"
    }

    /// Images are `inlineData` parts, not OpenAI `image_url` data URLs.
    @Test func imagesBecomeInlineDataParts() {
        let wire = GeminiAPI.wire([ChatTurn(role: .user, text: "what is this?",
                                            imageBase64s: ["QUJD"])],
                                  fallbackSystem: "sys")
        let parts = wire.contents.first?["parts"] as? [[String: Any]]

        #expect(parts?.count == 2)
        #expect(parts?[0]["text"] as? String == "what is this?")
        let inline = parts?[1]["inlineData"] as? [String: Any]
        #expect(inline?["mimeType"] as? String == "image/jpeg")
        #expect(inline?["data"] as? String == "QUJD")
        #expect(parts?[1]["image_url"] == nil)
    }

    /// A turn with no text and no image would otherwise send an empty `parts` array, which Gemini
    /// rejects outright.
    @Test func emptyTurnsAreDropped() {
        let wire = GeminiAPI.wire([ChatTurn(role: .user, text: "")], fallbackSystem: "sys")
        #expect(wire.contents.isEmpty)
    }

    /// Responses nest the text two levels deeper than OpenAI's, and a chunk can legitimately carry
    /// none (a safety-only or finish-reason frame).
    @Test func responseTextIsReadFromCandidateParts() {
        let json: [String: Any] = ["candidates": [
            ["content": ["role": "model", "parts": [["text": "one "], ["text": "two"]]]],
        ]]
        #expect(GeminiAPI.text(in: json) == "one two")
        #expect(GeminiAPI.text(in: ["candidates": []]).isEmpty)
        #expect(GeminiAPI.text(in: [:]).isEmpty)
    }
}

private actor Asked {
    var names: [String] = []
    func add(_ name: String) { names.append(name) }
}
