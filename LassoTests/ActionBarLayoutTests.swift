import Testing
import Foundation
import KeyboardShortcuts
@testable import Lasso

/// The toolbar's order, visibility, hotkey coverage and direct-run gating.
///
/// All of it is here because all of it is the same class of bug: rules that a green build and a
/// glance at the code both agree with, and that quietly do the wrong thing at runtime. A hidden
/// action that is actually dropped, a new action that lands in a random slot, a hotkey nobody wired
/// up, a Lens hotkey that uploads to Google in local-only mode — none of those fail to compile.
struct ActionBarLayoutTests {

    // The shipped priorities, so the fixtures below read like the real registry.
    private static let shipped: [(String, Int)] = [
        ("ocr.copy", 10), ("identify", 12), ("lens.search", 13), ("qr.open", 15),
        ("translate", 20), ("ai.grammar", 25), ("ai.summarize", 30), ("ai.ask", 40),
        ("color.pick", 50), ("builtin.copyImage", 60), ("builtin.saveImage", 61),
    ]

    private func entries(_ ids: [String], unavailable: Set<String> = []) -> [ActionBarEntry] {
        let priorities = Dictionary(uniqueKeysWithValues: Self.shipped)
        return ids.map { ActionBarEntry(id: $0, priority: priorities[$0] ?? 100,
                                        available: !unavailable.contains($0)) }
    }

    /// Every shipped entry, handed over in a scrambled input order so a test that expects the
    /// default ranking is really testing the sort and not the input.
    private var scrambled: [ActionBarEntry] {
        entries(["ai.ask", "builtin.saveImage", "qr.open", "ocr.copy", "color.pick",
                 "ai.grammar", "identify", "builtin.copyImage", "translate", "lens.search",
                 "ai.summarize"])
    }

    private let shippedOrder = ["ocr.copy", "identify", "lens.search", "qr.open", "translate",
                                "ai.grammar", "ai.summarize", "ai.ask", "color.pick",
                                "builtin.copyImage", "builtin.saveImage"]

    // MARK: - The user's order wins

    /// The whole point of the feature, in the exact shape the user reported it: "I only use select
    /// text and Ask AI, it always takes time to find those icons". Ask AI is priority 40 and a
    /// detected QR code is priority 15, so under the old priority-only sort the QR pill jumped ahead
    /// of the action the user actually came for, on any selection that happened to contain a code.
    @Test func theUsersOrderBeatsRelevancePriorityForAQRCode() {
        let arrangement = ActionBarLayout.arrange(
            entries: entries(["ocr.copy", "qr.open", "ai.ask", "color.pick"]),
            order: ["ocr.copy", "ai.ask"],
            hidden: [])

        #expect(arrangement.main.map(\.id) == ["ocr.copy", "ai.ask", "qr.open", "color.pick"])
        // And specifically: QR did not jump the user's second pick, despite ranking higher.
        let qr = arrangement.main.firstIndex { $0.id == "qr.open" }
        let ask = arrangement.main.firstIndex { $0.id == "ai.ask" }
        #expect(ask! < qr!)
    }

    /// A colour swatch is priority 50 — below everything — yet it must still come first once the
    /// user puts it first.
    @Test func theUsersOrderCanPromoteTheLowestRankedAction() {
        let arrangement = ActionBarLayout.arrange(
            entries: scrambled, order: ["color.pick"], hidden: [])
        #expect(arrangement.main.first?.id == "color.pick")
    }

    // MARK: - Fresh install

    /// Nobody who never opens Settings should be able to tell this feature shipped. With no saved
    /// order, the arrangement is exactly `relevancePriority` then registration order, which is what
    /// the bar did before.
    @Test func aFreshInstallMatchesTheShippedOrderExactly() {
        let arrangement = ActionBarLayout.arrange(entries: scrambled, order: [], hidden: [])
        #expect(arrangement.main.map(\.id) == shippedOrder)
        #expect(arrangement.overflow.isEmpty)
        #expect(arrangement.showsOverflowControl == false)
    }

