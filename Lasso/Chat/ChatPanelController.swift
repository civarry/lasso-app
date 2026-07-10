import AppKit
import CoreGraphics
import SwiftUI

/// Hosts the Chat panel: a persistent, top-right floating window, independent of the capture overlay.
/// Toggled by the chat shortcut (⌥⌘A) and from the menu bar; can be opened pre-seeded from a capture
/// ("Continue in chat"). Reuses `FloatingPanel` (becomes key for typing, Esc closes).
@MainActor
final class ChatPanelController: NSObject, NSWindowDelegate {
    static let shared = ChatPanelController()
    private var panel: FloatingPanel?
    private var pasteMonitor: Any?

    private let defaultSize = NSSize(width: 420, height: 580)
    private static let widthKey = "chat.panel.width"
    private static let heightKey = "chat.panel.height"
    private static let xKey = "chat.panel.x"
    private static let yKey = "chat.panel.y"

    var isOpen: Bool { panel != nil }

    /// Show if hidden, hide if shown (the shortcut's press-again-to-dismiss behavior).
    func toggle() {
        if isOpen { close() } else { present() }
    }

    /// Open the panel seeded from a capture selection (text and/or image).
    func open(seedText: String?, seedImage: CGImage?) {
        ChatController.shared.seed(text: seedText, image: seedImage)
        present()
    }

    /// Open the panel continuing a one-shot exchange (e.g. Ask AI) so the user can ask follow-ups.
    func continueInChat(question: String, answer: String, context: String?, image: CGImage?) {
        ChatController.shared.continueWith(question: question, answer: answer,
                                           context: context, image: image)
        present()
    }

    func present() {
        if let panel {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            Task { await ChatController.shared.refreshCapabilities() }
            return
        }

        let size = savedSize()
        let hosting = NSHostingController(rootView: ChatView())
        // Fixed-size panel: don't let the hosting controller shrink the window to the SwiftUI
        // content's fitting size (which would collapse the empty conversation to a tiny box).
        hosting.sizingOptions = []

        let panel = FloatingPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .resizable],
            backing: .buffered, defer: false)
        panel.contentViewController = hosting
        panel.delegate = self
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true   // native shadow follows the rounded card; no see-through corner halo
        panel.hidesOnDeactivate = false
        // Off: movable-by-background swallows clicks on SwiftUI controls (turns them into window
        // drags). The header provides an explicit drag region instead (see ChatView.WindowDragArea).
        panel.isMovableByWindowBackground = false
        panel.minSize = NSSize(width: 340, height: 360)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // Reopen where the user last dragged it; otherwise top-right. Set *after* the content view is
        // installed so the hosting controller can't override it.
        let origin = savedOrigin(for: size) ?? topRightOrigin(for: size)
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
        installPasteMonitor()

        Task { await ChatController.shared.refreshCapabilities() }
    }

    func close() {
        if let panel { saveSize(panel.frame.size); saveOrigin(panel.frame.origin) }
        removePasteMonitor()
        panel?.delegate = nil
        panel?.orderOut(nil)
        panel = nil
    }

    // NSWindowDelegate: clear our reference if the panel closes itself (Esc).
    func windowWillClose(_ notification: Notification) {
        if let panel { saveSize(panel.frame.size); saveOrigin(panel.frame.origin) }
        removePasteMonitor()
        panel = nil
    }

    func windowDidMove(_ notification: Notification) {
        if let panel { saveOrigin(panel.frame.origin) }
    }

    // MARK: - ⌘V image paste

    /// Intercept ⌘V while the chat panel is key: if an image is on the clipboard, attach it and
    /// consume the event; otherwise let it through so text still pastes into the field normally.
    private func installPasteMonitor() {
        removePasteMonitor()
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let panel = self.panel, event.window == panel,
                  event.modifierFlags.contains(.command),
                  event.charactersIgnoringModifiers?.lowercased() == "v" else { return event }
            return ChatController.shared.pasteImageFromClipboard() ? nil : event
        }
    }

    private func removePasteMonitor() {
        if let pasteMonitor { NSEvent.removeMonitor(pasteMonitor) }
        pasteMonitor = nil
    }

    func windowDidResize(_ notification: Notification) {
        if let panel { saveSize(panel.frame.size) }
    }

    // MARK: - Geometry & persistence

    /// Top-right of the screen with the mouse (or main), inset from the menu bar / edge.
    private func topRightOrigin(for size: NSSize) -> NSPoint {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let margin: CGFloat = 16
        return NSPoint(x: visible.maxX - size.width - margin,
                       y: visible.maxY - size.height - margin)
    }

    private func savedSize() -> NSSize {
        let d = UserDefaults.standard
        let w = d.double(forKey: Self.widthKey)
        let h = d.double(forKey: Self.heightKey)
        guard w >= 340, h >= 360 else { return defaultSize }
        return NSSize(width: w, height: h)
    }

    private func saveSize(_ size: NSSize) {
        UserDefaults.standard.set(size.width, forKey: Self.widthKey)
        UserDefaults.standard.set(size.height, forKey: Self.heightKey)
    }

    /// Last-dragged origin, only if it still lands on a connected screen (handles an unplugged monitor
    /// or resolution change) — otherwise nil so we fall back to the top-right default.
    private func savedOrigin(for size: NSSize) -> NSPoint? {
        let d = UserDefaults.standard
        guard d.object(forKey: Self.xKey) != nil, d.object(forKey: Self.yKey) != nil else { return nil }
        let p = NSPoint(x: d.double(forKey: Self.xKey), y: d.double(forKey: Self.yKey))
        guard NSScreen.screens.contains(where: { $0.visibleFrame.intersects(NSRect(origin: p, size: size)) })
        else { return nil }
        return p
    }

    private func saveOrigin(_ p: NSPoint) {
        UserDefaults.standard.set(p.x, forKey: Self.xKey)
        UserDefaults.standard.set(p.y, forKey: Self.yKey)
    }
}
