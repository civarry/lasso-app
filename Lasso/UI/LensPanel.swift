import AppKit
import SwiftUI

/// A floating, **resizable** card for Google Lens results, anchored to the selection. Separate from
/// `FloatingPanelController` (which auto-sizes its cards to content): a web view has no intrinsic
/// size, so this panel is user-resizable and the web view fills whatever size you drag it to.
///
/// It's a titled panel with the titlebar hidden + transparent and a clear background, so it reads as
/// a rounded card (the SwiftUI content draws the chrome) while keeping standard edge-drag resizing.
@MainActor
final class LensPanelController: NSObject, NSWindowDelegate {
    static let shared = LensPanelController()
    private var panel: NSPanel?

    func present(image: CGImage, anchor: CGRect?) {
        close()

        // Wide enough that Google serves its full two-column desktop Lens layout (AI Overview beside
        // the source list) rather than the cramped single-column view. Still user-resizable.
        let size = NSSize(width: 860, height: 680)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 360, height: 360)

        let hosting = NSHostingController(rootView: LensResultView(image: image))
        // [] so the hosting view never drives the window size (it fills via autoresizingMask and the
        // window is user-resizable) — non-empty options can recurse into layout and crash on scaled
        // displays.
        hosting.sizingOptions = []
        hosting.view.frame = NSRect(origin: .zero, size: size)
        hosting.view.autoresizingMask = [.width, .height]
        panel.contentViewController = hosting
        panel.delegate = self

        panel.setFrameOrigin(origin(for: size, anchor: anchor))
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    func close() {
        // Ordering the window out does not dismantle the SwiftUI hierarchy, so the queued Lens upload
        // would otherwise still reach Google after the card is gone. `present()` routes through here
        // too, so starting a new search also drops the previous one's pending request.
        LensSession.cancelPendingUpload()
        panel?.delegate = nil
        panel?.orderOut(nil)
        panel = nil
    }

    func windowWillClose(_ notification: Notification) {
        LensSession.cancelPendingUpload()
        panel = nil
    }

    /// Below the selection, flipping above if it would clip; clamped on-screen.
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
        var y = anchor.minY - gap - size.height
        if y < visible.minY + margin {
            y = anchor.maxY + gap
            if y + size.height > visible.maxY - margin {
                y = max(visible.minY + margin, visible.maxY - size.height - margin)
            }
        }
        return NSPoint(x: x, y: y)
    }
}