    /// Equal priorities fall back to registration order, not to whatever the sort happens to do
    /// (`sorted(by:)` is not stable, so this needs an explicit tie-break to hold).
    @Test func equalPrioritiesKeepRegistrationOrder() {
        let tied = (0..<8).map { ActionBarEntry(id: "tie.\($0)", priority: 100) }
        let arrangement = ActionBarLayout.arrange(entries: tied, order: [], hidden: [])
        #expect(arrangement.main.map(\.id) == tied.map(\.id))
    }

    // MARK: - Hiding

    /// Switching an action off moves it to the "…" menu. It is never dropped: the user said "I don't
    /// need this in the row", not "delete this feature".
    @Test func hiddenActionsLandInOverflowRatherThanBeingDropped() {
        let arrangement = ActionBarLayout.arrange(
            entries: scrambled, order: [], hidden: ["qr.open", "color.pick"])

        #expect(arrangement.main.map(\.id).contains("qr.open") == false)
        #expect(arrangement.overflow.map(\.id) == ["qr.open", "color.pick"])
        #expect(arrangement.showsOverflowControl)
        // Nothing vanished.
        let all = Set(arrangement.main.map(\.id)).union(arrangement.overflow.map(\.id))
        #expect(all == Set(scrambled.map(\.id)))
    }

    /// An empty overflow means no "…" control at all. An always-present button that opens an empty
    /// menu is a dead affordance.
    @Test func anEmptyOverflowShowsNoOverflowControl() {
        let arrangement = ActionBarLayout.arrange(entries: scrambled, order: [], hidden: [])
        #expect(arrangement.overflow.isEmpty)
        #expect(arrangement.showsOverflowControl == false)
    }

    /// Hidden entries keep the user's ordering among themselves, so the menu isn't in a third,
    /// unrelated order.
    @Test func overflowKeepsTheUsersOrderAmongHiddenActions() {
        let arrangement = ActionBarLayout.arrange(
            entries: scrambled,
            order: ["color.pick", "ocr.copy", "qr.open"],
            hidden: ["qr.open", "color.pick"])
        #expect(arrangement.overflow.map(\.id) == ["color.pick", "qr.open"])
    }

    /// Comfortable caps the row at 6; the tail spills into the same menu, ahead of the hidden
    /// entries because it ranks higher in the user's own order.
    @Test func theCappedTailSpillsIntoOverflowAheadOfHiddenActions() {
        let arrangement = ActionBarLayout.arrange(
            entries: scrambled, order: [], hidden: ["ocr.copy"], maxMain: 4)

        #expect(arrangement.main.map(\.id) == ["identify", "lens.search", "qr.open", "translate"])
        #expect(arrangement.overflow.map(\.id).first == "ai.grammar")
        #expect(arrangement.overflow.map(\.id).last == "ocr.copy")
    }

    // MARK: - Versions moving underneath the saved order

