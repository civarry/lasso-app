import Darwin
import Foundation

/// Runs a package's `script` command (spec, "script"): in its data folder, with only the documented
/// environment, under a `sandbox-exec` profile built from what the package declared, and stopped with
/// everything it started at its time limit.
enum PackageScript {
    enum RunError: LocalizedError, Equatable {
        case missing(String)
        case failed(String)
        case timedOut(Int)
        case badOutput(String)

        var errorDescription: String? {
            switch self {
            case .missing(let path): "The package's \(path) is missing or can't run. Add the package folder again."
            case .failed(let line): line.isEmpty ? "The script failed." : "The script failed: \(line)"
            case .timedOut(let s): "The script didn't finish in \(s) seconds, so Lasso stopped it."
            case .badOutput(let why): "The script's answer couldn't be read: \(why)"
            }
        }
    }

    /// What a script gave back.
    enum Output: Sendable, Equatable {
        case text(String)
        case url(String)
        case file(URL)
        case results([[String: String]])
    }

    struct Places: Sendable {
        /// The installed package's folder (`…/Packages/<id>/`).
        var package: URL
        /// Its own writable folder (`…/PackageData/<id>/`), also `HOME`.
        var data: URL
        /// Where `file` output goes (`~/LassoWorkspace/<id>/`).
        var workspace: URL
        /// Folders the user picked in its settings: readable.
        var folders: [URL]
    }

    static let maxOutput = 4 * 1024 * 1024
    /// Stands for the script's TMPDIR in its standard input until the folder exists.
    static let tmpToken = "@LASSO_TMPDIR@"

