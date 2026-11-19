import Testing
import Foundation
import AppKit
@testable import Lasso

/// Agent replies point to images with Hermes's `MEDIA:/path` line; Lasso's `/v1/runs` connection gets
/// it as text, so the chat must turn it into a picture (seen: "MEDIA:/tmp/demo.jpg" printed raw).
struct AgentMediaTests {
    @Test func directiveLinesAreTakenOutOfTheText() {
        let split = AgentMedia.split("Here's one:\n\nMEDIA:/tmp/a.png\n\nand `MEDIA:` inline stays.\nMEDIA:file:///tmp/b.jpg")
        #expect(split.paths == ["/tmp/a.png", "/tmp/b.jpg"])
        #expect(split.text == "Here's one:\n\nand `MEDIA:` inline stays.")
        #expect(AgentMedia.split("MEDIA:relative/x.png").paths.isEmpty)
    }

    @Test func anImageFileBecomesAPictureAndOthersStayAsPaths() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "agent-media-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = dir.appending(path: "dot.png")
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 3, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        try #require(rep.representation(using: .png, properties: [:])).write(to: png)
        let notes = dir.appending(path: "notes.txt")
        try Data("hi".utf8).write(to: notes)

        let out = AgentMedia.resolve("Done.\nMEDIA:\(png.path)\nMEDIA:\(notes.path)\nMEDIA:/nope/missing.png")
        #expect(out.images.count == 1)
        #expect(out.images.first?.image.width == 4)
        #expect(out.images.first?.path == png.path)
        #expect(out.text == "Done.\n\n`\(notes.path)`\n`/nope/missing.png`")
    }
}
