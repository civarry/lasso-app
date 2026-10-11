import Testing
import AppKit
@testable import Lasso

/// "After a selection it feels like it didn't register; you have to drag again" (Lens hotkey, 2026-10).
/// A hotkey only *asks* macOS to activate Lasso, and it can be slow or declined. While Lasso isn't
/// active, macOS spends the first click on a window that doesn't accept first mouse on activating the
/// app, so the drag never reached the selection gesture. The overlay must take the first click itself.
@MainActor
struct OverlayFirstClickTests {
    @Test func theOverlayTakesTheFirstClick() throws {
        let ctx = try #require(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let shot = DisplayShot(id: 1, image: try #require(ctx.makeImage()),
                               frame: CGRect(x: 0, y: 0, width: 200, height: 120), scale: 1)
        let window = OverlayWindow(shot: shot, coordinator: CaptureCoordinator.shared)
        defer { window.orderOut(nil) }
        let content = try #require(window.contentView)
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 100, y: 60),
                                                   modifierFlags: [], timestamp: 0,
                                                   windowNumber: window.windowNumber, context: nil,
                                                   eventNumber: 0, clickCount: 1, pressure: 1))
        let hit = content.hitTest(NSPoint(x: 100, y: 60)) ?? content
        #expect(hit.acceptsFirstMouse(for: down), "the first click would only activate Lasso")
    }
}
