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
        let hosting = NSHostingView(rootView: root)
        hosting.frame = CGRect(origin: .zero, size: shot.frame.size)
        contentView = hosting
        setFrame(shot.frame, display: true)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
