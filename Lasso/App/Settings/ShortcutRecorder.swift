import AppKit
import KeyboardShortcuts
import SwiftUI

/// A shortcut recorder that is a button, not a text field.
///
/// **Why Lasso has its own.** `KeyboardShortcuts.Recorder` is an `NSSearchField`, and in this window it
/// would not start: clicking the middle of the box gave it a focus ring but left it on "Record
/// Shortcut" with a caret (what `RecorderCocoa` looks like when recording never began), while a click
/// on its border worked. Hosting the control directly and forcing first responder made it worse: the
/// field editor's text-selection gesture never completed and AppKit began dropping gestures for the
/// whole window ("stuck gesture recognizers" in the log). The field editor is the common thread, so
/// this drops the text field entirely. A button has no editor, no caret and no selection gesture: it
/// is either recording or it isn't.
///
/// Storage, the global hotkey and the `Name` all still belong to the library. This is only the
/// recording UI.
struct ShortcutRecorder: View {
    let name: KeyboardShortcuts.Name
    /// The staged value. Like every other control in this window, a shortcut is only written to storage
    /// by Save & Apply, so Revert undoes it and the unsaved bar appears when it changes.
    @Binding var shortcut: KeyboardShortcuts.Shortcut?
    /// Every other staged shortcut, so a clash is caught against what is on screen rather than what is
    /// saved. Returns nil for a name the user has just cleared.
    let staged: (KeyboardShortcuts.Name) -> KeyboardShortcuts.Shortcut?
    /// Clears the other side of a clash when the user chooses to move a shortcut.
    let clearOther: (KeyboardShortcuts.Name) -> Void
    var width: CGFloat = 128

    // Computed, not stored: a private *stored* property makes the memberwise init private under Swift
    // 6.3 (Xcode 26), so SettingsView couldn't build this view there (CI caught it; Swift 6.4 allows it).
    private var session: ShortcutRecording { .shared }

    private var isRecording: Bool { session.recordingName == name }

    var body: some View {
        HStack(spacing: 4) {
            Button(action: toggle) {
                Text(label)
                    .font(.body.monospaced())
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.bordered)
            .tint(isRecording ? Color.accentColor : nil)
            .help(isRecording ? "Press the keys you want, or Esc to cancel"
                              : "Click, then press the keys you want")

            Button { assign(nil) } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Clear this shortcut")
                .opacity(shortcut == nil || isRecording ? 0 : 1)
                .disabled(shortcut == nil || isRecording)
        }
        .frame(width: width)
        .onDisappear { if isRecording { session.cancel() } }
    }

    private var label: String {
        if isRecording { return "Press keys" }
        return shortcut?.description ?? "Set shortcut"
    }

    private func toggle() {
        if isRecording {
            session.cancel()
        } else {
            session.begin(for: name, staged: staged, clearOther: clearOther) { captured in
                shortcut = captured
            }
        }
    }

    private func assign(_ value: KeyboardShortcuts.Shortcut?) {
        shortcut = value
    }
}

/// The one recording in progress, if any.
///
/// A singleton because only one shortcut can be recorded at a time, and because the keypress has to be
/// caught with a local monitor while the app's own hotkeys are disabled: otherwise recording ⌃⇧C would
/// start a capture instead of being recorded.
@MainActor
@Observable
final class ShortcutRecording {
    static let shared = ShortcutRecording()

    private(set) var recordingName: KeyboardShortcuts.Name?
    private var monitor: Any?
    private var onFinish: ((KeyboardShortcuts.Shortcut?) -> Void)?
    private var staged: ((KeyboardShortcuts.Name) -> KeyboardShortcuts.Shortcut?)?
    private var clearOther: ((KeyboardShortcuts.Name) -> Void)?

    /// What a keypress during recording means.
    enum Outcome: Equatable {
        case assign(KeyboardShortcuts.Shortcut)
        case clear
        case cancel
        /// Not usable as a global shortcut: a bare letter, or modifiers on their own.
        case reject
    }

    /// Pure, so the rules are tested rather than clicked: Esc cancels, Delete clears, and a plain key
    /// with no modifier can't be a global shortcut.
    nonisolated static func outcome(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, isFunctionKey: Bool,
                                    shortcut: KeyboardShortcuts.Shortcut?) -> Outcome {
        if keyCode == 53 { return .cancel }                       // Esc
        if keyCode == 51 || keyCode == 117 { return .clear }      // Delete / Forward delete
        guard !modifiers.intersection([.command, .control, .option]).isEmpty || isFunctionKey else {
            return .reject
        }
        guard let shortcut else { return .reject }
        return .assign(shortcut)
    }

    /// F1 to F20 can stand alone as a shortcut; everything else needs a modifier. (The library has the
    /// same rule, but its own check is internal.)
    nonisolated static func isFunctionKey(_ key: NSEvent.SpecialKey?) -> Bool {
        guard let key else { return false }
        return (NSEvent.SpecialKey.f1.rawValue...NSEvent.SpecialKey.f20.rawValue).contains(key.rawValue)
    }

    func begin(for name: KeyboardShortcuts.Name,
               staged: @escaping (KeyboardShortcuts.Name) -> KeyboardShortcuts.Shortcut?,
               clearOther: @escaping (KeyboardShortcuts.Name) -> Void,
               onFinish: @escaping (KeyboardShortcuts.Shortcut?) -> Void) {
        cancel()
        recordingName = name
        self.staged = staged
        self.clearOther = clearOther
        self.onFinish = onFinish
        KeyboardShortcuts.disable(Array(ActionShortcuts.titlesByName.keys))
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            MainActor.assumeIsolated { self.handle(event, for: name) }
            return nil          // swallow it: this keypress was meant for the recorder
        }
    }

    func cancel() {
        guard recordingName != nil else { return }
        stop()
    }

    private func handle(_ event: NSEvent, for name: KeyboardShortcuts.Name) {
        switch Self.outcome(keyCode: event.keyCode, modifiers: event.modifierFlags,
                            isFunctionKey: Self.isFunctionKey(event.specialKey),
                            shortcut: KeyboardShortcuts.Shortcut(event: event)) {
        case .reject:
            NSSound.beep()          // stay recording, so they can try another combination
        case .cancel:
            stop()
        case .clear:
            finish(with: nil)
        case .assign(let shortcut):
            assign(shortcut, to: name)
        }
    }

    private func assign(_ shortcut: KeyboardShortcuts.Shortcut, to name: KeyboardShortcuts.Name) {
        // Against what is on screen, not what is saved: both sides of a clash may be unsaved edits.
        guard let other = ShortcutConflict.other(using: shortcut, assignedTo: name,
                                                 lookup: { self.staged?($0) })
        else {
            finish(with: shortcut)
            return
        }
        // The library warns when macOS or the app's menu bar owns a combination, but not when Lasso
        // itself does: two actions on one key would both fire, with nothing said.
        let wording = ShortcutConflict.message(proposed: shortcut, taking: name, from: other)
        let alert = NSAlert()
        alert.messageText = wording.title
        alert.informativeText = wording.body
        alert.addButton(withTitle: "Move it here")
        alert.addButton(withTitle: "Keep it where it is")
        if alert.runModal() == .alertFirstButtonReturn {
            clearOther?(other)
            finish(with: shortcut)
        } else {
            stop()
        }
    }

    private func finish(with shortcut: KeyboardShortcuts.Shortcut?) {
        onFinish?(shortcut)
        stop()
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recordingName = nil
        onFinish = nil
        staged = nil
        clearOther = nil
        KeyboardShortcuts.enable(Array(ActionShortcuts.titlesByName.keys))
    }
}