    /// An action added by a later version has no saved position. It must still appear, visible, and
    /// in a predictable place: after everything the user placed, ranked by priority among the other
    /// ids the user never touched.
    @Test func anActionAddedLaterAppearsVisiblyAtTheEndOfTheUsersOrder() {
        var withNewcomer = entries(["ocr.copy", "ai.ask", "qr.open"])
        withNewcomer.append(ActionBarEntry(id: "future.lowPriority", priority: 5))
        withNewcomer.append(ActionBarEntry(id: "future.highPriority", priority: 95))

        let arrangement = ActionBarLayout.arrange(
            entries: withNewcomer, order: ["ocr.copy", "ai.ask"], hidden: [])

        #expect(arrangement.main.map(\.id)
            == ["ocr.copy", "ai.ask", "future.lowPriority", "qr.open", "future.highPriority"])
        // Visible, not quietly parked in the menu.
        #expect(arrangement.overflow.isEmpty)
    }

    /// An id left over from a version that no longer has that action must not disturb anything: not
    /// the positions of the ids around it, and not by appearing as a phantom row.
    @Test func anUnknownStoredIDIsIgnoredWithoutBreakingTheOrder() {
        let arrangement = ActionBarLayout.arrange(
            entries: entries(["ocr.copy", "ai.ask", "qr.open"]),
            order: ["ocr.copy", "removed.in.0.9", "ai.ask", "also.gone"],
            hidden: ["never.existed"])

        #expect(arrangement.main.map(\.id) == ["ocr.copy", "ai.ask", "qr.open"])
        #expect(arrangement.overflow.isEmpty)
    }

    /// A duplicated id in storage must not make one action occupy two slots or shift the rest.
    @Test func aDuplicatedStoredIDKeepsItsFirstPosition() {
        let arrangement = ActionBarLayout.arrange(
            entries: entries(["ocr.copy", "ai.ask", "qr.open"]),
            order: ["ai.ask", "ocr.copy", "ai.ask"],
            hidden: [])
        #expect(arrangement.main.map(\.id) == ["ai.ask", "ocr.copy", "qr.open"])
    }

    // MARK: - Composing with "Hide unavailable actions"

    /// The two kinds of hiding are different questions ("not useful for this selection" vs "I never
    /// use this"), and they have to compose: an unavailable entry the user also switched off is gone
    /// entirely, since parking it in the menu is exactly the clutter the setting removes.
    @Test func hideUnavailableComposesWithTheUsersHiding() {
        let candidates = entries(["ocr.copy", "translate", "qr.open", "ai.ask"],
                                 unavailable: ["translate", "qr.open"])

        let on = ActionBarLayout.arrange(entries: candidates, order: [],
                                         hidden: ["qr.open", "ai.ask"], hideUnavailable: true)
        #expect(on.main.map(\.id) == ["ocr.copy"])          // translate dropped: unavailable
        #expect(on.overflow.map(\.id) == ["ai.ask"])        // qr dropped: unavailable *and* hidden

        let off = ActionBarLayout.arrange(entries: candidates, order: [],
                                          hidden: ["qr.open", "ai.ask"], hideUnavailable: false)
        #expect(off.main.map(\.id) == ["ocr.copy", "translate"])
        #expect(off.overflow.map(\.id) == ["qr.open", "ai.ask"])
    }

    /// "Hide unavailable" on its own still behaves as it always did: greyed entries leave the bar.
    @Test func hideUnavailableAloneStillDropsGreyedActions() {
        let candidates = entries(["ocr.copy", "translate", "ai.ask"], unavailable: ["translate"])
        let on = ActionBarLayout.arrange(entries: candidates, order: [], hidden: [],
                                         hideUnavailable: true)
        #expect(on.main.map(\.id) == ["ocr.copy", "ai.ask"])
        #expect(on.showsOverflowControl == false)
    }

    // MARK: - Persistence

    @Test func savedOrderAndVisibilityRoundTripAndBumpTheRevision() {
        let suite = "ActionBarLayoutTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(ActionBarPreferences.order(from: defaults).isEmpty)
        #expect(ActionBarPreferences.hidden(from: defaults).isEmpty)

        let before = defaults.integer(forKey: ActionBarPreferences.revisionKey)
        ActionBarPreferences.save(order: ["ai.ask", "ocr.copy"], hidden: ["qr.open"], to: defaults)

        #expect(ActionBarPreferences.order(from: defaults) == ["ai.ask", "ocr.copy"])
        #expect(ActionBarPreferences.hidden(from: defaults) == ["qr.open"])
        // The bar re-reads the arrays off this counter, so a save that doesn't bump it is a save the
        // open bar never sees.
        #expect(defaults.integer(forKey: ActionBarPreferences.revisionKey) == before + 1)

        ActionBarPreferences.save(order: [], hidden: [], to: defaults)
        #expect(ActionBarPreferences.order(from: defaults).isEmpty)
        #expect(ActionBarPreferences.hidden(from: defaults).isEmpty)
    }
}

/// Hotkey coverage and the direct-run gate.
struct ActionShortcutsTests {

    /// **This test is the point of the table.** Every registered action must have a hotkey name, or
    /// the Settings row for it renders no recorder and the action is the one thing in the toolbar
    /// you can't bind. Adding an action without adding its entry turns this red instead of shipping
    /// a silently half-wired feature.
    @MainActor @Test func everyRegisteredActionHasAShortcutName() {
        let registry = ActionRegistry.makeDefault(intelligence: .shared)
        let registered = Set(registry.actions.map(\.id))

        #expect(registered.isEmpty == false)
        let missing = registered.subtracting(ActionShortcuts.byActionID.keys)
        #expect(missing.isEmpty, "Registered actions with no hotkey: \(missing.sorted())")
    }

