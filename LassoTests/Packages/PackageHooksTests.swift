import Foundation
import Testing
@testable import Lasso

/// The package hooks (docs/PACKAGE-HOOKS.md): `source/1` gets the turn and answers a status, Lasso keeps
/// its limits; `describe/1` writes What's in it; Go back restores the previous version. Each check is
/// one of the spec's verification rows (V1 to V11).
@MainActor
@Suite(.serialized)
struct PackageHooksTests {
    /// Saves what it got to its data folder, then answers by what the message asks for.
    static let script = #"""
    #!/usr/bin/env python3
    import json, os, sys
    data = json.load(sys.stdin)
    open(os.path.join(os.environ["HOME"], "last.json"), "w").write(json.dumps(data))
    if data.get("hook") == "describe/1":
        print(json.dumps({"about": "pricing, roadmap, launch plans", "words": ["seat", "tier"]})); sys.exit()
    m = (data.get("searchFor") or data.get("message", "")).lower()
    folder = data["settings"]["notes"]
    hit = {"title": "pricing", "url": "file://" + os.path.join(folder, "pricing.md"), "snippet": "Enterprise is per seat, 12 dollars."}
    if "junk" in m:
        print(json.dumps({"status": "found", "results": [{"title": "junk %d" % i, "url": "file:///tmp/j%d.md" % i, "snippet": "x" * 500} for i in range(50)]}))
    elif "frozendcit" in m:
        print(json.dumps({"status": "nothing", "results": [], "ask": "frozendict"}))
    elif "weather" in m:
        print(json.dumps({"status": "irrelevant", "results": []}))
    elif "last week" in m and "nothing" in m:
        print(json.dumps({"status": "nothing", "results": [], "note": "No notes dated last week."}))
    else:
        print(json.dumps({"status": "found", "results": [hit]}))
    """#

    static func manifest(version: String = "1.0.0", ranks: Bool = true) -> String {
        """
        {"lasso": 1, "id": "my-notes", "version": "\(version)", "name": "My notes", "summary": "Searches a notes folder.", "author": "Me",
         "settings": [{"id": "notes", "label": "Notes folder", "kind": "folder"}],
         "commands": [{"id": "search", "title": "My notes", "surfaces": ["search"], "input": ["query"], "output": "results",
                       "hook": "source/1", "ranks": \(ranks),
                       "run": {"script": {"path": "scripts/search.py", "timeout": 5}}, "test": {"query": "x"}},
                      {"id": "describe", "title": "What's in it", "hook": "describe/1", "run": {"script": {"path": "scripts/search.py"}}}]}
        """
    }

    private func withSource(_ body: (ChatController, PackageStore, LassoPackage) async throws -> Void) async throws {
        let name = "lasso-hooks-\(UUID().uuidString.prefix(6))"
        let base = FileManager.default.temporaryDirectory.appending(path: name, directoryHint: .isDirectory)
        let notes = base.appending(path: "notes", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        try "# Pricing\nEnterprise is per seat, 12 dollars.".write(to: notes.appending(path: "pricing.md"), atomically: true, encoding: .utf8)
        let real = PackageStore.shared
        let store = PackageStore(root: base.appending(path: "Packages"), defaults: UserDefaults(suiteName: name)!)
        PackageStore.shared = store
        let intelligence = IntelligenceCoordinator.shared
        let preferred = intelligence.preferred
        intelligence.preferred = .mlx
        defer {
            intelligence.preferred = preferred
            SourcePreferences.forget("my-notes")
            PackageStore.shared = real; real.reload()
            try? FileManager.default.removeItem(at: base)
        }
        let package = try store.install(Data(Self.manifest().utf8), files: ["scripts/search.py": Data(Self.script.utf8)], origin: .file)
        store.setValue(notes.path, package.id, package.setting("notes")!)
        SourcePreferences.setAbout("pricing, roadmap, decisions, weather", "my-notes")
        SourcePreferences.setWords([], "my-notes")
        SourcePreferences.setUse(.automatically, "my-notes")
        SourcePreferences.resetAllowed("my-notes")
        let chat = ChatController.shared
        chat.newChat()
        let conversation = chat.active.id
        defer { chat.close(conversation) }
        try await body(chat, store, package)
    }

    private func ask(_ chat: ChatController, _ text: String, mentioned: [String] = []) async -> (evidence: String?, message: ChatMessage?) {
        chat.active.messages.append(ChatMessage(role: .user, text: text))
        let reply = ChatMessage(role: .assistant, text: "", isStreaming: true)
        chat.active.messages.append(reply)
        let looked = await chat.lookInSources(typed: text, mentioned: mentioned, excluded: [], session: chat.active, assistantID: reply.id)
        if let i = chat.active.messages.firstIndex(where: { $0.id == reply.id }) {
            chat.active.messages[i].isStreaming = false
            chat.active.messages[i].text = "An answer."
        }
        return (looked.evidence, chat.active.messages.first { $0.id == reply.id })
    }

    private func lastInput(_ store: PackageStore, _ package: LassoPackage) throws -> [String: Any] {
        let data = try Data(contentsOf: store.places(for: package).data.appending(path: "last.json"))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // V1, V6: the message as typed, the previous turn, and a follow-up reaching the source.
    @Test func theSourceGetsTheTurnAndFollowUpsReachIt() async throws {
        try await withSource { chat, store, package in
            let first = await ask(chat, "what did we decide on pricing last week?")
            #expect(first.evidence?.contains("per seat") == true)
            var input = try lastInput(store, package)
            #expect(input["hook"] as? String == "source/1")
            #expect(input["message"] as? String == "what did we decide on pricing last week?", "date words arrive intact")
            #expect((input["today"] as? String)?.count == 10)
            #expect(input["intent"] as? String == "search")

            // "show me an example" shares no word with What's in it: only the follow-up rule asks it.
            let second = await ask(chat, "show me an example")
            #expect(second.message?.steps.first?.text.contains("My notes") == true, "\(second.message?.steps.map(\.text) ?? [])")
            input = try lastInput(store, package)
            #expect((input["previous"] as? [String: Any])?["message"] as? String == "what did we decide on pricing last week?")
            #expect(input["previousSearched"] as? Bool == true)

            // "thanks" has no words to search: not asked.
            let before = try lastInput(store, package)["message"] as? String
            let thanks = await ask(chat, "thanks!")
            #expect(thanks.message?.steps.isEmpty == true)
            #expect(try lastInput(store, package)["message"] as? String == before)
        }
    }

    // V3, V11: a source that ranks its own results still can't exceed the budget.
    @Test func ranksOwnResultsButTheBudgetHolds() async throws {
        try await withSource { chat, _, _ in
            let looked = await ask(chat, "junk", mentioned: ["my-notes"])
            let hits = try #require(looked.message?.sourceHits)
            #expect(hits.count == 3)
            #expect(hits.reduce(0) { $0 + $1.snippet.count } <= SourceCore.maxCharacters)
            let evidence = try #require(looked.evidence)
            #expect(evidence.components(separatedBy: "\n- ").count - 1 == 3)
        }
    }

    // V4: an offer goes to the user as a step, never to the model; one click searches it.
    @Test func aTypoOfferIsAStepNotPartOfThePrompt() async throws {
        try await withSource { chat, store, package in
            let looked = await ask(chat, "how does frozendcit work", mentioned: ["my-notes"])
            let evidence = try #require(looked.evidence)
            #expect(!evidence.contains("frozendict"), "the guess must not reach the model")
            #expect(evidence.contains("found nothing"))
            let step = try #require(looked.message?.steps.first)
            #expect(step.text == "Searched My notes · nothing matched", "\(step.text)")
            #expect(step.actions.first == .searchFor(source: "my-notes", name: "My notes", query: "frozendict", label: "Did you mean “frozendict”?"))

            chat.active.searchFor = ["my-notes": "frozendict"]
            _ = await ask(chat, "how does frozendcit work")
            #expect(try lastInput(store, package)["searchFor"] as? String == "frozendict")
        }
    }

    // V5: the step counts what reached the model.
    @Test func theStepCountsWhatTheModelGot() async throws {
        try await withSource { chat, _, _ in
            let looked = await ask(chat, "what did we decide on pricing")
            #expect(looked.message?.steps.first?.text == "Looked in My notes · sent 1 passage", "\(looked.message?.steps.map(\.text) ?? [])")
        }
    }

    // V7: "not about me" costs nothing when Lasso picked it, and still says "nothing" when @-mentioned.
    @Test func irrelevantCostsNothing() async throws {
        try await withSource { chat, _, _ in
            let picked = await ask(chat, "what's the weather like")
            #expect(picked.evidence == nil)
            #expect(picked.message?.steps.isEmpty == true, "\(picked.message?.steps.map(\.text) ?? [])")

            let mentioned = await ask(chat, "what's the weather like", mentioned: ["my-notes"])
            #expect(mentioned.message?.steps.first?.text == "Searched My notes · nothing related")
            #expect(mentioned.evidence?.contains("found nothing") == true)
        }
    }

    // A note is fenced with its source; for a cloud model it needs the user's Allow like passages.
    @Test func aNoteIsFencedAndFollowsConsent() async throws {
        try await withSource { chat, _, _ in
            let local = await ask(chat, "nothing from last week?", mentioned: ["my-notes"])
            let evidence = try #require(local.evidence)
            #expect(evidence.contains("No notes dated last week."))
            #expect(evidence.contains(SourceCore.fence))

            IntelligenceCoordinator.shared.preferred = .anthropic
            let cloud = await ask(chat, "nothing from last week?", mentioned: ["my-notes"])
            #expect(cloud.evidence?.contains("No notes dated last week.") == false, "not allowed for this provider")
        }
    }

    // describe/1 fills What's in it and picking words; a line the user wrote stays.
    @Test func describeFillsWhatsInItButNotOverTheUsers() async throws {
        try await withSource { _, _, package in
            let entry = try #require(PackageRegistry.shared.all.first { $0.package.id == package.id })
            SourcePreferences.setAbout("", "my-notes")
            await SourceDescribe.refresh(entry)
            #expect(SourcePreferences.about("my-notes") == "pricing, roadmap, launch plans")
            #expect(SourcePreferences.words("my-notes") == ["seat", "tier"])
            #expect(SourcePicker.automatic("what is the per seat tier", from: PackageRegistry.shared.sources()).map(\.id) == ["my-notes"])

            SourcePreferences.setAbout("my own words", "my-notes")
            await SourceDescribe.refresh(entry)
            #expect(SourcePreferences.about("my-notes") == "my own words")
        }
    }

    // V9: Go back restores the previous version's files.
    @Test func goBackRestoresThePreviousVersion() async throws {
        let name = "lasso-goback-\(UUID().uuidString.prefix(6))"
        let base = FileManager.default.temporaryDirectory.appending(path: name, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = PackageStore(root: base.appending(path: "Packages"), defaults: UserDefaults(suiteName: name)!)
        let old = Data((Self.script + "\n# version one\n").utf8)
        try store.install(Data(Self.manifest(version: "1.0.0").utf8), files: ["scripts/search.py": old], origin: .catalog)
        #expect(store.previousVersion("my-notes") == nil)
        try store.install(Data(Self.manifest(version: "1.1.0").utf8), files: ["scripts/search.py": Data(Self.script.utf8)], origin: .catalog)
        #expect(store.previousVersion("my-notes") == "1.0.0")
        try store.goBack("my-notes")
        #expect(store.installed.first { $0.id == "my-notes" }?.package.version == "1.0.0")
        #expect(try Data(contentsOf: base.appending(path: "Packages/my-notes/scripts/search.py")) == old)
        #expect(store.previousVersion("my-notes") == nil)
        #expect(store.installed.first { $0.id == "my-notes" }?.changedOnDisk == false)
    }

    @Test func theValidatorKnowsTheHooks() {
        func problems(_ json: String) -> [String] { PackageValidator.validate(Data(json.utf8)).problems.map(\.description) }
        let head = #"{"lasso": 1, "id": "x-y", "version": "1.0.0", "name": "X", "summary": "x", "author": "Me", "commands": ["#
        #expect(PackageValidator.validate(Data(Self.manifest().utf8)).package != nil)
        #expect(problems(head + #"{"id": "a", "title": "A", "surfaces": ["toolbar"], "input": ["text"], "output": "markdown", "hook": "source/1", "run": {"script": {"path": "scripts/a.py"}}}]}"#)
            .contains { $0.contains("for search commands") })
        #expect(problems(head + #"{"id": "a", "title": "A", "surfaces": ["search"], "input": ["query"], "output": "results", "ranks": true, "run": {"script": {"path": "scripts/a.py"}}, "test": {"query": "x"}}]}"#)
            .contains { $0.contains("Only for commands with \"hook\": \"source/1\"") })
        #expect(problems(head + #"{"id": "a", "title": "A", "surfaces": ["search"], "input": ["query"], "output": "results", "hook": "source/2", "run": {"script": {"path": "scripts/a.py"}}, "test": {"query": "x"}}]}"#)
            .contains { $0.contains("may need a newer Lasso") })
        #expect(problems(head + #"{"id": "d", "title": "D", "hook": "describe/1", "surfaces": ["toolbar"], "run": {"script": {"path": "scripts/a.py"}}}]}"#)
            .contains { $0.contains("has no \"surfaces\"") })
        #expect(problems(head + #"{"id": "a", "title": "A", "surfaces": ["search"], "input": ["query"], "output": "results", "hook": "source/1", "run": {"http": {"url": "https://x.example.com"}}, "test": {"query": "x"}}]}"#)
            .contains { $0.contains("A hook runs a script") })
    }
}
