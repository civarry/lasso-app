import Foundation
import Observation

/// Lasso's own Hermes: a dedicated `lasso-app` profile that Lasso sets up, starts when the chat's Agent
/// is used, and stops when Agent is turned off, local-only is turned on, or Lasso quits. Hermes itself is
/// the user's install (Homebrew or its installer); nothing of it ships inside Lasso.
///
/// The profile is created fresh, not cloned from the user's own Hermes: nothing about how (or whether)
/// the user set up Hermes for themselves leaks in, their model, keys and memory included. Lasso owns two
/// things in it:
///   • `.env`: messaging-platform credentials are removed (a second gateway on the same bot token would
///     take the user's messages) and the API server key, host and port are Lasso's;
///   • `config.yaml`: a block at the end, between `HermesProfileFiles` markers, that turns on the API
///     server on loopback, sets the approval mode, turns every messaging platform off, and holds the
///     model (as `model:` and as a route) that makes Hermes think with the model chosen in Lasso, and
///     only that model. Hermes reads YAML with PyYAML,
///     where a repeated top-level key replaces the earlier one, so the block wins.
/// Lasso only ever writes to a profile it created (marked by `HermesProfileFiles.sentinel`), and only
/// ever signals processes it launched; cleaning up a gateway it lost track of is left to Hermes
/// (`--replace`, `hermes gateway stop`), which checks a PID's start time before acting on it.
@MainActor
@Observable
final class HermesRuntime {
    static let shared = HermesRuntime()

    enum State: Equatable {
        case notInstalled
        case notSetUp
        case settingUp
        case stopped
        case starting
        case running
        case failed(String)
    }

    /// What the gateway was started with; a change means a restart (both are read at start-up).
    struct Launch: Equatable {
        var route: HermesRoute?
        var letHermesDecide: Bool
        /// The package tools offered (`PackageRegistry.toolSignature`): Hermes reads its tool list once,
        /// when it starts, so a package tool turned on or off means a restart before the next turn.
        var tools = ""
    }

    /// Whether the next turn starts (or restarts) the gateway.
    func needsStart(for route: HermesRoute?) -> Bool {
        state != .running || process?.isRunning != true
            || active != Launch(route: route, letHermesDecide: HermesAgent.letHermesDecide, tools: PackageRegistry.shared.toolSignature())
    }

    nonisolated static let profileName = "lasso-app"

    private(set) var state: State = .notInstalled
    /// What the running gateway was started with.
    private(set) var active: Launch?
    var activeRoute: HermesRoute? { active?.route }
    /// The port the running gateway listens on (see `HermesProfileFiles.bindablePort`).
    private(set) var port = HermesProfileFiles.basePort

    private var process: Process?
    private var startTask: Task<HermesClient, Error>?
    /// Which start `startTask` is: a cancelled start finishing late must not clear a newer one's handle.
    private var startID: UUID?
    /// The after-crash cleanup at launch; a start waits for it, or it could stop the new gateway.
    private var cleanupTask: Task<Void, Never>?
    /// Bumped by `stop()`: a start that was already under way when it was called must not finish.
    private var generation = 0

    private init() { refresh() }

    // MARK: Locations

