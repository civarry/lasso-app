import AppKit
import SwiftUI

/// Borderless floating panel that can become key (so buttons + Esc work), and dismisses on Esc.
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) {
        FloatingPanelController.shared.close()
    }
}

/// Hosts a result card in a floating window that's independent of the capture freeze overlay: once
/// you've selected (we have the crop), the freeze drops and the result floats above other windows,
/// persisting until you close it (✕ / Esc). The panel auto-resizes to its content and grows
/// downward (top-left anchored), so streamed answers / Ask AI input aren't clipped.
@MainActor
final class FloatingPanelController: NSObject, NSWindowDelegate {
    static let shared = FloatingPanelController()
    private var panel: FloatingPanel?
    private var topLeft: NSPoint = .zero

    /// `anchor` is the selection in global screen coordinates (AppKit, bottom-left origin), so the
    /// card appears at the selection (below it, flipping above).
    func present(_ content: AnyView, anchor: CGRect?) {
        close()

        // Crash-safe auto-grow. SwiftUI must NOT drive the window (sizingOptions = []) — its animated
        // auto-resize recurses into layout and overflows the stack on scaled displays. Instead the
        // content reports its ideal size and *we* resize the window (see `resize(toContent:)`):
        // asynchronously, rounded to whole points, past a 1pt threshold — so the card still grows with
        // streaming / expanding content (Ask AI, Identify) but can never recurse.
        let root = SelfSizingContent(content: content) { [weak self] ideal in
            self?.resize(toContent: ideal)
        }
        let hosting = NSHostingController(rootView: AnyView(root))
        hosting.sizingOptions = []

        let panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 200),
            styleMask: [.borderless],
            backing: .buffered, defer: false)
        panel.contentViewController = hosting
        panel.delegate = self
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        panel.layoutIfNeeded()
        // Initial size from the content's ideal; growth afterwards comes via `resize(toContent:)`.
        var size = hosting.view.fittingSize
        if size.width < 100 { size.width = 480 }
        size.height = min(max(size.height, 140), 900)
        let origin = origin(for: size, anchor: anchor)
        topLeft = NSPoint(x: origin.x, y: origin.y + size.height)
        panel.setFrame(NSRect(origin: origin, size: size), display: false)

        // Activate so text fields (Ask AI) receive keystrokes; the panel still floats and persists.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    /// Resize to the content's ideal size, keeping the top-left fixed. Async + integer + 1pt threshold:
    /// async means each resize is its own runloop turn (no synchronous recursion → no stack overflow),
    /// and integer rounding + threshold absorb the sub-pixel jitter that caused the infinite loop.
    private func resize(toContent ideal: CGSize) {
        let w = min(max(ideal.width.rounded(), 120), 1000)
        let h = min(max(ideal.height.rounded(), 80), 900)
        DispatchQueue.main.async { [weak self] in
            guard let self, let panel = self.panel else { return }
            let current = panel.frame.size
            guard abs(current.width - w) > 1 || abs(current.height - h) > 1 else { return }
            var frame = NSRect(x: self.topLeft.x, y: self.topLeft.y - h, width: w, height: h)
            if let visible = panel.screen?.visibleFrame, frame.origin.y < visible.minY + 8 {
                frame.origin.y = visible.minY + 8
            }
            panel.setFrame(frame, display: true)
        }
    }

    func close() {
        panel?.delegate = nil
        panel?.orderOut(nil)
        panel = nil
    }

    /// Keep the top-left fixed as content grows (grow downward), clamped on-screen.
    func windowDidResize(_ notification: Notification) {
        guard let panel else { return }
        var frame = panel.frame
        frame.origin.x = topLeft.x
        frame.origin.y = topLeft.y - frame.size.height
        if let visible = panel.screen?.visibleFrame, frame.origin.y < visible.minY + 8 {
            frame.origin.y = visible.minY + 8
        }
        if frame.origin != panel.frame.origin {
            panel.setFrameOrigin(frame.origin)
        }
    }

    /// Position below the selection, flipping above if it would go off-screen; clamps on-screen.
    private func origin(for size: NSSize, anchor: CGRect?) -> NSPoint {
        let screen = anchor.flatMap { a in NSScreen.screens.first { $0.frame.intersects(a) } }
            ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero

        guard let anchor else {
            return NSPoint(x: visible.maxX - size.width - 24, y: visible.maxY - size.height - 24)
        }

        let gap: CGFloat = 14
        let margin: CGFloat = 12
        let x = min(max(anchor.minX, visible.minX + margin), visible.maxX - size.width - margin)

        var y = anchor.minY - gap - size.height   // below the selection
        if y < visible.minY + margin {
            y = anchor.maxY + gap                  // flip above
            if y + size.height > visible.maxY - margin {
                y = max(visible.minY + margin, visible.maxY - size.height - margin)
            }
        }
        return NSPoint(x: x, y: y)
    }
}

/// Wraps a result view so it reports its *ideal* size (independent of the window) to the controller,
/// which resizes the window to match. `fixedSize(vertical:)` makes the content express its full ideal
/// height regardless of the current window height, so the measurement never depends on — and so never
/// feeds back into — the window size.
private struct SelfSizingContent: View {
    let content: AnyView
    let onIdealSize: (CGSize) -> Void

    var body: some View {
        content
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { onIdealSize($0) }
    }
}
