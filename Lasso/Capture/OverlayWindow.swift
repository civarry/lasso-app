import AppKit
import SwiftUI

/// Borderless, transparent, screen-saver-level window covering one display. Hosts the frozen
/// image + selection UI. One per `NSScreen` (Spec §6).
final class OverlayWindow: NSWindow {
    init(shot: DisplayShot, coordinator: CaptureCoordinator) {
        super.init(
            contentRect: shot.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let root = CaptureSessionView(shot: shot, coordinator: coordinator)
        let hosting = FirstClickHostingView(rootView: root)
        hosting.frame = CGRect(origin: .zero, size: shot.frame.size)
        contentView = hosting
        setFrame(shot.frame, display: true)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Takes the first click even while Lasso isn't the active app. A hotkey only *asks* macOS to activate
/// Lasso, and that can be slow or declined; until it happens, macOS spends a click on a window that
/// doesn't accept first mouse on activating the app. On the overlay that click was the start of the
/// selection, so the drag didn't register and had to be done again.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
