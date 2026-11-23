import Foundation
import KeyboardShortcuts
import Testing
@testable import Lasso

/// Regression: the app shell (shortcut recording, dictation cleanup, Keychain lookups). Each test is a
/// bug a QA pass found; it fails without its fix.
@MainActor
@Suite(.serialized)
struct AppShellRegressionTests {

    // 1. Recording (or just clicking and cancelling) any shortcut in Settings ends with
    //    `KeyboardShortcuts.enable(every name)`, which includes `.cancelCapture` (Esc). That one must
    //    only be live during a capture (TriggerService/CaptureCoordinator), so afterwards Esc is a
    //    global Carbon hotkey that every app on the Mac stops receiving.
    @Test func recordingAShortcutLeavesEscapeDisabled() {
        KeyboardShortcuts.disable(.cancelCapture)
        defer { KeyboardShortcuts.disable(.cancelCapture) }   // never leave Esc grabbed on this Mac
        #expect(!KeyboardShortcuts.isEnabled(for: .cancelCapture), "precondition")
        let session = ShortcutRecording.shared
        session.begin(for: .ocrCopySelection, staged: { _ in nil }, clearOther: { _ in }, onFinish: { _ in })
        session.cancel()
        #expect(!KeyboardShortcuts.isEnabled(for: .cancelCapture),
                "Esc is now a system-wide hotkey after a Settings recorder was clicked")
    }

    // 2. Rules-only cleanup (on by default, runs with or without the model) deletes hesitation
    //    patterns case-insensitively, so dictated acronyms that spell a hesitation vanish.
    @Test func cleanupKeepsAcronymsThatLookLikeHesitations() {
        #expect(DictationCleanup.tidy("We went to the ER last night.") == "We went to the ER last night.")
        #expect(DictationCleanup.tidy("She studies at UM in Ann Arbor.") == "She studies at UM in Ann Arbor.")
        #expect(DictationCleanup.tidy("Pay HM Revenue by Friday.") == "Pay HM Revenue by Friday.")
    }

    // 3. Accidental-repeat collapse is case-insensitive and knows no names: places and constructions
    //    that repeat a word on purpose lose one.
    @Test func cleanupKeepsIntentionalRepeatedWords() {
        #expect(DictationCleanup.tidy("We flew to Bora Bora.") == "We flew to Bora Bora.")
        #expect(DictationCleanup.tidy("What it is is a timing bug.") == "What it is is a timing bug.")
    }

    // 4. A key that isn't saved isn't remembered as missing: every `Keychain.get` of it goes back to
    //    the Keychain (`readLegacy`, a SecItemCopyMatching), and `ChatController.anthropicReady` does
    //    that on every render of the chat header's model menu when no Anthropic key is set. A saved
    //    key is a dictionary lookup. (With a legacy item the user declined, each of those reads is a
    //    password prompt.)
    @Test func missingKeyIsNotReReadFromTheKeychainEveryTime() {
        let present = "qa7.present.\(UUID().uuidString)"
        let missing = "qa7.missing.\(UUID().uuidString)"
        Keychain.set("x", for: present)
        defer { Keychain.delete(present) }
        _ = Keychain.get(missing)
        func time(_ account: String) -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<300 { _ = Keychain.get(account) }
            return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
        }
        let hit = time(present), miss = time(missing)
        #expect(miss < hit * 5 + 5, "300 reads: saved key \(hit) ms, missing key \(miss) ms")
    }

    // 5-8. After an update macOS asks for the password once to open the saved keys. When that prompt
    //    was cancelled, `vault()` stayed nil for the rest of the launch and `set` returned without a
    //    word: a key typed in Settings showed as saved, was gone on the next launch, and the provider
    //    said "no key". The refusal is simulated (`Keychain.vaultReadsForTesting`); the vault is the
    //    tests' own (`lasso.vault.tests`), never this Mac's.

    /// Runs `body` with the vault's first `refusals` reads refused, from a fresh launch's state.
    private func afterRefusal<T>(_ refusals: Int, _ body: (Keychain.VaultReadsForTesting) -> T) -> T {
        Keychain.resetCache()
        defer { Keychain.resetCache() }
        let reads = Keychain.VaultReadsForTesting(refusals: refusals)
        return Keychain.$vaultReadsForTesting.withValue(reads) { body(reads) }
    }

    @Test func aKeySavedAfterARefusedPromptIsKept() {
        let account = "qa8.saved.\(UUID().uuidString)"
        defer { Keychain.delete(account) }
        afterRefusal(1) { _ in
            #expect(Keychain.get(account) == nil)   // a background read: the prompt is cancelled
            _ = Keychain.set("sk-typed", for: account)
        }
        #expect(Keychain.get(account) == "sk-typed", "the key typed after a cancelled prompt was dropped")
    }

    @Test func savingAfterARefusalAsksOnceMoreAndSaves() {
        let account = "qa8.retry.\(UUID().uuidString)"
        defer { Keychain.delete(account) }
        let reads = afterRefusal(1) { reads in
            _ = Keychain.get(account)
            #expect(Keychain.isRefused)
            #expect(Keychain.set("sk-typed", for: account), "the save reported failure though the retry could read")
            #expect(!Keychain.isRefused)
            return reads.count
        }
        #expect(reads == 2, "the refused read plus exactly one retry, got \(reads)")
        #expect(Keychain.get(account) == "sk-typed")
    }

    @Test func aSecondRefusalReportsFailureAndKeepsTheSavedKeys() {
        let kept = "qa8.kept.\(UUID().uuidString)"
        let typed = "qa8.typed.\(UUID().uuidString)"
        Keychain.resetCache()
        #expect(Keychain.set("sk-kept", for: kept), "precondition")
        defer { Keychain.delete(kept); Keychain.delete(typed) }
        afterRefusal(3) { reads in
            _ = Keychain.get(kept)
            #expect(!Keychain.set("sk-typed", for: typed), "set claimed success while the vault stayed closed")
            #expect(reads.count == 2, "a save asks once more, not again and again")
            #expect(!Keychain.delete(kept), "delete claimed success while the vault stayed closed")
            #expect(reads.count == 3)
        }
        // Never a fresh vault over one that couldn't be read.
        #expect(Keychain.get(kept) == "sk-kept", "a refused prompt wiped a saved key")
        #expect(Keychain.get(typed) == nil)
    }

    @Test func aRefusedVaultIsNotReReadOnEveryBackgroundRead() {
        let account = "qa8.background.\(UUID().uuidString)"
        let legacyDefaultsKey = "qa8.legacy.\(UUID().uuidString)"
        UserDefaults.standard.set("sk-legacy", forKey: legacyDefaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: legacyDefaultsKey); Keychain.delete(account) }
        let reads = afterRefusal(100) { reads in
            for _ in 0..<5 { #expect(Keychain.get(account) == nil) }
            // A read that also moves an old copy in: it mustn't ask, nor drop the copy it couldn't move.
            #expect(Keychain.getMigrating(account, legacyDefaultsKey: legacyDefaultsKey) == "sk-legacy")
            return reads.count
        }
        #expect(reads == 1, "each background read asked again: \(reads) prompts")
        #expect(UserDefaults.standard.string(forKey: legacyDefaultsKey) == "sk-legacy",
                "the old copy was removed though the Keychain never saved it")
    }
}