    /// The real path, as the sandbox matches it (`/private/var/…`). Foundation's
    /// `resolvingSymlinksInPath` strips `/private`, which the sandbox then doesn't match.
    static func real(_ url: URL) -> String {
        guard let resolved = realpath(url.path, nil) else { return url.standardizedFileURL.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
    static let path = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"


    static func workspace(_ id: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "LassoWorkspace/\(id)", directoryHint: .isDirectory)
    }

    // MARK: Sandbox

    /// The sandbox profile: read the system and its own folders, write only its data, temp and
    /// workspace folders, and the network only when declared and not in local-only mode.
    static func profile(_ places: Places, tmp: URL, network: Bool) -> String {
        func q(_ url: URL) -> String { "\"" + real(url).replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        let system = ["/usr", "/bin", "/sbin", "/System", "/Library", "/opt/homebrew", "/usr/local", "/private/etc",
                      "/private/var/db", "/dev", "/Applications/Xcode.app"]
        let readable = [places.package, places.data, tmp, places.workspace] + places.folders
        let writable = [places.data, tmp, places.workspace]
        return """
        (version 1)
        (deny default)
        (import "system.sb")
        (allow process-fork)
        (allow process-exec)
        (allow signal (target same-sandbox))
        (allow sysctl-read)
        (allow file-read-metadata)
        (allow file-read* \(system.map { "(subpath \"\($0)\")" }.joined(separator: " ")) (literal "/") (literal "/private") (literal "/private/var") (literal "/etc") (literal "/var") (literal "/tmp"))
        (allow file-read* \(readable.map { "(subpath \(q($0)))" }.joined(separator: " ")))
        (allow file-write* \(writable.map { "(subpath \(q($0)))" }.joined(separator: " ")) (literal "/dev/null") (literal "/dev/tty") (literal "/dev/dtracehelper"))
        \(network ? "(allow network*)" : "")
        """
    }

    // MARK: Running

    /// What a run is given: the standard-input JSON and the secrets (as `LASSO_SECRET_<ID>` only).
    struct Request: Sendable {
        var command: String
        /// The standard-input JSON, already encoded.
        var stdin: Data
        var secrets: [String: String]
        var run: PackageScriptRun
        /// Full access: no sandbox (the user's choice, per package).
        var unsandboxed: Bool
        var localOnly: Bool
        /// Files written into its TMPDIR before it starts (the capture image), by name.
        var inputFiles: [String: Data] = [:]

        init(command: String, stdin: Data, secrets: [String: String], run: PackageScriptRun,
             unsandboxed: Bool = false, localOnly: Bool = PrivacyMode.localOnly) {
            self.command = command; self.stdin = stdin; self.secrets = secrets; self.run = run
            self.unsandboxed = unsandboxed; self.localOnly = localOnly
        }
    }

    /// Runs it and reads its answer. `progress` gets each `progress:` line from standard error.
    static func run(_ request: Request, places: Places, progress: (@Sendable (String) -> Void)? = nil) async throws -> Output {
        let script = places.package.appending(path: request.run.path)
        // The script must be the package's own file, not a link out of it.
        let resolved = real(script)
        guard resolved.hasPrefix(real(places.package) + "/"),
              FileManager.default.isExecutableFile(atPath: resolved) else { throw RunError.missing(request.run.path) }
        let fm = FileManager.default
        try fm.createDirectory(at: places.data, withIntermediateDirectories: true)
        try fm.createDirectory(at: places.workspace, withIntermediateDirectories: true)
        let tmp = fm.temporaryDirectory.appending(path: "lasso-script-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        var env = ["PATH": path, "HOME": places.data.path, "TMPDIR": tmp.path + "/", "LANG": "en_US.UTF-8"]
        env.merge(request.secrets) { _, new in new }
        let network = request.run.network && !request.localOnly
        let arguments: [String] = request.unsandboxed
            ? [resolved]
            : ["/usr/bin/sandbox-exec", "-p", profile(places, tmp: tmp, network: network), resolved]
        for (name, data) in request.inputFiles where !name.contains("/") {
            try data.write(to: tmp.appending(path: name))
        }
        let input = Data(String(decoding: request.stdin, as: UTF8.self)
            .replacingOccurrences(of: tmpToken, with: tmp.path).utf8)

        let finished = try await Spawned.run(arguments, environment: env, directory: places.data, stdin: input,
                                             timeout: request.run.timeout, progress: progress)
        if finished.timedOut { throw RunError.timedOut(Int(request.run.timeout)) }
        let errLines = String(decoding: finished.stderr, as: UTF8.self).split(separator: "\n")
            .filter { !$0.hasPrefix("progress:") }
        guard finished.status == 0 else {
            throw RunError.failed(PackageHTTP.redact(String(errLines.last ?? ""), secrets: Array(request.secrets.values)))
        }
        return try parse(finished.stdout, places: places, tmp: tmp, id: places.workspace.lastPathComponent)
    }

    /// Plain text as is, or one JSON object (`text`, `url`, `path`, `results`). A `path` is copied out
    /// of `TMPDIR` into the workspace before the folder goes.
    static func parse(_ data: Data, places: Places, tmp: URL, id: String) throws -> Output {
        let raw = String(decoding: data.prefix(maxOutput), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.hasPrefix("{"), let object = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else {
            return .text(raw)
        }
        if let text = object["text"] as? String { return .text(text) }
        if let url = object["url"] as? String { return .url(url) }
        if let list = object["results"] as? [[String: Any]] {
            return .results(list.map { $0.compactMapValues { $0 as? String } })
        }
        if let path = object["path"] as? String {
            let file = URL(fileURLWithPath: real(URL(fileURLWithPath: path, relativeTo: places.data)))
            let allowed = [places.data, tmp, places.workspace].map { real($0) + "/" }
            guard allowed.contains(where: { file.path.hasPrefix($0) }), FileManager.default.fileExists(atPath: file.path) else {
                throw RunError.badOutput("\(path) isn't a file in its own folders.")
            }
            if file.path.hasPrefix(real(places.workspace) + "/") { return .file(file) }
            var target = places.workspace.appending(path: file.lastPathComponent)
            var n = 2
            while FileManager.default.fileExists(atPath: target.path) {
                target = places.workspace.appending(path: "\(file.deletingPathExtension().lastPathComponent) \(n).\(file.pathExtension)")
                n += 1
            }
            try FileManager.default.copyItem(at: file, to: target)
            return .file(target)
        }
        throw RunError.badOutput("expected text, url, path or results.")
    }
}

/// A child process in its own process group, so a time limit stops everything it started.
enum Spawned {
    struct Finished: Sendable {
        var status: Int32
        var stdout: Data
        var stderr: Data
        var timedOut: Bool
    }

    static func run(_ arguments: [String], environment: [String: String], directory: URL, stdin: Data,
                    timeout: Double, progress: (@Sendable (String) -> Void)? = nil) async throws -> Finished {
        try await withCheckedThrowingContinuation { done in
            DispatchQueue.global(qos: .userInitiated).async {
                do { done.resume(returning: try runBlocking(arguments, environment, directory, stdin, timeout, progress)) }
                catch { done.resume(throwing: error) }
            }
        }
    }

    private static func runBlocking(_ arguments: [String], _ environment: [String: String], _ directory: URL, _ input: Data,
                                    _ timeout: Double, _ progress: (@Sendable (String) -> Void)?) throws -> Finished {
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, inPipe.fileHandleForReading.fileDescriptor, 0)
        posix_spawn_file_actions_adddup2(&actions, outPipe.fileHandleForWriting.fileDescriptor, 1)
        posix_spawn_file_actions_adddup2(&actions, errPipe.fileHandleForWriting.fileDescriptor, 2)
        posix_spawn_file_actions_addchdir(&actions, directory.path)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setpgroup(&attributes, 0)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))

        let argv = arguments.map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, arguments[0], &actions, &attributes, argv, envp)
        try? inPipe.fileHandleForReading.close()
        try? outPipe.fileHandleForWriting.close()
        try? errPipe.fileHandleForWriting.close()
        guard spawned == 0 else { throw PackageScript.RunError.failed(String(cString: strerror(spawned))) }

        // Write the input, then read both outputs on their own threads so neither pipe fills up.
        let writer = inPipe.fileHandleForWriting
        DispatchQueue.global().async { try? writer.write(contentsOf: input); try? writer.close() }
        final class Buffers: @unchecked Sendable {
            let lock = NSLock()
            var out = Data(), err = Data()
        }
        let buffers = Buffers()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            let handle = outPipe.fileHandleForReading
            while let chunk = try? handle.read(upToCount: 65_536), !chunk.isEmpty {
                buffers.lock.withLock { if buffers.out.count < PackageScript.maxOutput { buffers.out.append(chunk) } }
            }
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            let handle = errPipe.fileHandleForReading
            var pending = ""
            while let chunk = try? handle.read(upToCount: 4096), !chunk.isEmpty {
                buffers.lock.withLock { if buffers.err.count < 65_536 { buffers.err.append(chunk) } }
                pending += String(decoding: chunk, as: UTF8.self)
                while let newline = pending.firstIndex(of: "\n") {
                    let line = pending[..<newline]
                    if line.hasPrefix("progress:") { progress?(line.dropFirst("progress:".count).trimmingCharacters(in: .whitespaces)) }
                    pending = String(pending[pending.index(after: newline)...])
                }
            }
            group.leave()
        }

        var status: Int32 = 0
        var timedOut = false
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid { break }
            if result == -1 { break }
            if Date() > deadline {
                timedOut = true
                killpg(pid, SIGTERM)
                usleep(300_000)
                killpg(pid, SIGKILL)
                waitpid(pid, &status, 0)
                break
            }
            usleep(20_000)
        }
        // The script has exited; anything it left running in its group goes too.
        killpg(pid, SIGKILL)
        _ = group.wait(timeout: .now() + 2)
        let exit: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        return buffers.lock.withLock { Finished(status: exit, stdout: buffers.out, stderr: buffers.err, timedOut: timedOut) }
    }
}
