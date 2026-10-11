import Foundation
import AppKit

/// Detects a local Ollama install and, when the user opts in, starts its server. Lasso never manages
/// Ollama's lifecycle beyond launching it: it opens Ollama.app (which runs its own background server)
/// or, for a CLI-only install (e.g. Homebrew), runs `ollama serve`. This build is non-sandboxed, so
/// launching is permitted.
enum OllamaLauncher {
    private static let cliPaths = ["/opt/homebrew/bin/ollama", "/usr/local/bin/ollama", "/usr/bin/ollama"]

    /// The Ollama.app bundle, if installed in /Applications.
    static var appURL: URL? {
        let url = URL(fileURLWithPath: "/Applications/Ollama.app")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// A working `ollama` CLI. `isExecutableFile` follows symlinks, so a dangling link left behind by
    /// an uninstalled app is correctly ignored.
    static var cliPath: String? {
        cliPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// True when we have a way to start Ollama (so the UI only offers it when it can deliver).
    static var isInstalled: Bool { appURL != nil || cliPath != nil }

    /// Start Ollama (app preferred) and wait briefly for the server to answer. No-op returning true if
    /// it's already up. Returns false if Ollama isn't installed or didn't come up in time.
    @discardableResult
    static func start() async -> Bool {
        if await OllamaEndpoint.isReachable(OllamaEndpoint.baseURL) { return true }

        if let appURL {
            NSWorkspace.shared.open(appURL)
        } else if let cliPath {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: cliPath)
            task.arguments = ["serve"]
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            try? task.run()   // detached: keeps running after Lasso quits (reparented to launchd)
        } else {
            return false
        }

        // The server takes a moment to bind the port — poll up to ~8s.
        for _ in 0..<16 {
            try? await Task.sleep(for: .milliseconds(500))
            if await OllamaEndpoint.isReachable(OllamaEndpoint.baseURL) { return true }
        }
        return false
    }
}
