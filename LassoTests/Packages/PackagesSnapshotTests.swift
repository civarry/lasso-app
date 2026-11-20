import AppKit
import SwiftUI
import Testing
@testable import Lasso

/// Renders Settings › Packages in the states the UI review listed, against a throwaway store (never
/// this Mac's packages). Opt-in: TEST_RUNNER_LASSO_PACKAGES_SNAPSHOTS=<folder>.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["LASSO_PACKAGES_SNAPSHOTS"] != nil))
struct PackagesSnapshotTests {
    @Test func renderPackages() async throws {
        let folder = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LASSO_PACKAGES_SNAPSHOTS"]))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = "lasso-snap-packages-\(UUID().uuidString.prefix(6))"
        let root = FileManager.default.temporaryDirectory.appending(path: name, directoryHint: .isDirectory)
        let real = PackageStore.shared
        let store = PackageStore(root: root, defaults: UserDefaults(suiteName: name)!)
        PackageStore.shared = store
        defer { PackageStore.shared = real; real.reload(); try? FileManager.default.removeItem(at: root) }

        func snap<V: View>(_ name: String, width: CGFloat = 520, height: CGFloat = 640, _ view: V) async throws {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = NSHostingView(rootView: view.frame(width: width, height: height).background(SettingsPalette.pageFill))
            window.orderFrontRegardless()
            try await Task.sleep(for: .milliseconds(900))
            let content = try #require(window.contentView)
            let rep = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: rep)
            try #require(rep.representation(using: .png, properties: [:])).write(to: folder.appending(path: "\(name).png"))
            window.orderOut(nil); window.contentView = nil
        }
        let hub = { PackagesHub(webSearchOn: .constant(true), localOnly: false, openPackage: { _ in }) }

        try await snap("hub-empty", hub())

        let tavily = try #require(BundledPackages.data("tavily"))
        let serp = try #require(BundledPackages.data("serpapi"))
        try store.install(tavily, origin: .bundled)
        try store.install(serp, origin: .bundled, enabled: false)
        let brave = Data(PackageValidatorTests.search.utf8)
        try store.install(brave, origin: .file)
        let edited = String(decoding: brave, as: UTF8.self).replacingOccurrences(of: "\"name\": \"Brave\"", with: "\"name\": \"Brave Search\"")
        try Data(edited.utf8).write(to: root.appending(path: "brave-search/lasso.json"))
        try FileManager.default.createDirectory(at: root.appending(path: "broken-one"), withIntermediateDirectories: true)
        try store.install(Data(PackageValidatorTests.search.replacingOccurrences(of: "brave-search", with: "broken-one").utf8), origin: .pasted)
        try Data("{\"lasso\": 1, \"id\": \"broken-one\"}".utf8).write(to: root.appending(path: "broken-one/lasso.json"))
        store.reload()
        try await snap("hub-packages", hub())
        try await snap("page-tavily", height: 900, PackagePage(id: "tavily", localOnly: false, removed: {}))
        try await snap("page-changed", height: 700, PackagePage(id: "brave-search", localOnly: false, removed: {}))

        let sheet = { (preload: (Data, PackageStore.Origin)?, reviewing: String?) in
            AddPackageSheet(dismiss: {}, added: { _ in }, reviewing: reviewing, preload: preload)
        }
        store.remove("serpapi")
        try await snap("sheet-add", width: 480, height: 620, sheet(nil, nil))
        let other = PackageValidatorTests.search.replacingOccurrences(of: "brave-search", with: "brave-two")
        try await snap("sheet-review-file", width: 480, height: 640, sheet((Data(other.utf8), .file), nil))
        try await snap("sheet-review-changed", width: 480, height: 640, sheet(nil, "brave-search"))
        let bad = PackageValidatorTests.search
            .replacingOccurrences(of: "https://api.search.brave.com/res", with: "https://evil.example.com/res")
            .replacingOccurrences(of: "\"run\": {\"http\"", with: "\"run\": {\"prompt\": \"x\", \"http\"")
            .replacingOccurrences(of: "\"author\": \"Me\"", with: "\"author\": \"Me\", \"autor\": 1")
        try await snap("sheet-problems", width: 480, height: 520, sheet((Data(bad.utf8), .pasted), nil))
        try await snap("sheet-not-json", width: 480, height: 300, sheet((Data("{\"lasso\": 1,,}".utf8), .pasted), nil))

        // Step 2: a package of buttons and commands.
        let study = PackageCommandTests.study
        let hotkeyCmd = study.replacingOccurrences(of: "\"id\": \"study-tools\"", with: "\"id\": \"study-hotkey\"")
            .replacingOccurrences(of: "\"name\": \"Study tools\"", with: "\"name\": \"Rewrite\"")
            .replacingOccurrences(of: "\"surfaces\": [\"toolbar\", \"slash\"]", with: "\"surfaces\": [\"hotkey\"]")
            .replacingOccurrences(of: "\"when\": {\"minLength\": 40}, \"output\": \"markdown\"", with: "\"output\": \"replace\"")
        try await snap("sheet-review-study", width: 480, height: 700, sheet((Data(study.utf8), .file), nil))
        try store.install(Data(study.utf8), origin: .file)
        _ = hotkeyCmd
        try await snap("hub-commands", height: 760, hub())
        try await snap("page-study", height: 1000, PackagePage(id: "study-tools", localOnly: false, removed: {}))
    }
}
