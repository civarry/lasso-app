import Testing
import AppKit
@testable import Lasso

/// Opens the image viewer on a sample image and saves what it shows. Opt-in:
/// TEST_RUNNER_LASSO_VIEWER_SNAPSHOT=<file.png>.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["LASSO_VIEWER_SNAPSHOT"] != nil))
struct ImageViewerSnapshotTests {
    @Test func viewerShowsTheImageLarge() async throws {
        let out = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LASSO_VIEWER_SNAPSHOT"]))
        let size = NSSize(width: 1200, height: 800)
        let image = NSImage(size: size)
        image.lockFocus()
        NSGradient(colors: [.systemTeal, .systemIndigo])!.draw(in: NSRect(origin: .zero, size: size), angle: 30)
        ("Sample image" as NSString).draw(at: NSPoint(x: 60, y: 360),
            withAttributes: [.font: NSFont.boldSystemFont(ofSize: 90), .foregroundColor: NSColor.white])
        image.unlockFocus()
        let cg = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        ImageViewer.shared.show(cg, title: "sample.png", file: URL(fileURLWithPath: "/tmp/sample.png"))
        try await Task.sleep(for: .milliseconds(800))
        let window = try #require(NSApp.windows.first { $0.title == "sample.png" && $0.isVisible })
        let view = try #require(window.contentView)
        print("[viewer] window \(Int(window.frame.width))x\(Int(window.frame.height))")
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        try #require(rep.representation(using: .png, properties: [:])).write(to: out)
        ImageViewer.shared.close()
        #expect(!window.isVisible)
    }
}