    /// The other direction: a stale entry for an action that no longer exists would show a recorder
    /// for nothing and bind a key that can never fire.
    @MainActor @Test func noShortcutNamePointsAtAMissingAction() {
        let registered = Set(ActionRegistry.makeDefault(intelligence: .shared).actions.map(\.id))
        let orphans = Set(ActionShortcuts.byActionID.keys).subtracting(registered)
        #expect(orphans.isEmpty, "Hotkeys bound to actions that don't exist: \(orphans.sorted())")

        let fullScreenOrphans = Set(ActionShortcuts.fullScreenByActionID.keys).subtracting(registered)
        #expect(fullScreenOrphans.isEmpty)
    }

    /// Two actions sharing one name would mean binding one silently rebinds the other.
    @MainActor @Test func everyActionGetsItsOwnShortcutName() {
        let names = ActionShortcuts.byActionID.values.map(\.rawValue)
        #expect(Set(names).count == names.count)
        // ...and the in-place Proofread hotkey is not one of them: it does a different job (⌘C the
        // highlighted text, correct it, paste back) and must keep its own binding.
        #expect(names.contains(KeyboardShortcuts.Name.grammarSelection.rawValue) == false)
    }

    /// Bindings people already assigned must survive: `KeyboardShortcuts` stores a shortcut under the
    /// name's raw value, so renaming one of these silently discards it.
    @MainActor @Test func preExistingShortcutNamesAreUnchanged() {
        #expect(ActionShortcuts.byActionID["identify"]?.rawValue == "identifySelection")
        #expect(ActionShortcuts.byActionID["lens.search"]?.rawValue == "lensSelection")
        #expect(ActionShortcuts.fullScreenByActionID["identify"]?.rawValue == "identifyFullScreen")
        #expect(ActionShortcuts.fullScreenByActionID["lens.search"]?.rawValue == "lensFullScreen")
    }

    /// The toolbar catalog carries the two built-in image actions the bar appends itself, so Settings
    /// can order and hide them too.
    @MainActor @Test func theCatalogCoversRegisteredActionsAndTheBuiltInImageOnes() {
        let registry = ActionRegistry.makeDefault(intelligence: .shared)
        let catalog = ActionBarCatalog.entries(actions: registry.actions)
        let ids = catalog.map(\.id)

        #expect(ids.count == registry.actions.count + 2)
        #expect(ids.contains("builtin.copyImage"))
        #expect(ids.contains("builtin.saveImage"))
        // The built-ins can't run from a hotkey: `beginDirect` resolves an id against the registry.
        #expect(catalog.first { $0.id == "builtin.copyImage" }?.shortcut == nil)
        #expect(catalog.first { $0.id == "ai.ask" }?.shortcut != nil)
    }
}

/// The gate every direct hotkey passes through before a pixel is captured.
struct DirectActionGateTests {

    private let allIDs: Set<String> = ["ocr.copy", "identify", "lens.search", "qr.open", "translate",
                                       "ai.grammar", "ai.summarize", "ai.ask", "color.pick"]

    private func environment(lensEnabled: Bool = true, localOnly: Bool = false,
                             visionAvailable: Bool = true,
                             textModelConfigured: Bool = true) -> DirectActionGate.Environment {
        DirectActionGate.Environment(knownActionIDs: allIDs, lensEnabled: lensEnabled,
                                     localOnly: localOnly, visionAvailable: visionAvailable,
                                     textModelConfigured: textModelConfigured)
    }

    /// The bug this app has shipped twice. Lens uploads the selection to Google; the direct path
    /// skips `isRelevant`, which is the only other place that is checked. A hotkey must not be a way
    /// around local-only mode.
    @Test func lensRefusesInLocalOnlyMode() {
        let decision = DirectActionGate.decide(actionID: "lens.search", title: "Lens",
                                               environment: environment(localOnly: true))
        #expect(decision.isAllowed == false)
        guard case .refuse(_, let reason) = decision else { return }
        #expect(reason.localizedCaseInsensitiveContains("local-only"))
    }

