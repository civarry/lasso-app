import Foundation

/// Runs a package's `shortcut` command: one of the user's own Shortcuts, by name, through Apple's
/// `/usr/bin/shortcuts` (spec, "shortcut"). Nothing new runs on the Mac.
enum PackageShortcut {
    enum RunError: LocalizedError, Equatable {
        case notInstalled(String)
        case failed(String)
        case timedOut(Int)

        var errorDescription: String? {
            switch self {
            case .notInstalled(let name): "You don't have the Shortcut “\(name)”. Get it from the package's page in Settings › Packages."
            case .failed(let why): why.isEmpty ? "The Shortcut failed." : "The Shortcut failed: \(why)"
            case .timedOut(let s): "The Shortcut didn't finish in \(s) seconds, so Lasso stopped it."
            }
        }
    }

    static let tool = "/usr/bin/shortcuts"

    /// The user's Shortcut names, read at most every 10 seconds (`shortcuts list` takes a moment).
    private static let cache = Cache()

    final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var names: Set<String>?
        private var read = Date.distantPast
        func get() -> Set<String>? { lock.withLock { Date().timeIntervalSince(read) < 10 ? names : nil } }
        func set(_ value: Set<String>) { lock.withLock { names = value; read = Date() } }
        func clear() { lock.withLock { names = nil } }
    }

    static func installedNames() async -> Set<String> {
        if let names = cache.get() { return names }
        let tmp = FileManager.default.temporaryDirectory
        guard let finished = try? await Spawned.run([tool, "list"], environment: ["PATH": PackageScript.path, "HOME": NSHomeDirectory()],
                                                    directory: tmp, stdin: Data(), timeout: 15) else { return [] }
        let names = Set(String(decoding: finished.stdout, as: UTF8.self).split(separator: "\n").map(String.init))
        cache.set(names)
        return names
    }

    /// Last known answer without waiting (for menus); refreshed in the background.
    static func isInstalledNow(_ name: String) -> Bool? {
        guard let names = cache.get() else {
            Task.detached { _ = await installedNames() }
            return nil
        }
        return names.contains(name)
    }

    static func forget() { cache.clear() }

    /// Runs it with `text` as its input; returns what it output, as text.
    static func run(_ run: PackageShortcutRun, text: String?) async throws -> String {
        guard await installedNames().contains(run.name) else { throw RunError.notInstalled(run.name) }
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appending(path: "lasso-shortcut-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        var arguments = [tool, "run", run.name]
        if let text {
            let input = folder.appending(path: "input.txt")
            try Data(text.utf8).write(to: input)
            arguments += ["--input-path", input.path]
        }
        let output = folder.appending(path: "output.txt")
        arguments += ["--output-path", output.path, "--output-type", "public.plain-text"]
        let finished = try await Spawned.run(arguments, environment: ["PATH": PackageScript.path, "HOME": NSHomeDirectory()],
                                             directory: folder, stdin: Data(), timeout: run.timeout)
        if finished.timedOut { throw RunError.timedOut(Int(run.timeout)) }
        guard finished.status == 0 else {
            let line = String(decoding: finished.stderr, as: UTF8.self).split(separator: "\n").last.map(String.init) ?? ""
            throw RunError.failed(line)
        }
        let text = (try? String(contentsOf: output, encoding: .utf8)) ?? String(decoding: finished.stdout, as: UTF8.self)
        return String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4000))
    }
}
