import AppKit
import ApplicationServices
import CoreGraphics
import SwiftUI

/// In-place grammar fix on the *currently highlighted* text in any app — the convenient flow:
/// highlight → hotkey → corrected text is pasted back over the selection.
///
/// Mechanism (no screenshot/OCR): simulate ⌘C to grab the selection, correct it with the active text
/// engine, put the result on the pasteboard, simulate ⌘V to paste it back, then restore the user's
/// original clipboard. Requires Accessibility permission to post the keystrokes.
@MainActor
final class GrammarFixService {
    static let shared = GrammarFixService()
    private init() {}

    private let intelligence = IntelligenceCoordinator.shared
    private var running = false

    /// 'c' and 'v' ANSI virtual key codes (kVK_ANSI_C / kVK_ANSI_V).
    private let keyC: CGKeyCode = 8
    private let keyV: CGKeyCode = 9

    func run() {
        guard !running else { return }
        running = true
        Task { await fixSelectedText(); running = false }
    }

    private func fixSelectedText() async {
        // Accessibility is required to post ⌘C/⌘V to the frontmost app.
        guard ensureAccessibility() else {
            StatusHUD.shared.show(icon: "lock.shield",
                text: "Enable Accessibility for Lasso in System Settings, then try again.", persist: 4)
            openAccessibilitySettings()
            return
        }

        let pb = NSPasteboard.general
        let savedClipboard = pb.string(forType: .string)
        let changeBefore = pb.changeCount

        // Grab the current selection by copying it.
        sendKey(keyC)
        guard let selected = await readClipboard(changedFrom: changeBefore),
              !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            StatusHUD.shared.show(icon: "text.cursor", text: "Select some text first.", persist: 2)
            restore(savedClipboard, to: pb)
            return
        }
        // Nothing to proofread in a bare URL / path / email / code token — skip the model so it can't
        // mangle it or go conversational, and leave it untouched.
        if isNonProse(selected) {
            StatusHUD.shared.show(icon: "checkmark", text: "Nothing to change.", persist: 1.2)
            restore(savedClipboard, to: pb)
            return
        }
        // Decide now — while focus is still on the target — whether we can replace the selection in
        // place. Read-only text (a sent message, a web page, a PDF) can't be pasted into.
        let editable = isSelectionEditable()

        StatusHUD.shared.show(icon: "text.badge.checkmark", text: "Proofreading…", spinner: true)
        let corrected: String
        do {
            corrected = try await correct(selected)
        } catch {
            StatusHUD.shared.show(icon: "exclamationmark.triangle",
                text: "Couldn't proofread — \(error.localizedDescription)", persist: 4)
            restore(savedClipboard, to: pb)
            return
        }
        let unchanged = corrected.trimmingCharacters(in: .whitespacesAndNewlines)
            == selected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !corrected.isEmpty, !unchanged else {
            StatusHUD.shared.show(icon: "checkmark", text: "Nothing to change.", persist: 1.5)
            restore(savedClipboard, to: pb)
            return
        }