    /// Local-only is the stronger promise, so it is the reason shown even when Lens is also off.
    @Test func localOnlyIsTheReasonGivenEvenWhenLensIsAlsoSwitchedOff() {
        let decision = DirectActionGate.decide(actionID: "lens.search", title: "Lens",
                                               environment: environment(lensEnabled: false,
                                                                        localOnly: true))
        guard case .refuse(_, let reason) = decision else {
            Issue.record("expected a refusal"); return
        }
        #expect(reason.localizedCaseInsensitiveContains("local-only"))
    }

    @Test func lensRefusesWhenTheOptInIsOff() {
        let decision = DirectActionGate.decide(actionID: "lens.search", title: "Lens",
                                               environment: environment(lensEnabled: false))
        #expect(decision.isAllowed == false)
    }

    @Test func lensRunsOnceItIsOptedInAndNotLocalOnly() {
        #expect(DirectActionGate.decide(actionID: "lens.search", title: "Lens",
                                        environment: environment()) == .allow)
    }

    /// An AI action with nothing behind it must say so, not start a capture that ends in a provider
    /// error the user can't read as "you haven't finished setting this up".
    @Test func anAIActionRefusesWithNoLanguageModelConfigured() {
        for id in ["ai.ask", "ai.summarize", "ai.grammar"] {
            let decision = DirectActionGate.decide(actionID: id, title: "Ask AI",
                                                   environment: environment(textModelConfigured: false))
            #expect(decision.isAllowed == false, "\(id) should refuse with no language model")
            guard case .refuse(_, let reason) = decision else { continue }
            #expect(reason.localizedCaseInsensitiveContains("language model"))
        }
    }

    @Test func identifyRefusesWithNoImageModel() {
        let decision = DirectActionGate.decide(actionID: "identify", title: "Identify",
                                               environment: environment(visionAvailable: false))
        #expect(decision.isAllowed == false)
        guard case .refuse(_, let reason) = decision else { return }
        #expect(reason.localizedCaseInsensitiveContains("image model"))
    }

    /// Identify is a vision action, not a text one: a missing *language* model must not block it, or
    /// the gate would start refusing things that work.
    @Test func identifyIsNotBlockedByTheLanguageModelCheck() {
        #expect(DirectActionGate.decide(actionID: "identify", title: "Identify",
                                        environment: environment(textModelConfigured: false)) == .allow)
    }

    /// The non-AI actions are pure local work and must never be gated: gating one would be a
    /// regression that reads like a feature.
    @Test func localActionsAreNeverGated() {
        let hostile = environment(lensEnabled: false, localOnly: true, visionAvailable: false,
                                  textModelConfigured: false)
        for id in ["ocr.copy", "translate", "qr.open", "color.pick"] {
            #expect(DirectActionGate.decide(actionID: id, title: id, environment: hostile) == .allow,
                    "\(id) must run offline with nothing configured")
        }
    }

    /// A hotkey left over from a version that had an action Lasso no longer ships must explain
    /// itself rather than doing nothing, which is indistinguishable from a broken binding.
    @Test func anUnknownActionIDRefusesWithSomethingToRead() {
        let decision = DirectActionGate.decide(actionID: "removed.action",
                                               environment: environment())
        guard case .refuse(_, let reason) = decision else {
            Issue.record("expected a refusal"); return
        }
        #expect(reason.isEmpty == false)
    }

    /// Every refusal has to carry a sentence. A `.refuse` with an empty reason presents an empty
    /// card, which is the silent failure wearing a window.
    @Test func everyRefusalCarriesAReason() {
        let cases: [(String, DirectActionGate.Environment)] = [
            ("lens.search", environment(localOnly: true)),
            ("lens.search", environment(lensEnabled: false)),
            ("identify", environment(visionAvailable: false)),
            ("ai.ask", environment(textModelConfigured: false)),
            ("gone", environment()),
        ]
        for (id, env) in cases {
            guard case .refuse(let title, let reason) = DirectActionGate.decide(actionID: id,
                                                                                title: "Action",
                                                                                environment: env)
            else { Issue.record("\(id) should have been refused"); continue }
            #expect(title.isEmpty == false)
            #expect(reason.count > 20, "refusal for \(id) is too short to be an explanation")
        }
    }
}

/// The half of the direct-hotkey gate that needs the selection. `decide` runs before the capture and
/// can only answer the static questions; these are the ones that made a hotkey look dead: a QR hotkey
/// on a picture with no code, or Copy text where nothing was readable.
@Suite(.timeLimit(.minutes(1)))
struct DirectActionContentGateTests {

