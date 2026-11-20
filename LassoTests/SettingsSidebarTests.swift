import AppKit
import SwiftUI
import Testing
@testable import Lasso

/// Settings has no sidebar button, so a sidebar dragged shut used to stay shut with no way back.
/// It must come back by itself. Needs a window on screen. Opt-in: TEST_RUNNER_LASSO_SETTINGS_SIDEBAR=1.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["LASSO_SETTINGS_SIDEBAR"] == "1"))
struct SettingsSidebarTests {
    private func splitView(in view: NSView) -> NSSplitView? {
        if let s = view as? NSSplitView { return s }
        for sub in view.subviews { if let s = splitView(in: sub) { return s } }
        return nil
    }

    @Test func draggedShutSidebarComesBack() async throws {
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 740, height: 600),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: SettingsView(intelligence: .shared))
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.contentView = nil }
        try await Task.sleep(for: .milliseconds(800))
        let content = try #require(window.contentView)
        let split = try #require(splitView(in: content))
        let sidebar = try #require(split.arrangedSubviews.first)
        #expect(sidebar.frame.width > 100)

        // What dragging the divider all the way left does.
        if let controller = split.delegate as? NSSplitViewController, let item = controller.splitViewItems.first {
            item.animator().isCollapsed = true
        } else {
            split.setPosition(0, ofDividerAt: 0)
        }
        try await Task.sleep(for: .milliseconds(1200))
        print("[sidebar] width after collapsing: \(sidebar.frame.width) hidden: \(split.isSubviewCollapsed(sidebar))")
        #expect(!split.isSubviewCollapsed(sidebar) && sidebar.frame.width > 100, "the sidebar stayed shut")
    }
}
