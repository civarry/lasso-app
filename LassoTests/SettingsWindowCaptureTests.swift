import Testing
import AppKit
import SwiftUI
@testable import Lasso

/// Opens the app's real Settings window (its Settings scene, with the real toolbar) on a given page and
/// keeps it on screen, writing its window number to a file so a capture tool can photograph exactly that
/// window. Offscreen snapshots draw neither the toolbar nor the sidebar. Opt-in:
/// TEST_RUNNER_LASSO_SETTINGS_WINDOW=<file for the window number>, TEST_RUNNER_LASSO_SETTINGS_ROUTE=<route>.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["LASSO_SETTINGS_WINDOW"] != nil))
struct SettingsWindowCaptureTests {
    @Test(.timeLimit(.minutes(1))) func holdTheRealSettingsWindow() async throws {
        let out = try #require(ProcessInfo.processInfo.environment["LASSO_SETTINGS_WINDOW"])
        let route = ProcessInfo.processInfo.environment["LASSO_SETTINGS_ROUTE"].flatMap(SettingsRoute.init(rawValue:))
        UserDefaults.standard.set((route?.pane ?? .general).rawValue, forKey: SettingsView.paneKey)
        if let route { UserDefaults.standard.set(route.rawValue, forKey: SettingsView.routeKey) }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        // The way the app opens it: SwiftUI's openWindow action, from a view hosted inside the app.
        let opener = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        opener.contentView = NSHostingView(rootView: SettingsOpener())
        opener.orderFrontRegardless()
        try await Task.sleep(for: .seconds(3))
        opener.orderOut(nil)
        let window = try #require(NSApp.windows.first { $0.isVisible && $0.frame.width > 600 }, "Settings didn't open")
        // The menu-bar fix brings this window forward by looking it up: it must find it.
        print("[settings-window] identifier=\(window.identifier?.rawValue ?? "nil")")
        #expect(SettingsWindow.window === window, "SettingsWindow.window can't find the Settings window")
        SettingsWindow.bringForward()
        #expect(window.isKeyWindow)
        window.makeKeyAndOrderFront(nil)
        print("[settings-window] number=\(window.windowNumber) title=\(window.title) toolbarStyle=\(window.toolbarStyle.rawValue) items=\(window.toolbar?.items.map(\.itemIdentifier.rawValue) ?? [])")
        try "\(window.windowNumber)".write(toFile: out, atomically: true, encoding: .utf8)
        try await Task.sleep(for: .seconds(8))
        window.close()
    }
}

private struct SettingsOpener: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View { Color.clear.onAppear { SettingsWindow.open(with: openWindow) } }
}
