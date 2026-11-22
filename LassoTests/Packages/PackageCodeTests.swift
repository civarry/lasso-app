import Foundation
import Testing
@testable import Lasso

/// The `code` surface (a package's button on chat code blocks), the console answer a script gives it,
/// and commands with no surface that only the package's own buttons run.
@MainActor
@Suite(.serialized)
struct PackageCodeTests {
    static let head = #"{"lasso": 1, "id": "x-y", "version": "1.0.0", "name": "X", "summary": "x", "author": "Me", "commands": ["#

    func problems(_ commands: String) -> [String] {
        PackageValidator.validate(Data((Self.head + commands + "]}").utf8)).problems.map(\.description)
    }

    @Test func theValidatorKnowsCodeCommands() {
        let ok = #"{"id": "run", "title": "Run", "surfaces": ["code"], "languages": ["Python", "py"], "input": ["text"], "output": "markdown", "run": {"script": {"path": "scripts/r.py"}}}"#
        let package = PackageValidator.validate(Data((Self.head + ok + "]}").utf8)).package
        #expect(package?.commands.first?.languages == ["python", "py"])
        #expect(problems(#"{"id": "run", "title": "Run", "surfaces": ["code"], "input": ["text"], "output": "markdown", "run": {"script": {"path": "scripts/r.py"}}}"#)
            .contains { $0.contains("Required with the \"code\" surface") })
        #expect(problems(#"{"id": "run", "title": "Run", "surfaces": ["code", "slash"], "languages": ["py"], "input": ["text"], "output": "markdown", "run": {"script": {"path": "scripts/r.py"}}}"#)
            .contains { $0.contains("can't appear anywhere else") })
        #expect(problems(#"{"id": "run", "title": "Run", "surfaces": ["code"], "languages": ["py"], "input": ["text"], "output": "copy", "run": {"script": {"path": "scripts/r.py"}}}"#)
            .contains { $0.contains("shows in the code block") })
        #expect(problems(#"{"id": "run", "title": "Run", "surfaces": ["slash"], "languages": ["py"], "input": ["text"], "output": "markdown", "run": {"script": {"path": "scripts/r.py"}}}"#)
            .contains { $0.contains("Only for commands with the \"code\" surface") })
        // No surface: only a script, run from the package's own buttons.
        #expect(PackageValidator.validate(Data((Self.head + #"{"id": "install", "title": "Install", "surfaces": [], "input": ["text"], "output": "markdown", "run": {"script": {"path": "scripts/i.py", "network": true}}}"# + "]}").utf8)).package != nil)
        #expect(problems(#"{"id": "install", "title": "Install", "surfaces": [], "input": ["text"], "output": "markdown", "run": {"prompt": {"prompt": "x {{text}}"}}}"#)
            .contains { $0.contains("Only a script command can have no surfaces") })
    }

    @Test func aConsoleAnswerHasTextAPictureAndAtMostThreeButtons() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "lasso-console-\(UUID().uuidString.prefix(6))", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: base) }
        let places = PackageScript.Places(package: base.appending(path: "pkg"), data: base.appending(path: "data"),
                                          workspace: base.appending(path: "ws"), folders: [])
        for url in [places.package, places.data, places.workspace] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        let picture = places.workspace.appending(path: "drawing.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: picture)
        let answer: [String: Any] = [
            "console": "Hello", "image": picture.path, "failed": true,
            "actions": [
                ["title": "Install numpy", "command": "install", "input": ["packages": "numpy"], "rerun": true],
                ["title": "Fix it", "chat": "Fix this"],
                ["title": "Both", "command": "x", "chat": "y"],        // one or the other, never both
                ["title": "Fourth", "chat": "a"], ["title": "Fifth", "chat": "b"],
            ],
        ]
        let output = try PackageScript.parse(JSONSerialization.data(withJSONObject: answer), places: places, tmp: base, id: "ws")
        guard case .console(let console) = output else { Issue.record("not a console: \(output)"); return }
        #expect(console.text == "Hello" && console.failed)
        #expect(console.image?.lastPathComponent == "drawing.png")
        #expect(console.actions.map(\.title) == ["Install numpy", "Fix it"])
        #expect(console.actions[0].input == ["packages": "numpy"] && console.actions[0].rerun)

        // A picture outside its own folders is refused.
        let outside: [String: Any] = ["console": "x", "image": "/etc/hosts"]
        #expect(throws: (any Error).self) {
            _ = try PackageScript.parse(JSONSerialization.data(withJSONObject: outside), places: places, tmp: base, id: "ws")
        }
    }

    @Test func codeBlocksGetButtonsByLanguageFromEnabledPackages() throws {
        let name = "lasso-codecmd-\(UUID().uuidString.prefix(6))"
        let base = FileManager.default.temporaryDirectory.appending(path: name, directoryHint: .isDirectory)
        let real = PackageStore.shared
        let store = PackageStore(root: base.appending(path: "Packages"), defaults: UserDefaults(suiteName: name)!)
        PackageStore.shared = store
        defer { PackageStore.shared = real; real.reload(); try? FileManager.default.removeItem(at: base) }
        let manifest = Self.head.replacingOccurrences(of: "x-y", with: "py-run")
            + #"{"id": "run", "title": "Run", "surfaces": ["code"], "languages": ["python", "py"], "input": ["text"], "output": "markdown", "run": {"script": {"path": "scripts/r.py"}}}]}"#
        try store.install(Data(manifest.utf8), files: ["scripts/r.py": Data("#!/bin/sh\n".utf8)], origin: .file)
        #expect(CodeRunner.shared.commands(for: "Python").map(\.command.id) == ["run"])
        #expect(CodeRunner.shared.commands(for: "py").count == 1)
        #expect(CodeRunner.shared.commands(for: "swift").isEmpty)
        #expect(CodeRunner.shared.commands(for: nil).isEmpty)
        store.setEnabled("py-run", false)
        #expect(CodeRunner.shared.commands(for: "python").isEmpty, "a package that's off offers nothing")
    }
}
