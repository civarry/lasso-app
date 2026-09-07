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

    // MARK: - The old on/off flag

    /// Connections used to have an on/off pill. That control is gone — every configured endpoint
    /// contributes its models at once — but a registry written by the old UI can still carry
    /// `enabled == false`, and `groups(for:)` skips those. Left alone, such a connection is invisible
    /// in every picker with no control left to bring it back.
    @Test func loadReEnablesAConnectionTheOldUISwitchedOff() {
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

            #expect(allEnabled(loaded))
            // The healed value has to reach the model list, not just the struct.
            #expect(loaded.groups(for: .language).map(\.name) == ["Groq", "AIStudio"])
        }
    }

    /// Healing only the in-memory copy is what made Settings claim three connections while the chat
    /// switcher showed one. The fix has to be written back, so every reader agrees.
    @Test func theReEnableIsPersistedNotJustInMemory() {
        withScratchDefaults { defaults in
            let registry = KeysRegistry(entries: [
                RegisteredKey(name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1",
                              keyNotRequired: false, enabled: false,
                              models: [RegistryModel(name: "openai/gpt-5")]),
            ])
            registry.save(to: defaults)

            _ = KeysRegistry.load(from: defaults)          // heals + writes back
            let reread = KeysRegistry.load(from: defaults) // a second, independent reader

            #expect(allEnabled(reread))
            #expect(!reread.groups(for: .language).isEmpty)
        }
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
