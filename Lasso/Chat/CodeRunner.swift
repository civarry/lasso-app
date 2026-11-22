import Foundation
import SwiftUI

/// Code blocks in chat replies with a package's button on them (the `code` surface): Run Python's
/// "Run" on python blocks. A run shows in the block's own console: "Run started", the script's
/// progress lines, its output or picture, and "Run completed in 605 ms", with the buttons the script
/// offers (Install numpy, Fix it). Only the user's click runs anything.
@MainActor
@Observable
final class CodeRunner {
    static let shared = CodeRunner()

    struct Run: Equatable {
        var title: String
        var lines: [String]
        var console: PackageScript.Console?
        var error: String?
        var running: Bool
        var started: Date
        var elapsed: TimeInterval?
        // What ran, so a button can run it again (after Install numpy).
        var packageID: String
        var commandID: String
        var code: String
        var language: String
        var reply: String
    }

    /// By message and code block.
    var runs: [String: Run] = [:]

    /// A block's runs: its reply, which answer of it (‹ n/N ›), which code block, and the code.
    static func key(_ message: UUID, _ code: String, index: Int = 0, version: Int = 0) -> String {
        "\(message.uuidString)#\(version)#\(index)#\(code.hashValue)"
    }

    /// The commands offered on a block of this language, from enabled packages.
    func commands(for language: String?) -> [(entry: PackageRegistry.Entry, command: PackageCommand)] {
        guard let language = language?.lowercased(), !language.isEmpty else { return [] }
        return PackageRegistry.shared.all.filter(\.ready).flatMap { entry in
            entry.package.commands.filter { $0.surfaces.contains(.code) && $0.languages.contains(language) }.map { (entry, $0) }
        }
    }

    func run(_ key: String) -> Run? { runs[key] }

    func start(_ entry: PackageRegistry.Entry, _ command: PackageCommand, code: String, language: String,
               reply: String, key: String) {
        runs[key] = Run(title: command.title, lines: ["Run started"], console: nil, error: nil, running: true,
                        started: Date(), elapsed: nil, packageID: entry.package.id, commandID: command.id,
                        code: code, language: language, reply: reply)
        execute(entry, command, key: key, action: nil, then: nil)
    }

    /// A button under the console.
    func perform(_ action: PackageScript.Console.Action, key: String) {
        guard let run = runs[key] else { return }
        if let chat = action.chat {
            ChatController.shared.send(text: chat)
            return
        }
        guard let name = action.command,
              let entry = PackageRegistry.shared.all.first(where: { $0.package.id == run.packageID && $0.ready }),
              let command = entry.package.command(name),
              let original = entry.package.command(run.commandID) else { return }
        var next = run
        next.lines = ["\(action.title) started"]
        next.console = nil
        next.error = nil
        next.running = true
        next.started = Date()
        next.elapsed = nil
        runs[key] = next
        execute(entry, command, key: key, action: action.input, then: action.rerun ? original : nil)
    }

    private func execute(_ entry: PackageRegistry.Entry, _ command: PackageCommand, key: String,
                         action: [String: String]?, then rerun: PackageCommand?) {
        guard let run = runs[key] else { return }
        let started = Date()
        Task {
            do {
                let result = try await PackageCommandRunner.run(
                    entry, command, input: PackageInput(text: run.code),
                    extra: ["language": run.language, "reply": run.reply], action: action,
                    progress: { line in Task { @MainActor in self.runs[key]?.lines.append(line) } })
                var console: PackageScript.Console
                switch result {
                case .console(let c): console = c
                case .text(let t): console = .init(text: t, image: nil, actions: [], failed: false)
                case .file(let url) where PackageScript.Console.pages.contains(url.pathExtension.lowercased()):
                    console = .init(text: "", image: nil, html: url, actions: [], failed: false)
                case .file(let url): console = .init(text: "", image: url, actions: [], failed: false)
                case .url(let url): console = .init(text: url.absoluteString, image: nil, actions: [], failed: false)
                case .stream(let s): console = .init(text: try await PackageCommandRunner.collect(s), image: nil, actions: [], failed: false)
                }
                if let rerun, !console.failed {
                    // Installed: run the code again, in the same console.
                    runs[key]?.lines.append(contentsOf: console.text.split(separator: "\n").map(String.init))
                    runs[key]?.lines.append("Running code again")
                    execute(entry, rerun, key: key, action: nil, then: nil)
                    return
                }
                runs[key]?.console = console
            } catch {
                runs[key]?.error = PackageOutput.failure(error, entry, command)
            }
            runs[key]?.running = false
            runs[key]?.elapsed = Date().timeIntervalSince(started)
        }
    }
}

/// Which reply a code block is in, set by chat so its blocks get packages' buttons. Nil elsewhere
/// (result cards), where blocks stay plain.
struct CodeBlockContext: Equatable {
    var message: UUID
    var reply: String
    var version = 0
}

private struct CodeBlockContextKey: EnvironmentKey {
    static let defaultValue: CodeBlockContext? = nil
}

extension EnvironmentValues {
    var codeBlockContext: CodeBlockContext? {
        get { self[CodeBlockContextKey.self] }
        set { self[CodeBlockContextKey.self] = newValue }
    }
}
