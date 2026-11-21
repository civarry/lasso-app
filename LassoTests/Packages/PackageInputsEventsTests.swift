import CoreGraphics
import Foundation
import Testing
@testable import Lasso

/// Build 0.25: the capture image and text positions for packages, event commands the user lets run
/// by themselves, and three more patch targets.
@MainActor
@Suite(.serialized)
struct PackageInputsEventsTests {
    static func manifest(_ command: String, id: String = "probe", version: String = "1.0.0") -> String {
        #"{"lasso": 1, "id": "\#(id)", "version": "\#(version)", "name": "Probe", "summary": "x", "author": "Me", "commands": [\#(command)]}"#
    }
    private func problems(_ command: String) -> [String] {
        PackageValidator.validate(Data(Self.manifest(command).utf8)).problems.map(\.description)
    }

    @Test func imageAndLinesComeFromACapture() {
        let ok = #"{"id": "c", "title": "C", "surfaces": ["toolbar"], "input": ["image", "lines"], "output": "markdown", "run": {"script": {"path": "scripts/s.py"}}}"#
        #expect(problems(ok).isEmpty, "\(problems(ok))")
        #expect(problems(ok.replacingOccurrences(of: #"["toolbar"]"#, with: #"["slash"]"#))
            .contains { $0.contains("comes from a capture") })
        let http = #"{"id": "c", "title": "C", "surfaces": ["toolbar"], "input": ["image"], "output": "markdown", "run": {"http": {"method": "POST", "url": "https://x.example.com/a"}}}"#
        #expect(PackageValidator.validate(Data(Self.manifest(http).replacingOccurrences(of: #""commands""#, with: #""hosts": ["x.example.com"], "commands""#).utf8))
            .problems.contains { $0.message.contains("not a web request") })
    }

    @Test func eventCommandsHaveTheirOwnRules() {
        let ok = #"{"id": "log", "title": "Log", "surfaces": ["event"], "on": ["capture", "reply"], "input": ["text"], "output": "file", "run": {"script": {"path": "scripts/s.py"}}}"#
        #expect(problems(ok).isEmpty, "\(problems(ok))")
        #expect(problems(ok.replacingOccurrences(of: #", "on": ["capture", "reply"]"#, with: "")).contains { $0.contains("Required with the \"event\" surface") })
        #expect(problems(ok.replacingOccurrences(of: #""output": "file""#, with: #""output": "markdown""#)).contains { $0.contains("notify or file") })
        #expect(problems(ok.replacingOccurrences(of: #""input": ["text"]"#, with: #""input": ["image"]"#)).contains { $0.contains("A reply has only its text") })
        #expect(problems(ok.replacingOccurrences(of: #"["event"]"#, with: #"["event", "toolbar"]"#)).contains { $0.contains("can't appear anywhere else") })
    }

    /// A real script, in its sandbox, gets the capture as a PNG file it can read and the text positions.
    @Test func aScriptReadsTheCaptureImageAndTextPositions() async throws {
        let f = try PackageScriptTests.Fixture("""
            #!/usr/bin/env python3
            import json, os, sys
            data = json.load(sys.stdin)
            png = open(data["image"], "rb").read()
            print(json.dumps({"text": f"{png[1:4] == b'PNG'} {len(data['lines'])} {data['lines'][0]['text']} {round(data['lines'][0]['y'], 2)}"}))
            """)
        defer { f.clean() }
        let package = try #require(PackageValidator.validate(Data(Self.manifest(#"{"id": "c", "title": "C", "surfaces": ["toolbar"], "input": ["image", "lines"], "output": "markdown", "run": {"script": {"path": "scripts/run.sh"}}}"#).utf8)).package)
        let ctx = try #require(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(ctx.makeImage())
        let png = try #require(PackageInput.png(image))
        let input = PackageInput(text: "Total", image: png,
                                 lines: [OCRLine(string: "Total", boundingBox: CGRect(x: 0.1, y: 0.7, width: 0.2, height: 0.1))])
        let entry = PackageRegistry.Entry(package: package, values: [:], secrets: [], ready: true)
        var request = PackageScript.Request(command: "c", stdin: PackageScript.stdin(entry, package.commands[0], input: input),
                                            secrets: [:], run: PackageScriptRun(path: "scripts/run.sh", network: false, timeout: 10))
        request.inputFiles["capture.png"] = png
        let output = try await PackageScript.run(request, places: f.places)
        // y is from the top: a box at 0.7 to 0.8 from the bottom starts 0.2 from the top.
        #expect(output == .text("True 1 Total 0.2"), "\(output)")
    }

    @Test func eventsRunOnlyOnceAllowedAndAnUpdateTurnsThemOff() async throws {
        let name = "lasso-events-\(UUID().uuidString.prefix(6))"
        let base = FileManager.default.temporaryDirectory.appending(path: name, directoryHint: .isDirectory)
        let real = PackageStore.shared
        let store = PackageStore(root: base.appending(path: "Packages"), defaults: .standard)
        PackageStore.shared = store
        defer { PackageEvents.setAllowed(false, "reply-log"); PackageStore.shared = real; real.reload(); try? FileManager.default.removeItem(at: base) }
        let command = #"{"id": "log", "title": "Log", "surfaces": ["event"], "on": ["reply"], "input": ["text"], "output": "notify", "run": {"script": {"path": "scripts/log.sh"}}}"#
        let script = Data("#!/bin/sh\ncat >> \"$HOME/replies.log\"\necho\n".utf8)
        try store.install(Data(Self.manifest(command, id: "reply-log").utf8), files: ["scripts/log.sh": script], origin: .file)
        let log = store.dataRoot.appending(path: "reply-log/replies.log")
        // Its own list: other suites swap the shared one while this runs.
        let registry = PackageRegistry()
        let installed = try #require(store.installed.first { $0.id == "reply-log" }?.package)
        registry.update([installed], settings: { _ in ([:], []) }, places: { store.places(for: $0) })

        // Not allowed: nothing runs.
        #expect(PackageEvents.commands(for: .reply, registry: registry).isEmpty)
        PackageEvents.fire(.reply, input: PackageInput(text: "first"), registry: registry)
        try await Task.sleep(for: .milliseconds(600))
        #expect(!FileManager.default.fileExists(atPath: log.path))

        // Allowed: it runs on a reply, in its sandbox.
        PackageEvents.setAllowed(true, "reply-log")
        #expect(PackageEvents.commands(for: .reply, registry: registry).count == 1)
        #expect(PackageEvents.commands(for: .capture, registry: registry).isEmpty)
        PackageEvents.fire(.reply, input: PackageInput(text: "second"), registry: registry)
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: log.path) { try await Task.sleep(for: .milliseconds(50)) }
        #expect((try? String(contentsOf: log, encoding: .utf8))?.contains("second") == true)

        // An update that changes the script turns it off again.
        try store.install(Data(Self.manifest(command, id: "reply-log", version: "1.0.1").utf8),
                          files: ["scripts/log.sh": script + Data("# changed\n".utf8)], origin: .file)
        #expect(!PackageEvents.isAllowed("reply-log"))
    }

    @Test func theGreetingThePlaceholderAndIconsArePatchable() throws {
        let patches = """
        [{"target": "chat.greeting", "set": "What are we working on?"}, {"target": "chat.placeholder", "set": "Ask anything…"},
         {"target": "action.ai.summarize.symbol", "set": "list.bullet"}]
        """
        let json = #"{"lasso": 1, "id": "look", "version": "1.0.0", "name": "Look", "summary": "x", "author": "Me", "patches": \#(patches)}"#
        let package = try #require(PackageValidator.validate(Data(json.utf8)).package, "\(PackageValidator.validate(Data(json.utf8)).problems)")
        let applied = AppliedPatches.apply([package])
        #expect(applied.texts["chat.greeting"] == "What are we working on?")
        #expect(applied.texts["action.ai.summarize.symbol"] == "list.bullet")
        let bad = json.replacingOccurrences(of: "list.bullet", with: "not a symbol!")
        #expect(PackageValidator.validate(Data(bad.utf8)).problems.contains { $0.message.contains("SF Symbol") })
        PatchState.shared.update(applied)
        defer { PatchState.shared.update(PackageStore.shared.patches) }
        #expect(SummarizeAction(intelligence: .shared).systemImage == "list.bullet")
    }
}
