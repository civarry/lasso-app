import Testing
import AppKit
import SwiftUI
@testable import Lasso

/// Every search entry must lead to a real place: its page belongs to the pane it names, and common
/// words find what people mean.
struct SettingsSearchTests {
    @Test func everyEntryLeadsToItsPane() {
        for entry in SettingsSearchEntry.all {
            if let route = entry.route { #expect(route.pane == entry.pane, "\(entry.label)") }
        }
        #expect(Set(SettingsSearchEntry.all.map(\.id)).count == SettingsSearchEntry.all.count, "duplicate entries")
    }

    @Test func commonWordsFindTheRightPage() {
        #expect(SettingsSearchEntry.results(for: "hotkey").allSatisfy { $0.route == .shortcuts })
        #expect(SettingsSearchEntry.results(for: "offline").map(\.label) == ["Local-only mode"])
        #expect(SettingsSearchEntry.results(for: "update").contains { $0.route == .softwareUpdate })
        #expect(SettingsSearchEntry.results(for: "tavily").first?.route == .searchKeys)
        #expect(SettingsSearchEntry.results(for: "  ").isEmpty)
    }
}

/// Renders each Settings pane and page in a real window and saves a PNG, so the layout can be looked at
/// without opening the app. Opt-in: TEST_RUNNER_LASSO_SETTINGS_SNAPSHOTS=<folder>.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["LASSO_SETTINGS_SNAPSHOTS"] != nil))
struct SettingsSnapshotTests {
    @Test func renderEveryPaneAndPage() async throws {
        let folder = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LASSO_SETTINGS_SNAPSHOTS"]))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let paneWas = UserDefaults.standard.string(forKey: SettingsView.paneKey)
        defer { UserDefaults.standard.set(paneWas, forKey: SettingsView.paneKey) }
        func snap(_ window: NSWindow, _ name: String) async throws {
            try await Task.sleep(for: .milliseconds(900))
            let view = try #require(window.contentView)
            let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            try #require(rep.representation(using: .png, properties: [:])).write(to: folder.appending(path: "\(name).png"))
        }
        func open(_ pane: SettingsPane, route: SettingsRoute? = nil) -> NSWindow {
            UserDefaults.standard.set(pane.rawValue, forKey: SettingsView.paneKey)
            if let route { UserDefaults.standard.set(route.rawValue, forKey: SettingsView.routeKey) }
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 740, height: 640),
                                  styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            window.identifier = NSUserInterfaceItemIdentifier("settings-snapshot")
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = NSHostingView(rootView: SettingsView(intelligence: .shared))
            window.orderFrontRegardless()
            return window
        }
        for pane in SettingsPane.allCases {
            let w = open(pane); try await snap(w, pane.rawValue); w.orderOut(nil); w.contentView = nil
        }
        // The Agent pane for Lasso's built-in agent (the Workspace row), whatever this Mac has set.
        let ownWas = UserDefaults.standard.object(forKey: HermesAgent.useOwnHermesKey)
        UserDefaults.standard.set(false, forKey: HermesAgent.useOwnHermesKey)
        let builtIn = open(.agent); try await snap(builtIn, "agent-builtin"); builtIn.orderOut(nil); builtIn.contentView = nil
        UserDefaults.standard.set(ownWas, forKey: HermesAgent.useOwnHermesKey)
        for route in SettingsRoute.allCases {
            let w = open(route.pane, route: route); try await snap(w, "\(route.pane.rawValue)-\(route.rawValue)"); w.orderOut(nil); w.contentView = nil
        }
    }
}
