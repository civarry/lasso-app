import Testing
import AppKit
import SwiftUI
@testable import Lasso

/// Opening the chat (or a result card) brought an open Settings window in front of every other app:
/// activating an app brings its *main* and key windows forward, and a panel couldn't be main, so
/// Settings was. Reproduced in isolation; these check the mechanism deterministically: the panel that
/// opens must itself be the main window.
@MainActor
@Suite(.serialized)
struct PanelActivationTests {
    @Test func chatPanelBecomesTheMainWindow() async throws {
        let settings = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                                styleMask: [.titled], backing: .buffered, defer: false)
        settings.orderFront(nil)
        settings.makeMain()
        defer { settings.orderOut(nil) }

        ChatPanelController.shared.present()
        defer { ChatPanelController.shared.close() }
        let panel = try #require(ChatPanelController.shared.panel)
        try await Task.sleep(for: .milliseconds(200))
        #expect(panel.isMainWindow, "Settings stays main and is dragged forward with the chat")
        #expect(!settings.isMainWindow)
    }

    @Test func resultCardBecomesTheMainWindow() async throws {
        FloatingPanelController.shared.present(AnyView(Text("result")), anchor: nil)
        defer { FloatingPanelController.shared.close() }
        try await Task.sleep(for: .milliseconds(200))
        let main = NSApp.mainWindow
        #expect(main is FloatingPanel, "main window is \(String(describing: main))")
    }
}
