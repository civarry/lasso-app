import Testing
import AppKit
import SwiftUI
@testable import Lasso

/// Renders each Settings pane in a real window and saves a PNG, so the layout can be looked at without
/// opening the app. Opt-in: TEST_RUNNER_LASSO_SETTINGS_SNAPSHOTS=<folder>.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["LASSO_SETTINGS_SNAPSHOTS"] != nil))
struct SettingsSnapshotTests {
    @Test func renderEveryPane() async throws {
        let folder = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LASSO_SETTINGS_SNAPSHOTS"]))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let paneWas = UserDefaults.standard.string(forKey: SettingsView.paneKey)
        defer { UserDefaults.standard.set(paneWas, forKey: SettingsView.paneKey) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 640),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = NSHostingView(rootView: SettingsView(intelligence: .shared))
        window.orderFrontRegardless()
        for pane in SettingsView.Pane.allCases {
            UserDefaults.standard.set(pane.rawValue, forKey: SettingsView.paneKey)
            try await Task.sleep(for: .milliseconds(900))
            let view = try #require(window.contentView)
            let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            try #require(rep.representation(using: .png, properties: [:]))
                .write(to: folder.appending(path: "\(pane.rawValue).png"))
        }
        window.orderOut(nil)
    }
}
