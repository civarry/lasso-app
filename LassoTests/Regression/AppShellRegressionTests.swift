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
}