    @Test func anActionWithNothingToWorkOnRefusesOutLoud() {
        let decision = DirectActionGate.contentDecision(title: "Scan code", isRelevant: false, disabledReason: nil)
        #expect(decision == .refuse(title: "Scan code",
                                    reason: "Scan code has nothing to work with in that selection."))
    }

    @Test func theActionsOwnReasonIsPreferredWhenItHasOne() {
        // "No text to translate." says more than the generic line, and it is what the greyed pill in
        // the toolbar would have said.
        let decision = DirectActionGate.contentDecision(title: "Translate", isRelevant: true,
                                                        disabledReason: "No text to translate.")
        #expect(decision == .refuse(title: "Translate", reason: "No text to translate."))

        let both = DirectActionGate.contentDecision(title: "Translate", isRelevant: false,
                                                    disabledReason: "No text to translate.")
        #expect(both == .refuse(title: "Translate", reason: "No text to translate."),
                "the specific sentence wins over the generic one")
    }

    @Test func anActionWithSomethingToDoRuns() {
        #expect(DirectActionGate.contentDecision(title: "Ask AI", isRelevant: true, disabledReason: nil) == .allow)
    }
}

/// Two of Lasso's own shortcuts on the same keys. The library warns when macOS or the app's menu bar
/// owns a combination, but says nothing about the app's own: both actions would fire on one keypress.
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct ShortcutConflictTests {
    private let combo = KeyboardShortcuts.Shortcut(.one, modifiers: [.control, .option])

    @Test func aCombinationAlreadyUsedByAnotherActionIsFound() {
        let taken: [KeyboardShortcuts.Name: KeyboardShortcuts.Shortcut] = [.askAISelection: combo]
        let other = ShortcutConflict.other(using: combo, assignedTo: .ocrCopySelection, lookup: { taken[$0] })
        #expect(other == .askAISelection)
    }

    @Test func aFreeCombinationIsNotAConflictAndNeitherIsYourOwn() {
        let taken: [KeyboardShortcuts.Name: KeyboardShortcuts.Shortcut] = [.ocrCopySelection: combo]
        #expect(ShortcutConflict.other(using: combo, assignedTo: .askAISelection, lookup: { _ in nil }) == nil)
        #expect(ShortcutConflict.other(using: combo, assignedTo: .ocrCopySelection, lookup: { taken[$0] }) == nil,
                "re-recording the same keys on the same action is not a clash with itself")
    }

    /// App-wide shortcuts are in the same space as the toolbar ones: ⌃⇧C for Capture must clash.
    @Test func theAppsOwnGlobalShortcutsCountToo() {
        let taken: [KeyboardShortcuts.Name: KeyboardShortcuts.Shortcut] = [.capture: combo]
        #expect(ShortcutConflict.other(using: combo, assignedTo: .translateSelection, lookup: { taken[$0] }) == .capture)
    }

    @Test func theAlertNamesBothSides() {
        let wording = ShortcutConflict.message(proposed: combo, taking: .askAISelection, from: .ocrCopySelection)
        #expect(wording.title.contains("already used by Copy text"))
        #expect(wording.body.contains("Ask AI") && wording.body.contains("Copy text"))
    }

    /// A shortcut with no entry here cannot be warned about, so the table has to cover everything.
    @Test func everyShortcutTheAppOwnsIsInTheConflictTable() {
        for (id, name) in ActionShortcuts.byActionID {
            #expect(ActionShortcuts.titlesByName[name] != nil, "missing title for \(id)")
        }
        for (id, name) in ActionShortcuts.fullScreenByActionID {
            #expect(ActionShortcuts.titlesByName[name] != nil, "missing title for \(id) (full screen)")
        }
        for name in [KeyboardShortcuts.Name.capture, .cancelCapture, .chat, .grammarSelection] {
            #expect(ActionShortcuts.titlesByName[name] != nil, "missing title for \(name.rawValue)")
        }
    }
}

/// Recording a shortcut, now that Lasso reads the keypress itself. These are the rules that used to
/// belong to the library's text field.
@Suite(.timeLimit(.minutes(1)))
struct ShortcutRecordingTests {
    private let combo = KeyboardShortcuts.Shortcut(.one, modifiers: [.control, .option])