    /// Where installers put `hermes`. An app started from Finder has no shell PATH to search.
    nonisolated static func hermesExecutable(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        let candidates = ["/opt/homebrew/bin/hermes", "/usr/local/bin/hermes"]
            + [".local/bin/hermes", ".hermes/bin/hermes"].map { home.appending(path: $0).path }
        return candidates.lazy.map(URL.init(fileURLWithPath:))
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    nonisolated static var profileDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".hermes/profiles/\(profileName)")
    }

    /// Where Lasso's agent works: its commands start here and the files it makes go here, in a folder
    /// the user can see, not inside the hidden profile. The user's own Hermes keeps its own setting.
    nonisolated static var workspaceDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "LassoWorkspace", directoryHint: .isDirectory)
    }

    nonisolated static var logFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/Lasso/hermes-gateway.log")
    }

    /// The profile exists and Lasso made it. A profile of that name the user made is never adopted.
    nonisolated static var profileIsLassos: Bool {
        FileManager.default.fileExists(atPath: profileDirectory.appending(path: HermesProfileFiles.sentinel).path)
    }

    /// Lasso made it fresh (not the earlier clone of the user's own Hermes, which carried their model,
    /// keys and memory). A cloned one is replaced on the next setup.
    nonisolated static var profileIsFresh: Bool {
        let text = (try? String(contentsOf: profileDirectory.appending(path: HermesProfileFiles.sentinel), encoding: .utf8)) ?? ""
        return text.contains(HermesProfileFiles.freshMark)
    }

    var isInstalled: Bool { Self.hermesExecutable() != nil }
    var isSetUp: Bool {
        Self.profileIsLassos && Self.profileIsFresh
            && HermesProfileFiles.hasManagedBlock(
                (try? String(contentsOf: Self.profileDirectory.appending(path: "config.yaml"), encoding: .utf8)) ?? "")
            && !HermesAgent.managedKey.isEmpty
    }

    /// Re-reads what's on disk (after an install, or when Settings opens).
    func refresh() {
        switch state {
        case .settingUp, .starting, .running: return
        default: break
        }
        state = !isInstalled ? .notInstalled : (isSetUp ? .stopped : .notSetUp)
    }

    // MARK: Setup

    /// Creates (or repairs) Lasso's profile. Safe to run again: it clones only when the profile doesn't
    /// exist, re-filters `.env`, and rewrites only Lasso's block in `config.yaml`.
    func setUp() async throws {
        guard !PrivacyMode.localOnly else { throw HermesError.localOnly }
        guard let hermes = Self.hermesExecutable() else { state = .notInstalled; throw HermesRuntimeError.notInstalled }
        let wasRunning = state == .running
        state = .settingUp
        do {
            let dir = Self.profileDirectory
            if Self.profileIsLassos, !Self.profileIsFresh {
                // Lasso's own older profile, cloned from the user's Hermes: replace it with a fresh one.
                // (Its gateway isn't running: a profile that isn't set up is never started.)
                try await Self.run(hermes, ["profile", "delete", Self.profileName, "--yes"])
                Log.chat.notice("hermes runtime · replaced the cloned profile with a fresh one")
            }
            if !FileManager.default.fileExists(atPath: dir.path) {
                do {
                    try await Self.run(hermes, ["profile", "create", Self.profileName, "--no-alias",
                                                "--description", "Used by the Lasso app's chat Agent. Managed by Lasso."])
                } catch {
                    // It didn't exist a moment ago: whatever a failed create left is Lasso's to remove,
                    // or every later attempt would see a profile it didn't make.
                    try? FileManager.default.removeItem(at: dir)
                    throw error
                }
                try Self.writePrivate("Created by the Lasso app, which rewrites this profile's .env and the end of its config.yaml.\n\(HermesProfileFiles.freshMark)\n",
                                      to: dir.appending(path: HermesProfileFiles.sentinel))
            }
            guard Self.profileIsLassos else { throw HermesRuntimeError.profileTaken(dir.path) }
            var key = HermesAgent.managedKey
            if key.isEmpty {
                key = HermesProfileFiles.newKey()
                HermesAgent.setManagedKey(key)
            }
            try writeProfile(active ?? Launch(route: nil, letHermesDecide: HermesAgent.letHermesDecide), key: key, port: port, tools: nil)
            state = wasRunning && process?.isRunning == true ? .running : .stopped
            Log.chat.notice("hermes runtime · set up profile \(Self.profileName, privacy: .public)")
        } catch {
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    private func writeProfile(_ launch: Launch, key: String, port: Int, tools: LassoToolsAccess?) throws {
        let dir = Self.profileDirectory
        let envURL = dir.appending(path: ".env"), configURL = dir.appending(path: "config.yaml")
        let env = (try? String(contentsOf: envURL, encoding: .utf8)) ?? ""
        try Self.writePrivate(HermesProfileFiles.filteredEnv(env, apiKey: key, port: port), to: envURL)
        let config = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        try FileManager.default.createDirectory(at: Self.workspaceDirectory, withIntermediateDirectories: true)
        try HermesLassoPlugin.install(in: dir, access: tools)
        try Self.writePrivate(HermesProfileFiles.withManagedBlock(config, port: port, route: launch.route,
                                                                   letHermesDecide: launch.letHermesDecide,
                                                                   workspace: Self.workspaceDirectory,
                                                                   tools: tools),
                              to: configURL)
    }

    // MARK: Running

    /// A client for Lasso's Hermes thinking with `route`, starting or restarting the gateway as needed.
    /// Concurrent callers share a start, and a caller that wanted another route starts again after it.
    func ready(route: HermesRoute?) async throws -> HermesClient {
        await cleanupTask?.value
        let wanted = Launch(route: route, letHermesDecide: HermesAgent.letHermesDecide,
                            tools: PackageRegistry.shared.toolSignature())
        while true {
            if let startTask {
                let client = try await startTask.value
                if active == wanted, process?.isRunning == true { return client }
                if self.startTask != nil { continue }
            }
            let id = UUID()
            let task = Task { () throws -> HermesClient in
                defer { if self.startID == id { self.startTask = nil; self.startID = nil } }
                return try await self.start(wanted)
            }
            startTask = task
            startID = id
            return try await task.value
        }
    }

    private func start(_ wanted: Launch) async throws -> HermesClient {
        let gen = generation
        /// Local-only or a stop since this start began: don't go on.
        func stillWanted() throws {
            if PrivacyMode.localOnly { throw HermesError.localOnly }
            if generation != gen || Task.isCancelled { throw CancellationError() }
        }
        try stillWanted()
        guard let hermes = Self.hermesExecutable() else { state = .notInstalled; throw HermesRuntimeError.notInstalled }
        if !isSetUp { try await setUp() }
        try stillWanted()
        if process?.isRunning == true, active == wanted,
           let current = HermesClient(baseURLString: "http://127.0.0.1:\(port)", apiKey: HermesAgent.managedKey),
           (try? await current.check()) != nil {
            state = .running
            return current
        }
        try stillWanted()
        stopProcess()

        // A port a gateway just closed can't be bound again for ~30 s (TIME_WAIT; Hermes binds without
        // address reuse), so a restart takes the next port that is free right now.
        guard let freePort = HermesProfileFiles.bindablePort() else {
            throw HermesRuntimeError.startFailed("No free port for Lasso's agent between \(HermesProfileFiles.basePort) "
                + "and \(HermesProfileFiles.basePort + HermesProfileFiles.portRange - 1).")
        }
        port = freePort
        guard let client = HermesClient(baseURLString: "http://127.0.0.1:\(port)",
                                        apiKey: HermesAgent.managedKey) else { throw HermesRuntimeError.notSetUp }

        state = .starting
        do {
            // The route and approval mode are read when the gateway starts. Lasso's own tools too: if
            // their server can't start, the agent still runs, just without them.
            let toolsURL = try? await LassoToolServer.shared.start()
            try stillWanted()
            let tools = toolsURL.map { LassoToolsAccess(url: $0.absoluteString, token: LassoToolServer.shared.token) }
            try writeProfile(wanted, key: HermesAgent.managedKey, port: port, tools: tools)
            active = wanted
            Log.chat.notice("hermes runtime · starting (route: \(wanted.route?.label ?? "Hermes's model", privacy: .public))")

            let proc = Process()
            proc.executableURL = hermes
            // --replace: Hermes takes over from a gateway of this profile that Lasso lost track of (after
            // a crash), checking the recorded PID's start time first.
            proc.arguments = ["gateway", "run", "--replace", "--external-supervisor"]
            // Only what Hermes needs: an inherited API_SERVER_HOST or a project .env in the working
            // directory would override the profile (and could expose the agent beyond loopback).
            proc.environment = Self.childEnvironment()
            proc.currentDirectoryURL = Self.profileDirectory
            let log = try Self.openLog()
            proc.standardOutput = log
            proc.standardError = log
            proc.terminationHandler = { [weak self] p in
                let pid = p.processIdentifier, status = p.terminationStatus
                Task { @MainActor in self?.processEnded(pid: pid, status: status) }
            }
            try stillWanted()
            try proc.run()
            process = proc
            Log.chat.notice("hermes runtime · launched pid \(proc.processIdentifier, privacy: .public) on port \(self.port, privacy: .public)")

            // Up when its API answers with Lasso's key (a second or two).
            let deadline = Date().addingTimeInterval(45)
            while Date() < deadline, proc.isRunning {
                try stillWanted()
                if (try? await client.check()) != nil {
                    try stillWanted()
                    // Belt and braces: a messaging platform Lasso doesn't know about (a newer Hermes)
                    // must not come up in Lasso's gateway on the user's credentials.
                    if let platform = Self.unexpectedPlatform() {
                        stopProcess()
                        throw HermesRuntimeError.startFailed("Lasso's agent stopped: it tried to connect to "
                            + "\(platform). Remove that platform's credentials from your Hermes profile, then Repair.")
                    }
                    state = .running
                    Log.chat.notice("hermes runtime · ready")
                    return client
                }
                try await Task.sleep(for: .milliseconds(400))
            }
            let tail = Self.logTail()
            stopProcess()
            throw HermesRuntimeError.startFailed("Lasso's agent didn't start." + (tail.isEmpty ? "" : " Hermes said:\n\(tail)"))
        } catch {
            if error is CancellationError || (error as? HermesError) != nil {
                stopProcess()
                if state == .starting { state = isSetUp ? .stopped : .notSetUp }
            } else {
                state = .failed(error.localizedDescription)
            }
            throw error
        }
    }

    private func processEnded(pid: pid_t, status: Int32) {
        guard process?.processIdentifier == pid else { return }
        process = nil
        active = nil
        if state == .running || state == .starting {
            Log.chat.notice("hermes runtime · gateway exited (\(status, privacy: .public))")
            state = status == 0 ? .stopped : .failed("Lasso's agent stopped unexpectedly (exit \(status)).")
        }
    }

    /// Stops Lasso's gateway (Agent turned off, local-only turned on, a model switch) and cancels a start
    /// still under way. Returns at once; stragglers are killed in the background after 3 s.
    func stop() {
        generation += 1
        startTask?.cancel()
        stopProcess(waiting: false)
        LassoToolServer.shared.stop()
    }

    /// Lasso is quitting: same, but waits (up to 3 s) so nothing outlives it.
    func stopForQuit() {
        generation += 1
        startTask?.cancel()
        stopProcess(waiting: true)
        LassoToolServer.shared.stop()
    }

    /// Signals only the process Lasso launched and its children (Hermes runs the gateway under a
    /// logging wrapper), then makes sure they're gone.
    private func stopProcess(waiting: Bool = false) {
        defer {
            process = nil
            active = nil
            if state == .running || state == .starting { state = .stopped }
        }
        guard let proc = process, proc.isRunning else { return }
        let pids = [proc.processIdentifier] + Self.descendants(of: proc.processIdentifier)
        for pid in pids { kill(pid, SIGTERM) }
        Log.chat.notice("hermes runtime · stopping \(pids.map(String.init).joined(separator: ","), privacy: .public)")
        if waiting {
            Self.reap(pids)
        } else {
            Task.detached { Self.reap(pids) }
        }
    }

    /// Waits up to 3 s for `pids` to exit after SIGTERM, then kills what's left.
    nonisolated private static func reap(_ pids: [pid_t]) {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, pids.contains(where: { kill($0, 0) == 0 }) { usleep(50_000) }
        for pid in pids where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
    }

    /// At launch: a gateway of Lasso's profile still running means Lasso crashed while it ran. It holds the
    /// user's keys, so ask Hermes to stop it (Hermes verifies the PID is really that gateway).
    func cleanUpAfterCrash() {
        guard Self.profileIsLassos,
              FileManager.default.fileExists(atPath: Self.profileDirectory.appending(path: "gateway.pid").path),
              let hermes = Self.hermesExecutable() else { return }
        cleanupTask = Task { try? await Self.run(hermes, ["gateway", "stop"], home: Self.profileDirectory) }
    }

    // MARK: Helpers

    /// Whether a gateway of Lasso's profile is up (its port answers), for tests and diagnostics.
    nonisolated static func recordedLassoGatewayRunning() -> Bool {
        guard let data = try? Data(contentsOf: profileDirectory.appending(path: "gateway_state.json")),
              let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = (state["pid"] as? NSNumber)?.int32Value else { return false }
        return state["gateway_state"] as? String == "running" && kill(pid, 0) == 0
    }

    nonisolated static func childEnvironment(home: URL = profileDirectory) -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        var env: [String: String] = [:]
        // Proxy and certificate settings stay, or the agent can't reach its model behind a company proxy.
        for key in ["HOME", "USER", "LOGNAME", "LANG", "LC_ALL", "TMPDIR", "SHELL",
                    "HTTPS_PROXY", "HTTP_PROXY", "ALL_PROXY", "NO_PROXY",
                    "https_proxy", "http_proxy", "all_proxy", "no_proxy",
                    "SSL_CERT_FILE", "SSL_CERT_DIR", "REQUESTS_CA_BUNDLE"] {
            if let value = inherited[key] { env[key] = value }
        }
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["HERMES_HOME"] = home.path
        return env
    }

    nonisolated static func descendants(of parent: pid_t) -> [pid_t] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        proc.arguments = ["-P", String(parent)]
        let pipe = Pipe()
        proc.standardOutput = pipe
        guard (try? proc.run()) != nil else { return [] }
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        proc.waitUntilExit()
        let children = out.split(separator: "\n").compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
        return children + children.flatMap { descendants(of: $0) }
    }

    /// A platform other than the API server in this profile's gateway state, if any.
    nonisolated static func unexpectedPlatform() -> String? {
        guard let data = try? Data(contentsOf: profileDirectory.appending(path: "gateway_state.json")),
              let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let platforms = state["platforms"] as? [String: Any] else { return nil }
        return platforms.keys.sorted().first { $0 != "api_server" }
    }

    private static func run(_ executable: URL, _ arguments: [String], home: URL? = nil) async throws {
        try await Task.detached {
            let proc = Process()
            proc.executableURL = executable
            proc.arguments = arguments
            var env = childEnvironment()
            if let home { env["HERMES_HOME"] = home.path } else { env.removeValue(forKey: "HERMES_HOME") }
            proc.environment = env
            proc.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe
            try proc.run()
            let output = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else {
                let text = String(decoding: output, as: UTF8.self).suffix(400)
                throw HermesRuntimeError.commandFailed("hermes \(arguments.prefix(2).joined(separator: " ")): \(text)")
            }
        }.value
    }

    /// Writes a file that only the user can read, created that way (no world-readable moment), and never
    /// through a symlink.
    nonisolated static func writePrivate(_ text: String, to url: URL) throws {
        let fm = FileManager.default
        if let type = try? fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType, type == .typeSymbolicLink {
            throw HermesRuntimeError.commandFailed("\(url.lastPathComponent) is a symbolic link; Lasso won't write through it.")
        }
        let temp = url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).lasso-\(UUID().uuidString.prefix(6))")
        guard fm.createFile(atPath: temp.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw HermesRuntimeError.commandFailed("couldn't write \(url.lastPathComponent)")
        }
        if fm.fileExists(atPath: url.path) {
            // Owner-only before the new contents land (the replacement keeps the old file's mode).
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            _ = try fm.replaceItemAt(url, withItemAt: temp, options: .usingNewMetadataOnly)
        } else {
            try fm.moveItem(at: temp, to: url)
        }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func openLog() throws -> FileHandle {
        let url = logFile
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Fresh per start, so the tail shown on a failure is this start's.
        FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        return try FileHandle(forWritingTo: url)
    }

    /// Hermes's own error lines from this start (its banner and tool warnings say nothing useful).
    private static func logTail(lines: Int = 3) -> String {
        guard let text = try? String(contentsOf: logFile, encoding: .utf8) else { return "" }
        let all = text.split(separator: "\n")
        let errors = all.filter { $0.contains(" ERROR ") }
        return (errors.isEmpty ? all : errors).suffix(lines)
            .map { $0.replacingOccurrences(of: #"^\S+ \S+ ERROR \S+: "#, with: "", options: .regularExpression) }
            .joined(separator: "\n")
    }
}

enum HermesRuntimeError: LocalizedError {
    case notInstalled
    case notSetUp
    case profileTaken(String)
    case commandFailed(String)
    case startFailed(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled: "Hermes Agent isn't installed. Install it with `brew install hermes-agent`, then try again."
        case .notSetUp: "The Agent isn't set up yet. Set it up in Settings ▸ Agent."
        case .profileTaken(let path): "A Hermes profile Lasso didn't create already exists at \(path), so Lasso won't change it. Rename or remove it, then set up the Agent again."
        case .commandFailed(let detail): "Setting up the Agent failed: \(detail)"
        case .startFailed(let message): message
        }
    }
}

/// The model Hermes thinks with for Lasso: the one selected in Lasso, when Hermes can reach it.
struct HermesRoute: Equatable, Sendable {
    /// Same backend and model; the label is only for display and must not cause a restart.
    static func == (a: HermesRoute, b: HermesRoute) -> Bool {
        a.provider == b.provider && a.model == b.model && a.baseURL == b.baseURL && a.apiKey == b.apiKey
    }

    var provider: String
    var model: String
    var baseURL: String?
    var apiKey: String?
    /// For the Activity trace ("Answering · …").
    var label: String

    /// The route for Lasso's current text model, or nil when Hermes can't use it (then the Agent doesn't
    /// run; see `unavailableReason`). MLX is served to Hermes by Lasso itself on loopback
    /// (`LocalModelServer`); Apple Intelligence can't be served to another program.
    @MainActor
    static func current(_ intelligence: IntelligenceCoordinator) async -> HermesRoute? {
        let label = intelligence.textEngineLabel
        switch intelligence.effectivePreferred {
        case .onDevice:
            return nil
        case .mlx:
            let server = LocalModelServer.shared
            guard let base = try? await server.start(model: intelligence.mlxModel) else { return nil }
            return HermesRoute(provider: "custom", model: intelligence.mlxModel,
                               baseURL: base.absoluteString, apiKey: server.token, label: label)
        case .anthropic:
            let key = Keychain.getMigrating("anthropic.apiKey", legacyDefaultsKey: "anthropic.apiKey") ?? ""
            guard !intelligence.anthropicModel.isEmpty else { return nil }
            let base = intelligence.anthropicBaseURL.trimmingCharacters(in: .whitespaces)
            return HermesRoute(provider: "anthropic", model: intelligence.anthropicModel,
                               baseURL: base.isEmpty || base.contains("api.anthropic.com") ? nil : base,
                               apiKey: key.isEmpty ? nil : key, label: label)
        case .openAICompatible:
            let key = Keychain.getMigrating("openai.apiKey", legacyDefaultsKey: "openai.apiKey") ?? ""
            guard !intelligence.openAIModel.isEmpty else { return nil }
            if intelligence.openAIConnectionKind == .gemini {
                return HermesRoute(provider: "gemini", model: intelligence.openAIModel, baseURL: nil,
                                   apiKey: key.isEmpty ? nil : key, label: label)
            }
            return HermesRoute(provider: "custom", model: intelligence.openAIModel,
                               baseURL: intelligence.openAIBaseURL, apiKey: key.isEmpty ? "none" : key, label: label)
        case .ollama:
            let chosen = await intelligence.resolvedTextModel()
            guard !chosen.isEmpty else { return nil }
            // The same model with a context window Hermes fits in (see OllamaAgentModel).
            let model = await OllamaAgentModel.ensure(chosen) ?? chosen
            return HermesRoute(provider: "custom", model: model,
                               baseURL: OllamaEndpoint.baseURL.appending(path: "v1").absoluteString,
                               apiKey: "ollama", label: label)
        }
    }

    /// Why the Agent can't run on the model chosen in Lasso, for the reply.
    @MainActor
    static func unavailableReason(_ intelligence: IntelligenceCoordinator) -> String {
        switch intelligence.effectivePreferred {
        case .onDevice:
            "Agent can't use Apple Intelligence: it only runs inside Lasso. Pick an MLX, Ollama or cloud model."
        case .mlx:
            "Agent couldn't start your MLX model. Check it's downloaded in Settings ▸ Models."
        default:
            "Agent needs a model: choose one in Settings ▸ Models."
        }
    }
}

/// The text transformations on Lasso's Hermes profile files. Pure, so they're unit-tested.
enum HermesProfileFiles {
    /// Loopback ports for Lasso's gateway (the user's own Hermes API server defaults to 8642).
    static let basePort = 8653
    static let portRange = 10

    /// The first port in Lasso's range that can be bound right now, the way Hermes binds it (no
    /// address reuse), so a port still in TIME_WAIT after a restart is skipped.
    static func bindablePort(from base: Int = basePort, count: Int = portRange) -> Int? {
        (base..<(base + count)).first(where: canBind)
    }

    static func canBind(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        } == 0
    }

    /// Marks a profile Lasso created; Lasso writes to no other.
    static let sentinel = ".lasso-managed"
    /// In the sentinel of a profile Lasso created fresh rather than cloned.
    static let freshMark = "profile: fresh"

    static let beginMarker = "# >>> Lasso: managed block. Lasso rewrites everything down to the end marker."
    static let endMarker = "# <<< Lasso"

    /// Every messaging platform Hermes 0.21 knows (gateway/config.py `Platform`), turned off in
    /// Lasso's profile so its gateway never connects to the user's chat accounts.
    static let messagingPlatforms = ["telegram", "discord", "whatsapp", "whatsapp_cloud", "slack", "signal",
                                     "mattermost", "matrix", "homeassistant", "email", "sms", "dingtalk",
                                     "webhook", "msgraph_webhook", "feishu", "wecom", "wecom_callback", "weixin",
                                     "bluebubbles", "qqbot", "yuanbao", "relay"]

    /// `.env` keys that belong to those platforms (or to the API server, which Lasso sets). Bot tokens
    /// and webhooks of platforms not listed here are dropped by pattern; a platform that still comes up
    /// stops the gateway (`HermesRuntime.unexpectedPlatform`).
    static let droppedEnvPrefixes = ["TELEGRAM_", "DISCORD_", "WHATSAPP_", "SLACK_", "SIGNAL_", "MATTERMOST_",
                                     "MATRIX_", "HOMEASSISTANT_", "HASS_", "EMAIL_", "IMAP_", "SMTP_", "SMS_",
                                     "TWILIO_", "DINGTALK_", "MSGRAPH_", "FEISHU_", "LARK_", "WECOM_", "WEIXIN_",
                                     "BLUEBUBBLES_", "QQBOT_", "QQ_", "YUANBAO_", "RELAY_", "WEBHOOK_",
                                     "API_SERVER_", "GATEWAY_ALLOW_ALL_USERS", "HERMES_YOLO_MODE"]

    static func newKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return "lasso-" + bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// The cloned `.env` without messaging credentials, with Lasso's API server key, host and port
    /// (`.env` is loaded with override, so these win over anything else Hermes might read).
    static func filteredEnv(_ env: String, apiKey: String, port: Int) -> String {
        var kept: [String] = []
        for line in env.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let name = line.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "export ", with: "")
                .components(separatedBy: "=").first ?? ""
            if droppedEnvPrefixes.contains(where: { name.hasPrefix($0) })
                || ["_BOT_TOKEN", "_BOT_KEY", "_APP_TOKEN", "_SIGNING_SECRET", "WEBHOOK"].contains(where: name.contains) {
                continue
            }
            kept.append(line)
        }
        while kept.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { kept.removeLast() }
        kept += ["API_SERVER_KEY=\(apiKey)", "API_SERVER_HOST=127.0.0.1", "API_SERVER_PORT=\(port)"]
        return kept.joined(separator: "\n") + "\n"
    }

    static func hasManagedBlock(_ config: String) -> Bool {
        config.contains(beginMarker) && config.contains(endMarker)
    }

    /// `config` with Lasso's block (re)written at the end.
    static func withManagedBlock(_ config: String, port: Int, route: HermesRoute?, letHermesDecide: Bool = false,
                                 workspace: URL? = nil, tools: LassoToolsAccess? = nil) -> String {
        var text = config.replacingOccurrences(of: "\r\n", with: "\n")
        if let start = text.range(of: beginMarker) {
            let end = text.range(of: endMarker, range: start.upperBound..<text.endIndex)
            text.removeSubrange(start.lowerBound..<(end.map { lineEnd(in: text, after: $0.upperBound) } ?? text.endIndex))
        }
        while text.hasSuffix("\n\n") { text.removeLast() }
        if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
        return text + "\n" + managedBlock(port: port, route: route, letHermesDecide: letHermesDecide, workspace: workspace, tools: tools)
    }

    /// `letHermesDecide`: the user's opt-out in Settings; Hermes's `smart` mode then decides flagged
    /// commands with its helper model (its hard blocklist still applies), and every reply says so.
    /// Hermes's tools the Agent gets in Lasso. Every tool's description is sent with every request (on a
    /// local model, context and seconds), so only what's useful in Lasso's chat panel: commands, files,
    /// the web and Hermes's memory. Left out: sub-agents, a second code runner, its own session search
    /// (Lasso keeps the conversation), skill writing, to-do lists, scheduled jobs, the browser and image
    /// generation (they need setup Lasso doesn't do), and its vision tool (it asks the model Hermes
    /// thinks with, which here often can't see; Lasso's `look_at_image` uses the image model instead).
    /// Measured with Hermes's own resolver: 17 tools, ~7.5k tokens, down to 10, ~3.9k.
    static let hermesToolsets = ["terminal", "file", "web", "memory"]

    static func managedBlock(port: Int, route: HermesRoute?, letHermesDecide: Bool = false, workspace: URL? = nil,
                             tools: LassoToolsAccess? = nil) -> String {
        var lines = [beginMarker]
        // The model Hermes thinks with, for everything: replies, and its side tasks (titles, history
        // summaries), which follow `model:` rather than the per-request route. Lasso's choice, never a
        // default Hermes ships with or one the user set for their own Hermes.
        if let route {
            lines += ["model:",
                      "  provider: \(quoted(route.provider))",
                      "  default: \(quoted(route.model))"]
            if let base = route.baseURL { lines.append("  base_url: \(quoted(base))") }
            if let key = route.apiKey { lines.append("  api_key: \(quoted(key))") }
        }
        // The agent's working folder (Hermes's file tools also resolve relative paths against it). The
        // profile is Lasso's own, so its `terminal:` section is Lasso's to set; Hermes fills in the rest.
        if let workspace {
            lines += ["terminal:", "  cwd: \(quoted(workspace.path))"]
        }
        lines += ["approvals:",
                     "  mode: \(letHermesDecide ? "smart" : "manual")",
                     "platforms:",
                     "  api_server:",
                     "    enabled: true",
                     "    extra:",
                     "      host: \"127.0.0.1\"",
                     "      port: \(port)"]
        if let route {
            lines += ["      model_routes:",
                      "        lasso:",
                      "          provider: \(quoted(route.provider))",
                      "          model: \(quoted(route.model))"]
            if let base = route.baseURL { lines.append("          base_url: \(quoted(base))") }
            if let key = route.apiKey { lines.append("          api_key: \(quoted(key))") }
        }
        for platform in messagingPlatforms {
            lines += ["  \(platform):", "    enabled: false"]
        }
        // Lasso's own tools come in through its plugin (`HermesLassoPlugin`), turned on here: plugins
        // are opt-in, and a listed toolset is the only way one reaches the API server's agent.
        let toolsets = hermesToolsets + (tools == nil ? [] : [HermesLassoPlugin.toolset])
        lines += ["platform_toolsets:",
                  "  api_server: [\(toolsets.map(quoted).joined(separator: ", "))]"]
        if tools != nil {
            lines += ["plugins:", "  enabled: [\(quoted(HermesLassoPlugin.name))]"]
        }
        lines.append(endMarker)
        return lines.joined(separator: "\n") + "\n"
    }

    /// A YAML double-quoted scalar (JSON string syntax is valid YAML).
    static func quoted(_ value: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [value], options: [.withoutEscapingSlashes])) ?? Data()
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast())
    }

    private static func lineEnd(in text: String, after index: String.Index) -> String.Index {
        text[index...].firstIndex(of: "\n").map { text.index(after: $0) } ?? text.endIndex
    }
}

/// Where Hermes reaches Lasso's own tools, written into the profile for one launch.
struct LassoToolsAccess: Equatable, Sendable {
    var url: String
    var token: String
}
