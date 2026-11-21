import Foundation
import Testing
@testable import Lasso

/// Patches (spec, "Patches: changing Lasso's own content"): what's accepted, the order they apply in,
/// and that turning a package off or removing it leaves Lasso exactly as it was.
@MainActor
@Suite(.serialized)
struct PackagePatchTests {
    static func manifest(id: String = "writing-kit", name: String = "Writing Kit", version: String = "1.0.0",
                         patches: String) -> String {
        """
        {"lasso": 1, "id": "\(id)", "version": "\(version)", "name": "\(name)", "summary": "Changes things.",
         "author": "Me", "patches": \(patches)}
        """
    }

    private func problems(_ patches: String) -> [String] {
        PackageValidator.validate(Data(Self.manifest(patches: patches).utf8)).problems.map(\.description)
    }

    /// A throwaway store standing in for this Mac's, so `PatchState` shows only these packages.
    private func withStore(_ body: (PackageStore, UserDefaults) throws -> Void) rethrows {
        let name = "lasso-patches-\(UUID().uuidString.prefix(6))"
        let defaults = UserDefaults(suiteName: name)!
        let root = FileManager.default.temporaryDirectory.appending(path: name, directoryHint: .isDirectory)
        let real = PackageStore.shared
        let store = PackageStore(root: root, defaults: defaults)
        PackageStore.shared = store
        defer { PackageStore.shared = real; real.reload(); try? FileManager.default.removeItem(at: root) }
        try body(store, defaults)
    }

    // MARK: Validation

    @Test func aPackageCanBeOnlyPatches() throws {
        let outcome = PackageValidator.validate(Data(Self.manifest(patches: """
            [{"target": "action.ai.summarize.prompt", "set": "Summarize as 5 bullets."},
             {"target": "action.ai.summarize.title", "set": "TL;DR"},
             {"target": "toolbar.order", "set": ["translate", "ocr.copy", "study-tools/explain"]},
             {"target": "toolbar.hidden", "add": "lens.search"},
             {"target": "chat.suggestions", "add": {"title": "What's on my calendar today?"}},
             {"target": "chat.suggestions", "remove": "Attach a file or image"},
             {"target": "chat.instructions", "add": "Answer in British English."}]
            """).utf8))
        let package = try #require(outcome.package, "\(outcome.problems)")
        #expect(package.commands.isEmpty)
        #expect(package.patches.count == 7)
        #expect(package.patches[2].items == ["translate", "ocr.copy", "study-tools/explain"])
    }