        if editable {
            // Paste the correction back over the selection, then restore the user's clipboard.
            pb.clearContents()
            pb.setString(corrected, forType: .string)
            sendKey(keyV)
            StatusHUD.shared.show(icon: "checkmark.circle.fill", text: "Proofread", persist: 1.2)
            try? await Task.sleep(nanoseconds: 250_000_000)   // let the paste land before restoring
            restore(savedClipboard, to: pb)
        } else {
            // Read-only selection: pasting would silently fail. Restore the user's clipboard and show
            // the corrected text in a card they can copy from — so Proofread still works on web pages,
            // PDFs, and already-sent messages, just as a copy-out instead of an in-place edit.
            restore(savedClipboard, to: pb)
            StatusHUD.shared.hide()
            FloatingPanelController.shared.present(
                AnyView(FloatingResultView(title: "Proofread", result: .text(corrected))), anchor: nil)
        }
    }

    /// Whether the focused element's selection can be replaced (so paste-back will actually work).
    /// Uses the Accessibility tree: selected-text/value settable, or a known editable role. String
    /// literals for the attribute names avoid the non-concurrency-safe `kAX…` globals.
    private func isSelectionEditable() -> Bool {
        let system = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, "AXFocusedUIElement" as CFString, &focusedRef) == .success,
              let focused = focusedRef, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return false }
        let element = focused as! AXUIElement

        func settable(_ attr: String) -> Bool {
            var flag: DarwinBoolean = false
            return AXUIElementIsAttributeSettable(element, attr as CFString, &flag) == .success && flag.boolValue
        }
        if settable("AXSelectedText") || settable("AXValue") { return true }

        var roleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, "AXRole" as CFString, &roleRef) == .success,
           let role = roleRef as? String {
            return ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(role)
        }
        return false
    }

    /// Accumulate the engine's correction to a full string (can't stream into another app's field),
    /// then clean it so a chatty small model can't paste labels or extra example turns.
    private func correct(_ text: String) async throws -> String {
        var out = ""
        for try await delta in intelligence.respond(prompt: GrammarFixAction.framedPrompt(for: text),
                                                    context: nil) {
            out += delta
        }
        let cleaned = GrammarFixAction.cleanCorrection(out)
        // If the model went conversational (asked a question / refused) or returned nothing, keep the
        // original verbatim — never replace the user's text with a refusal.
        return (cleaned.isEmpty || looksLikeRefusal(cleaned)) ? text : cleaned
    }

    /// A bare URL / file path / email / code token has no prose to correct — skip the model entirely.
    private func isNonProse(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.contains(where: \.isWhitespace) else { return false }   // has spaces → treat as prose
        if t.contains("://") || t.lowercased().hasPrefix("www.") { return true }   // URL
        if t.contains("@"), t.contains(".") { return true }                        // email
        if t.hasPrefix("/") || t.hasPrefix("~/") || t.hasPrefix("./") { return true }  // path
        return t.filter(\.isLetter).count < 2                                      // numbers/symbols
    }

    /// Heuristic: did the model answer conversationally instead of returning corrected text? Guards
    /// against pasting "I'm not sure what you meant…"-style replies over the user's selection.
    private func looksLikeRefusal(_ s: String) -> Bool {
        let t = s.lowercased()
        let markers = ["i'm not sure", "i am not sure", "not sure what", "please provide",
                       "you'd like me to", "you would like me to", "i'll try to", "i will try to",
                       "as an ai", "i cannot", "i can't help", "could you clarify", "what would you like",
                       "there is no text", "no text to correct", "please share"]
        return markers.contains { t.contains($0) }
    }

    // MARK: - Clipboard & key simulation

    /// Poll the pasteboard until its changeCount moves (the copy landed), up to ~0.7s.
    private func readClipboard(changedFrom change: Int) async -> String? {
        let pb = NSPasteboard.general
        for _ in 0..<24 {
            if pb.changeCount != change { return pb.string(forType: .string) }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        return nil
    }

    private func restore(_ string: String?, to pb: NSPasteboard) {
        guard let string else { return }
        pb.clearContents()
        pb.setString(string, forType: .string)
    }

    private func sendKey(_ keyCode: CGKeyCode) {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    // MARK: - Accessibility permission

    private func ensureAccessibility() -> Bool {
        if AXIsProcessTrusted() { return true }
        // Prompts the user (and adds Lasso to the Accessibility list) the first time. Use the literal
        // option key — the `kAXTrustedCheckOptionPrompt` global isn't concurrency-safe under Swift 6.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    private func openAccessibilitySettings() {
        let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Lightweight status HUD

/// A small transient floating HUD (spinner / icon + message) for quick-action feedback that has no
/// panel of its own — e.g. the in-place grammar fix.
@MainActor
final class StatusHUD {
    static let shared = StatusHUD()
    private init() {}

    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    /// Show the HUD. `persist` auto-hides after that many seconds; nil keeps it until replaced/hidden.
    func show(icon: String, text: String, spinner: Bool = false, persist: Double? = nil) {
        hideTask?.cancel()
        let hosting = NSHostingController(rootView: StatusHUDView(icon: icon, text: text, spinner: spinner))
        // sizingOptions MUST be [] — any non-empty value makes the hosting view drive the window size,
        // which recurses into layout on scaled displays and overflows the stack (this was the
        // grammar-hotkey crash). Size the window once from fittingSize instead.
        hosting.sizingOptions = []

        let panel = self.panel ?? makePanel()
        panel.contentViewController = hosting
        panel.layoutIfNeeded()
        var size = hosting.view.fittingSize
        if size.width < 60 { size.width = 220 }
        if size.height < 28 { size.height = 44 }
        panel.setContentSize(size)
        positionNearBottom(panel)
        panel.orderFrontRegardless()
        self.panel = panel

        if let persist {
            hideTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(persist * 1_000_000_000))
                if !Task.isCancelled { self?.hide() }
            }
        }
    }

    func hide() {
        hideTask?.cancel()
        panel?.orderOut(nil)
        panel = nil
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 220, height: 44),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        return panel
    }

    private func positionNearBottom(_ panel: NSPanel) {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: screen.midX - size.width / 2,
                                     y: screen.minY + 120))
    }
}

private struct StatusHUDView: View {
    let icon: String
    let text: String
    let spinner: Bool

    var body: some View {
        HStack(spacing: 9) {
            if spinner {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(.tint)
            }
            Text(text).font(.callout).lineLimit(2)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.12)))
        .fixedSize()
        .frame(maxWidth: 360)
    }
}
