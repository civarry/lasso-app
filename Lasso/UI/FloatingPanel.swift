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

        let hosting = NSHostingController(rootView: content)
        hosting.sizingOptions = .preferredContentSize

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
        let size = panel.frame.size
        let origin = origin(for: size, anchor: anchor)
        topLeft = NSPoint(x: origin.x, y: origin.y + size.height)
        panel.setFrameOrigin(origin)

        // Activate so text fields (Ask AI) receive keystrokes; the panel still floats and persists.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
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