    @Test func escapeCancelsAndDeleteClears() {
        #expect(ShortcutRecording.outcome(keyCode: 53, modifiers: [], isFunctionKey: false, shortcut: combo) == .cancel)
        #expect(ShortcutRecording.outcome(keyCode: 51, modifiers: [], isFunctionKey: false, shortcut: combo) == .clear)
        #expect(ShortcutRecording.outcome(keyCode: 117, modifiers: [], isFunctionKey: false, shortcut: combo) == .clear,
                "forward delete clears too")
    }

    /// A bare letter cannot be a global shortcut: it would fire while the user is typing anywhere.
    @Test func aKeyWithoutAModifierIsRefused() {
        #expect(ShortcutRecording.outcome(keyCode: 18, modifiers: [], isFunctionKey: false, shortcut: combo) == .reject)
        #expect(ShortcutRecording.outcome(keyCode: 18, modifiers: [.shift], isFunctionKey: false, shortcut: combo) == .reject,
                "shift alone is not enough")
    }

    @Test func aModifiedKeyIsAssigned() {
        #expect(ShortcutRecording.outcome(keyCode: 18, modifiers: [.control, .option], isFunctionKey: false,
                                          shortcut: combo) == .assign(combo))
        #expect(ShortcutRecording.outcome(keyCode: 122, modifiers: [], isFunctionKey: true,
                                          shortcut: combo) == .assign(combo), "F-keys stand alone")
    }

    @Test func aKeypressThatIsNotAShortcutIsRefused() {
        #expect(ShortcutRecording.outcome(keyCode: 18, modifiers: [.command], isFunctionKey: false,
                                          shortcut: nil) == .reject)
    }

    @Test func onlyRealFunctionKeysCountAsStandalone() {
        #expect(ShortcutRecording.isFunctionKey(.f1))
        #expect(ShortcutRecording.isFunctionKey(.f20))
        #expect(!ShortcutRecording.isFunctionKey(.home))
        #expect(!ShortcutRecording.isFunctionKey(nil))
    }
}

/// Shortcuts are staged edits, not writes-through. The case that matters is clearing: the draft holds
/// no entry at all for an emptied shortcut, which must still reach storage as a write of nil.
@Suite(.timeLimit(.minutes(1)))
struct ShortcutStagingTests {
    private let one = KeyboardShortcuts.Name("stagingOne")
    private let two = KeyboardShortcuts.Name("stagingTwo")
    private var names: [KeyboardShortcuts.Name] { [one, two] }

    private let ctrlShiftC = KeyboardShortcuts.Shortcut(.c, modifiers: [.control, .shift])
    private let cmdOptK = KeyboardShortcuts.Shortcut(.k, modifiers: [.command, .option])

    @Test func loadingStagesOnlyWhatIsAssigned() {
        let staged = ShortcutStaging.snapshot(names: names,
                                              stored: { $0 == self.one ? self.ctrlShiftC : nil })
        #expect(staged == [self.one.rawValue: ctrlShiftC])
    }

    @Test func anUntouchedShortcutIsNotRewritten() {
        let changes = ShortcutStaging.changes(staged: [one.rawValue: ctrlShiftC], names: names,
                                              stored: { $0 == self.one ? self.ctrlShiftC : nil })
        #expect(changes.isEmpty)
    }

    @Test func clearingWritesNil() {
        // The user pressed ✕: the key is gone from the draft, and storage still holds the old value.
        let changes = ShortcutStaging.changes(staged: [:], names: names,
                                              stored: { $0 == self.one ? self.ctrlShiftC : nil })
        #expect(changes.count == 1)
        #expect(changes.first?.name == one)
        #expect(changes.first?.shortcut == nil)
    }

    @Test func recordingAndRebindingBothReachStorage() {
        let changes = ShortcutStaging.changes(staged: [one.rawValue: cmdOptK, two.rawValue: ctrlShiftC],
                                              names: names,
                                              stored: { $0 == self.one ? self.ctrlShiftC : nil })
        #expect(changes.map(\.name) == [one, two], "sorted by name, so the order is predictable")
        #expect(changes.map(\.shortcut) == [cmdOptK, ctrlShiftC])
    }
}