    @Test func protectionsAndUnknownTargetsAreRefused() {
        for target in ["privacy.localOnly", "chat.fencing", "agent.approvals", "packages.review", "action.translate.prompt",
                       "action.identify.prompt", "sound.capture", "theme.accent", "string.chat.placeholder"] {
            let list = problems(#"[{"target": "\#(target)", "set": "x"}]"#)
            #expect(list.contains { $0.hasPrefix("patches[0].target: Lasso can't patch \"\(target)\"") }, "\(target): \(list)")
        }
    }

    @Test func eachTargetTakesOnlyItsOperationsAndShapes() {
        #expect(problems(#"[{"target": "chat.instructions", "set": "Replace Lasso's rules."}]"#)
            .contains("patches[0].set: chat.instructions can only be changed with add."))
        #expect(problems(#"[{"target": "action.ai.summarize.prompt", "set": "Summarize {{text}}"}]"#)
            .contains { $0.contains("leave out {{…}} values") })
        #expect(problems(#"[{"target": "toolbar.order", "set": ["translate", "rm -rf"]}]"#)
            .contains { $0.contains("\"rm -rf\" isn't a toolbar id") })
        #expect(problems(#"[{"target": "toolbar.order", "set": "translate"}]"#)
            .contains("patches[0].set: Must be a list of toolbar ids."))
        #expect(problems(#"[{"target": "chat.suggestions", "add": "Just a string"}]"#)
            .contains { $0.contains("Must be an object like") })
        #expect(problems(#"[{"target": "chat.instructions", "add": "\#(String(repeating: "a", count: 501))"}]"#)
            .contains("patches[0].add: At most 500 characters."))
        #expect(problems(#"[{"target": "action.ai.ask.title", "set": "x", "add": "y"}]"#)
            .contains { $0.hasPrefix("patches[0]: Needs exactly one of") })
        #expect(problems("[]").contains("patches: Must be a list of 1 to 50 patches."))
        #expect(problems(#"[{"target": "action.ai.ask.title", "set": "Ask", "when": 1}]"#)
            .contains("patches[0].when: Unknown field \"when\"."))
    }

    // MARK: Order and undo

    @Test func theUsersOrderPicksTheWinnerAndUndoIsExact() throws {
        let original = PatchState.prompt("ai.summarize", default: SummarizeAction.defaultPrompt)
        #expect(original == SummarizeAction.defaultPrompt)
        try withStore { store, _ in
            try store.install(Data(Self.manifest(id: "study-tools", name: "Study Tools",
                patches: #"[{"target": "action.ai.summarize.prompt", "set": "A"}]"#).utf8), origin: .file)
            try store.install(Data(Self.manifest(id: "writing-kit",
                patches: #"[{"target": "action.ai.summarize.prompt", "set": "B"}]"#).utf8), origin: .file)
            // Newest install applies last.
            #expect(PatchState.prompt("ai.summarize", default: "") == "B")
            #expect(store.patches.winner["action.ai.summarize.prompt"] == "writing-kit")
            #expect(store.patches.changedBy["action.ai.summarize.prompt"] == ["study-tools", "writing-kit"])
            // The user picks the other.
            store.preferPatches(of: "study-tools")
            #expect(PatchState.prompt("ai.summarize", default: "") == "A")
            // Turning the winner off restores the other's; removing both restores Lasso's exactly.
            store.setEnabled("study-tools", false)
            #expect(PatchState.prompt("ai.summarize", default: "") == "B")
            store.remove("writing-kit")
            store.remove("study-tools")
            #expect(PatchState.prompt("ai.summarize", default: SummarizeAction.defaultPrompt) == SummarizeAction.defaultPrompt)
            #expect(store.patches == AppliedPatches())
        }
    }

    /// Proofread's patched prompt is what the model gets, with the text still framed after it.
    @Test func proofreadSendsThePatchedPrompt() throws {
        try withStore { store, _ in
            try store.install(Data(Self.manifest(patches: #"[{"target": "action.ai.grammar.prompt", "set": "Fix spelling only."}]"#).utf8), origin: .file)
            #expect(GrammarFixAction.framedPrompt(for: "teh cat") == "Fix spelling only.\n\nInput:\nteh cat\nOutput:\n")
            store.setEnabled("writing-kit", false)
            #expect(GrammarFixAction.framedPrompt(for: "teh cat").hasPrefix(GrammarFixAction.prompt))
        }
    }

    @Test func aRenamedActionShowsEverywhereAndComesBack() throws {
        try withStore { store, _ in
            let action = SummarizeAction(intelligence: IntelligenceCoordinator.shared)
            try store.install(Data(Self.manifest(patches: #"[{"target": "action.ai.summarize.title", "set": "TL;DR"}]"#).utf8), origin: .file)
            #expect(action.title == "TL;DR")
            #expect(ActionBarCatalog.entries(actions: [action]).first?.title == "TL;DR")
            store.setEnabled("writing-kit", false)
            #expect(action.title == "Summarize")
        }
    }

    // MARK: Toolbar: the user's own choice wins

    @Test func toolbarPatchesAreDefaultsTheUsersChoicesBeat() throws {
        try withStore { store, defaults in
            try store.install(Data(Self.manifest(patches: """
                [{"target": "toolbar.order", "set": ["ai.summarize", "translate", "study-tools/explain"]},
                 {"target": "toolbar.hidden", "add": ["lens.search", "color.pick"]},
                 {"target": "toolbar.hidden", "remove": "color.pick"}]
                """).utf8), origin: .file)
            let patches = store.patches
            #expect(ActionBarPreferences.effectiveOrder([], patches: patches) == ["ai.summarize", "translate", "pkg:study-tools/explain"])
            #expect(ActionBarPreferences.effectiveOrder(["ocr.copy"], patches: patches) == ["ocr.copy"])
            #expect(ActionBarPreferences.hidden(from: defaults, patches: patches) == ["lens.search"])

            // Saving an order in Settings with the hidden set untouched keeps the hidden set the package's.
            ActionBarPreferences.save(order: ["ocr.copy"], hidden: ["lens.search"], to: defaults, patches: patches)
            #expect(defaults.stringArray(forKey: ActionBarPreferences.hiddenKey) == nil)
            #expect(ActionBarPreferences.hidden(from: defaults, patches: AppliedPatches()).isEmpty)
            // Choosing one makes it the user's.
            ActionBarPreferences.save(order: ["ocr.copy"], hidden: [], to: defaults, patches: patches)
            #expect(ActionBarPreferences.hidden(from: defaults, patches: patches).isEmpty)

            // The bar arranges by the package's order when the user has none.
            let entries = ["translate", "ocr.copy", "ai.summarize"].enumerated().map { ActionBarEntry(id: $1, priority: $0) }
            let main = ActionBarLayout.arrange(entries: entries, order: ActionBarPreferences.effectiveOrder([], patches: patches),
                                               hidden: []).main.map(\.id)
            #expect(main == ["ai.summarize", "translate", "ocr.copy"])
        }
    }

    // MARK: Chat

    @Test func chatInstructionsComeAfterLassosOwnAndLeaveWithThePackage() throws {
        let own = ChatController.systemPrompt(formatting: .full)
        try withStore { store, _ in
            try store.install(Data(Self.manifest(patches: #"[{"target": "chat.instructions", "add": "Answer in British English."}]"#).utf8), origin: .file)
            let patched = ChatController.systemPrompt(formatting: .full)
            #expect(patched.hasPrefix(String(own.prefix(200))))
            #expect(patched.hasSuffix("Added by packages the user installed:\n- Answer in British English."))
            store.setEnabled("writing-kit", false)
            #expect(!ChatController.systemPrompt(formatting: .full).contains("British"))
        }
    }

    @Test func suggestionsAddRemoveAndSetInOrder() {
        func package(_ id: String, _ patches: String) -> LassoPackage {
            PackageValidator.validate(Data(Self.manifest(id: id, patches: patches).utf8)).package!
        }
        let add = package("adds-one", """
            [{"target": "chat.suggestions", "add": [{"title": "Plan my day"}, {"title": "What can you do?"}]},
             {"target": "chat.suggestions", "remove": ["Attach a file or image"]}]
            """)
        #expect(AppliedPatches.apply([add]).suggestions == ["What can you do?", "Ask about something on screen", "Plan my day"])
        let set = package("sets-all", #"[{"target": "chat.suggestions", "set": [{"title": "Only this"}]}]"#)
        #expect(AppliedPatches.apply([add, set]).suggestions == ["Only this"])
        #expect(AppliedPatches.apply([set, add]).suggestions == ["Only this", "Plan my day", "What can you do?"])
        #expect(AppliedPatches.apply([]).suggestions == ChatSuggestions.builtIn)
    }
}

/// Every whole package in the authors' guide is one Lasso accepts, so the guide can't teach a broken one.
struct GuideExamplesTests {
    @Test func everyPackageInTheGuideIsValid() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "docs/CONTRIBUTING-PACKAGES.md")
        let guide = try String(contentsOf: url, encoding: .utf8)
        let blocks = guide.components(separatedBy: "```json\n").dropFirst().compactMap { $0.components(separatedBy: "\n```").first }
            .filter { $0.contains("\"lasso\": 1") }
        #expect(blocks.count >= 2)
        for block in blocks {
            let outcome = PackageValidator.validate(Data(block.utf8))
            #expect(outcome.package != nil, "\(outcome.problems)\n\(block.prefix(120))")
        }
    }
}

/// `docs/patch-targets.md` is generated from the code; this fails when it's out of date, so CI does.
/// Rerun with `LASSO_WRITE_PATCH_TARGETS=1` to write it.
struct PatchTargetsDocTests {
    @Test func theDocMatchesTheCode() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "docs/patch-targets.md")
        let expected = PatchTargets.markdown
        if ProcessInfo.processInfo.environment["LASSO_WRITE_PATCH_TARGETS"] != nil {
            try expected.write(to: url, atomically: true, encoding: .utf8)
        }
        let actual = try String(contentsOf: url, encoding: .utf8)
        #expect(actual == expected, "docs/patch-targets.md is out of date: rerun this test with TEST_RUNNER_LASSO_WRITE_PATCH_TARGETS=1.")
    }
}
