import Foundation
import NaturalLanguage

/// Sources (docs/LOCAL-SOURCES.md): search packages a chat message can look in, apart from web search.
/// `@My notes` forces one; otherwise Lasso ranks them against the message itself (no model call, no
/// context) and looks in the few that fit. Results pass a lexical gate and a shared 3-passage cap
/// before the model sees anything.
struct PackageSource: Identifiable, Sendable, Equatable {
    var entry: PackageRegistry.Entry
    var command: PackageCommand
    var id: String { entry.package.id }
    var name: String { entry.package.name }
    /// On this Mac (a script without network, loopback http) or Web (Tavily, SerpApi).
    var isOnThisMac: Bool

    static func == (a: PackageSource, b: PackageSource) -> Bool { a.id == b.id && a.command.id == b.command.id }

    /// A search command reaches the internet unless it's a script without `network`, or http whose
    /// every host is this Mac. Derived, never declared (docs/LOCAL-SOURCES.md).
    static func isOnThisMac(_ entry: PackageRegistry.Entry, _ command: PackageCommand) -> Bool {
        if let script = command.script { return !script.network }
        if command.http != nil {
            let hosts = PackageHTTP.allowedHosts(entry.package, values: entry.values)
            return !hosts.isEmpty && hosts.allSatisfy(PackageValidator.isLoopback)
        }
        if let shortcut = command.shortcut { return shortcut.offline }
        return command.prompt != nil
    }
}

extension PackageRegistry {
    /// Every enabled, set-up search package as a source, On this Mac ones first.
    func sources(localOnly: Bool = PrivacyMode.localOnly) -> [PackageSource] {
        all.filter(\.ready).flatMap { entry in
            entry.package.commands.filter { $0.surfaces.contains(.search) }.map { command in
                PackageSource(entry: entry, command: command, isOnThisMac: PackageSource.isOnThisMac(entry, command))
            }
        }
        .filter { !localOnly || $0.isOnThisMac }
        .sorted { ($0.isOnThisMac ? 0 : 1, $0.name) < ($1.isOnThisMac ? 0 : 1, $1.name) }
    }

    /// The Web ones only: what the globe's web search adds to its free sources.
    func webSources(localOnly: Bool = PrivacyMode.localOnly) -> [PackageSource] {
        localOnly ? [] : sources(localOnly: false).filter { !$0.isOnThisMac }
    }
}

// MARK: - The user's choices per source

/// "Use it: Automatically / Only when I @ it", "What's in it", and which cloud providers may receive
/// passages from it. In preferences, by package id.
enum SourcePreferences {
    enum Use: String, Sendable { case automatically, onlyWhenMentioned }

    static func use(_ id: String, _ defaults: UserDefaults = .standard) -> Use {
        defaults.string(forKey: "sources.\(id).use").flatMap(Use.init(rawValue:)) ?? .automatically
    }
    static func setUse(_ use: Use, _ id: String, _ defaults: UserDefaults = .standard) {
        defaults.set(use.rawValue, forKey: "sources.\(id).use")
    }

    static let maxAbout = 120

    /// What the source holds, in the user's words; Lasso ranks against it.
    static func about(_ id: String, _ defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: "sources.\(id).about") ?? ""
    }
    static func setAbout(_ text: String, _ id: String, _ defaults: UserDefaults = .standard) {
        defaults.set(String(text.prefix(maxAbout)), forKey: "sources.\(id).about")
    }

    /// Set the line automatically (from the folder, or the package's describe/1), unless the user
    /// wrote their own: an automatic line is replaced only by another automatic one.
    static func setAutomaticAbout(_ text: String, _ id: String, _ defaults: UserDefaults = .standard) {
        let current = about(id, defaults)
        guard current.isEmpty || current == defaults.string(forKey: "sources.\(id).aboutAuto") else { return }
        setAbout(text, id, defaults)
        defaults.set(String(text.prefix(maxAbout)), forKey: "sources.\(id).aboutAuto")
    }

    /// Picking words a describe/1 command gave: Lasso's picker uses them, the model never sees them.
    static func words(_ id: String, _ defaults: UserDefaults = .standard) -> [String] {
        defaults.stringArray(forKey: "sources.\(id).words") ?? []
    }
    static func setWords(_ words: [String], _ id: String, _ defaults: UserDefaults = .standard) {
        defaults.set(Array(words.prefix(100)), forKey: "sources.\(id).words")
        defaults.set(Date(), forKey: "sources.\(id).described")
    }
    static func described(_ id: String, _ defaults: UserDefaults = .standard) -> Date? {
        defaults.object(forKey: "sources.\(id).described") as? Date
    }

    /// Cloud providers the user allowed to receive this source's passages ("anthropic", "groq"…).
    static func allowed(_ id: String, _ defaults: UserDefaults = .standard) -> [String] {
        defaults.stringArray(forKey: "sources.\(id).allowed") ?? []
    }
    static func allow(_ provider: String, _ id: String, _ defaults: UserDefaults = .standard) {
        let list = allowed(id, defaults)
        if !list.contains(provider) { defaults.set(list + [provider], forKey: "sources.\(id).allowed") }
    }
    static func resetAllowed(_ id: String, _ defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: "sources.\(id).allowed")
    }

    /// Everything about a source, when its package is removed.
    static func forget(_ id: String, _ defaults: UserDefaults = .standard) {
        for key in ["use", "about", "allowed", "aboutAuto", "words", "described"] { defaults.removeObject(forKey: "sources.\(id).\(key)") }
    }
}

// MARK: - Choosing sources

enum SourcePicker {
    /// Phrases that point at the user's own things: "my notes", "I wrote".
    static let selfReference = ["my notes", "my files", "my docs", "my documents", "i wrote", "i noted", "in my notes"]

    /// Sources to look in automatically: On this Mac, set to Automatically, with a "What's in it", and
    /// sharing words with the message (or its last exchange). Best first, at most 2, and only those
    /// close to the best (a relative margin, never a fixed similarity cutoff).
    static func automatic(_ message: String, lastExchange: String = "", from sources: [PackageSource],
                          defaults: UserDefaults = .standard) -> [PackageSource] {
        let words = SourceWords.content(message)
        guard !words.isEmpty else { return [] }
        let context = SourceWords.content(lastExchange)
        let scored: [(source: PackageSource, score: Double)] = sources.compactMap { source in
            guard source.isOnThisMac, SourcePreferences.use(source.id, defaults) == .automatically else { return nil }
            // What's in it, and the picking words its describe/1 command gave (never shown to a model).
            let about = (SourcePreferences.about(source.id, defaults) + " " + SourcePreferences.words(source.id, defaults).joined(separator: " "))
                .trimmingCharacters(in: .whitespaces)
            guard !about.isEmpty else { return nil }
            // A word of "What's in it" must be in the message: the name alone ("release notes" vs My
            // notes) isn't enough.
            let direct = SourceWords.overlap(words, in: about)
            guard direct > 0 else { return nil }
            let vocabulary = "\(source.name) \(about)"
            let followUp = SourceWords.overlap(context, in: vocabulary)
            return (source, Double(direct) + 0.25 * Double(followUp) + similarity(message, vocabulary))
        }
        guard let best = scored.map(\.score).max() else { return [] }
        return scored.filter { $0.score >= best * 0.6 }.sorted { $0.score > $1.score }.prefix(2).map(\.source)
    }

    /// Sentence similarity from Apple's on-device embedding, only to order candidates that already
    /// share words with the message (0 when unavailable).
    static func similarity(_ a: String, _ b: String) -> Double {
        guard let embedding = NLEmbedding.sentenceEmbedding(for: .english) else { return 0 }
        let distance = embedding.distance(between: a.lowercased(), and: b.lowercased(), distanceType: .cosine)
        return distance.isFinite ? max(0, 1 - distance) : 0
    }

    /// A source the message points at by name or as "my notes" but that isn't being searched: offered
    /// as "Look in My notes for this?", never searched on its own.
    static func offered(_ message: String, from sources: [PackageSource], searched: Set<String>) -> PackageSource? {
        let lower = message.lowercased()
        let points = selfReference.contains { lower.contains($0) }
        return sources.first { source in
            !searched.contains(source.id) && source.isOnThisMac
                && (lower.contains(source.name.lowercased()) || points)
        }
    }
}

// MARK: - Looking

/// What looking in one source came to, for its step line.
struct SourceOutcome: Sendable, Equatable {
    enum Status: Sendable, Equatable {
        case matched(Int), nothing, timedOut, failed(String)
        /// The source said the message isn't about it (`source/1`): no step when Lasso picked it.
        case irrelevant
        /// The source can't answer this kind of question; its note says why.
        case cant(String)
    }
    var source: PackageSource
    var status: Status
    /// Whether Lasso picked it (vs an `@`).
    var automatic: Bool
    /// What it searched for, when not the user's words ("frozendict").
    var searched: String? = nil
    /// A query it offers the user ("Did you mean frozendict?").
    var ask: String? = nil
    /// Its fact about the search, for the model.
    var note: String? = nil
    /// Whether its passage is the list of files ("what's in my notes").
    var listed = false
}

enum SourceSearch {
    static let maxPassages = SourceCore.maxPassages
    static let maxCharacters = SourceCore.maxCharacters
    static let timeout: Double = 5

    /// The words a source is searched with: the user's own, without the words of the source's name
    /// ("my notes about pricing" searches My notes for "pricing").
    static func query(_ message: String, for source: PackageSource) -> [String] {
        SourceCore.query(message, sourceName: source.name)
    }

    /// The folder a source reads, when it has one (My notes' notes folder).
    static func folder(of source: PackageSource) -> URL? {
        guard let setting = source.entry.package.settings.first(where: { $0.kind == .folder }),
              let path = source.entry.values["settings.\(setting.id)"], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// What's in a folder source, for "what's in my notes": its folders with how many files each (and
    /// their subfolders), the files at the top, and the newest few. Lasso reads the folder itself, no
    /// script and no search. A folder of docs next to a few notes reads as both, not as 60 doc pages.
    static func inventory(_ source: PackageSource, limit: Int = 20_000) -> SourceHit? {
        guard let folder = folder(of: source),
              let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.contentModificationDateKey],
                                                          options: [.skipsHiddenFiles]) else { return nil }
        var files: [(path: String, date: Date)] = []
        for case let url as URL in walker where ["md", "markdown", "txt"].contains(url.pathExtension.lowercased()) {
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            files.append((String(url.standardizedFileURL.path.dropFirst(folder.standardizedFileURL.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")), date))
            if files.count >= limit { break }
        }
        let place = (folder.path as NSString).abbreviatingWithTildeInPath
        guard !files.isEmpty else {
            return SourceHit(source: source.name, title: "Files in \(source.name)", url: folder, snippet: "\(place) has no notes yet.")
        }
        func plural(_ n: Int) -> String { "\(n) file\(n == 1 ? "" : "s")" }
        var top: [String] = []
        var folders: [String: [String]] = [:]
        for file in files {
            let parts = file.path.split(separator: "/").map(String.init)
            if parts.count == 1 { top.append(file.path) } else { folders[parts[0], default: []].append(parts.dropFirst().joined(separator: "/")) }
        }
        var lines = ["\(plural(files.count)) in \(place)."]
        if !folders.isEmpty {
            let described = folders.sorted { ($0.value.count, $1.key) > ($1.value.count, $0.key) }.map { name, inside -> String in
                let subfolders = Dictionary(grouping: inside.filter { $0.contains("/") }, by: { String($0.split(separator: "/")[0]) })
                    .sorted { $0.value.count > $1.value.count }.prefix(6).map { "\($0.key)/ \($0.value.count)" }
                let loose = inside.filter { !$0.contains("/") }
                let detail = subfolders.isEmpty
                    ? (loose.count <= 4 ? ": " + loose.joined(separator: ", ") : "")
                    : ": " + subfolders.joined(separator: ", ") + (subfolders.count < Set(inside.compactMap { $0.split(separator: "/").count > 1 ? $0.split(separator: "/")[0] : nil }).count ? ", …" : "")
                return "\(name)/ (\(plural(inside.count))\(detail))"
            }
            lines.append("Folders: " + described.prefix(12).joined(separator: "; ") + (described.count > 12 ? "; and \(described.count - 12) more folders" : "") + ".")
        }
        if !top.isEmpty {
            let shown = top.sorted().prefix(25)
            lines.append("Not in a folder: " + shown.joined(separator: ", ") + (top.count > shown.count ? ", and \(top.count - shown.count) more" : "") + ".")
        }
        let newest = files.sorted { $0.date > $1.date }.prefix(8).map(\.path)
        lines.append("Most recently changed: " + newest.joined(separator: ", ") + ".")
        return SourceHit(source: source.name, title: "Files in \(source.name)", url: folder, snippet: lines.joined(separator: "\n"))
    }

    /// The query's words as the gate compares them (stemmed).
    static func gateWords(_ message: String, for source: PackageSource) -> [String] {
        query(message, for: source).map(SourceWords.stem).reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }

    static func passes(_ hit: SourceHit, words: [String]) -> Bool { SourceCore.passes(hit, words: words) }

    /// Runs each source in parallel (each with its own time limit), gates the hits (unless the source
    /// ranks its own), and keeps at most 3 passages in all, at least one from each source that matched.
    /// A `source/1` source gets the whole turn; others get Lasso's words, as before.
    static func look(_ sources: [(PackageSource, automatic: Bool)], turn: SourceTurn,
                     run: @escaping @Sendable (PackageSource, SourceTurn) async throws -> SourceAnswer = SourceSearch.run)
        async -> (hits: [SourceHit], outcomes: [SourceOutcome], notes: [String: String]) {
        let results = await withTaskGroup(of: (Int, Result<SourceAnswer, Error>?).self) { group in
            for (i, item) in sources.enumerated() {
                let words = query(turn.message, for: item.0)
                var prepared = turn
                prepared.query = words.joined(separator: " ")
                prepared.intent = words.isEmpty && turn.searchFor == nil ? .about : .search
                let own = prepared
                let source = item.0
                let hooked = item.0.command.hook == .source
                group.addTask {
                    await withTaskGroup(of: Result<SourceAnswer, Error>?.self) { race in
                        race.addTask {
                            // A question about the source itself: its own list if it gives one, else
                            // Lasso's list of its files.
                            if own.intent == .about, !hooked {
                                return .success(listing(source))
                            }
                            do {
                                var answer = try await run(source, own)
                                if own.intent == .about, answer.status != .inventory, answer.status != .found {
                                    answer = listing(source)
                                }
                                return .success(answer)
                            } catch { return .failure(error) }
                        }
                        race.addTask {
                            try? await Task.sleep(for: .seconds(timeout))
                            return nil
                        }
                        let first = await race.next() ?? nil
                        race.cancelAll()
                        return (i, first)
                    }
                }
            }
            var out: [(Int, Result<SourceAnswer, Error>?)] = []
            for await r in group { out.append(r) }
            return out.sorted { $0.0 < $1.0 }
        }
        var perSource: [[SourceHit]] = []
        var outcomes: [SourceOutcome] = []
        var notes: [String: String] = [:]
        for (i, result) in results {
            let (source, automatic) = sources[i]
            let words = gateWords(turn.message, for: source)
            var outcome = SourceOutcome(source: source, status: .nothing, automatic: automatic)
            switch result {
            case nil:
                perSource.append([])
                outcome.status = .timedOut
            case .failure(let error):
                perSource.append([])
                outcome.status = .failed(error.localizedDescription)
            case .success(let answer):
                outcome.searched = answer.searched
                outcome.ask = answer.ask
                outcome.note = answer.note
                let listed = answer.status == .inventory
                outcome.listed = listed
                var passed = answer.hits
                if !listed, !source.command.ranks, !words.isEmpty {
                    // Lasso's gate, on the words actually searched when the source says so.
                    let gate = answer.searched.map { SourceWords.content($0) } ?? words
                    passed = passed.filter { SourceCore.passes($0, words: gate) }
                }
                if listed { passed = Array(passed.prefix(1)).map { var h = $0; h.title = h.title.hasPrefix("Files in ") ? h.title : "Files in \(source.name)"; return h } }
                perSource.append(answer.status == .irrelevant ? [] : passed)
                switch answer.status {
                case .irrelevant: outcome.status = .irrelevant
                case .cant: outcome.status = .cant(answer.note ?? "\(source.name) can't answer this.")
                default: outcome.status = passed.isEmpty ? .nothing : .matched(passed.count)
                }
                if let note = answer.note, answer.status != .irrelevant { notes[source.name] = note }
            }
            outcomes.append(outcome)
        }
        let kept = SourceCore.budget(perSource, notes: notes.values.reduce(0) { $0 + $1.count })
        for (i, outcome) in outcomes.enumerated() {
            let count = kept.filter { $0.source == outcome.source.name }.count
            if case .matched = outcome.status { outcomes[i].status = count > 0 ? .matched(count) : .nothing }
        }
        return (kept, outcomes, notes)
    }

    /// Lasso's own list of a folder source's files, as an answer.
    static func listing(_ source: PackageSource) -> SourceAnswer {
        guard let hit = inventory(source) else { return SourceAnswer(status: .nothing, hits: []) }
        return SourceAnswer(status: .inventory, hits: [hit])
    }

    /// Runs one source's search command: a `source/1` script with the whole turn, anything else with
    /// Lasso's words, as web search runs Web packages.
    @Sendable static func run(_ source: PackageSource, _ turn: SourceTurn) async throws -> SourceAnswer {
        if source.command.hook == .source {
            return try await PackageSearch.source(source.entry, source.command, turn: turn)
        }
        let hits: [WebSourcesProvider.Hit]
        if source.command.script != nil {
            hits = try await PackageSearch.script(source.entry, source.command, query: turn.query)
        } else {
            hits = await PackageSearch.run(source.entry, source.command, query: turn.query)
        }
        let list = hits.map { SourceHit(source: source.name, title: $0.title, url: $0.url, snippet: $0.snippet ?? "") }
        return SourceAnswer(status: list.isEmpty ? .nothing : .found, hits: list)
    }

    /// When the sources Lasso looked in gave nothing, the model is told so for this turn. Without it a
    /// small model fills the gap: a made-up answer "from your notes", or buttons and menus that don't
    /// exist. A source's own note (a fact about its search) is fenced with it.
    static func nothingFound(_ outcomes: [SourceOutcome], notes: [String: String] = [:]) -> String? {
        // Not when something matched (a cloud model the user said no to doesn't mean "nothing"), and
        // not for a source that said the message isn't about it.
        guard !outcomes.contains(where: { if case .matched = $0.status { true } else { false } }) else { return nil }
        // A source Lasso picked that said "not about me" says nothing; one the user @-mentioned did look.
        let names = outcomes.filter { $0.status != .irrelevant || !$0.automatic }.map(\.source.name)
        guard !names.isEmpty else { return nil }
        let list = names.count == 1 ? names[0] : names.dropLast().joined(separator: ", ") + " and " + names.last!
        var text = """
        Lasso searched the user's \(list) for this message and found nothing that matches. Say so plainly \
        in one short sentence. Don't present anything as coming from their \(list), and don't describe \
        buttons, menus or features. If you can still help from general knowledge, say that it is general \
        knowledge, and if a name or word in the message looks misspelled or unfamiliar, say you don't know \
        it rather than guessing what it is.
        """
        let own = notes.filter { names.contains($0.key) }
        if !own.isEmpty, let fenced = SourceCore.evidence([], notes: own) { text += "\n\n" + fenced }
        return text
    }

    static func evidence(_ hits: [SourceHit], notes: [String: String] = [:]) -> String? {
        hits.isEmpty ? nil : SourceCore.evidence(hits, notes: notes)
    }
}

// MARK: - What's in it, generated

enum SourceAbout {
    /// A source set to Automatically with an empty "What's in it" is never picked. When its folder has
    /// notes now (it was empty when chosen, or the field was never filled), fill it in from them, once.
    static func fillIfEmpty(_ sources: [PackageSource], _ defaults: UserDefaults = .standard) {
        for source in sources where source.isOnThisMac && SourcePreferences.use(source.id, defaults) == .automatically
            && SourcePreferences.about(source.id, defaults).isEmpty {
            guard let folder = SourceSearch.folder(of: source) else { continue }
            let suggested = suggest(for: folder)
            if !suggested.isEmpty { SourcePreferences.setAutomaticAbout(suggested, source.id, defaults) }
        }
    }

    /// A first "What's in it" from a folder: the most frequent words of its file names and headings,
    /// e.g. "flet, animation, architecture, blueprint, prompt, guide". The user edits it.
    static func suggest(for folder: URL, limit: Int = 300) -> String {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return "" }
        var counts: [String: Int] = [:]
        var seen = 0
        for case let url as URL in walker where ["md", "markdown", "txt"].contains(url.pathExtension.lowercased()) {
            seen += 1
            if seen > limit { break }
            for word in SourceWords.whole(url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_", with: " ")) {
                counts[word, default: 0] += 3
            }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n").prefix(400) where line.hasPrefix("#") {
                for word in SourceWords.whole(String(line)) { counts[word, default: 0] += 1 }
            }
        }
        // What the folder holds first: its folders and its loose notes by name ("python, projects,
        // meetings, adobo, todo"), then the most frequent words of names and headings.
        var leading: [String] = []
        let top = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        let isFolder = { (url: URL) in (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        for url in top.filter(isFolder).sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            + top.filter({ !isFolder($0) && ["md", "markdown", "txt"].contains($0.pathExtension.lowercased()) })
                .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            for word in SourceWords.whole(url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_", with: " "))
                where !leading.contains(word) { leading.append(word) }
        }
        var out = ""
        for word in leading + counts.sorted(by: { ($0.value, $1.key) > ($1.value, $0.key) }).map(\.key).filter({ !leading.contains($0) }) {
            let next = out.isEmpty ? word : out + ", " + word
            if next.count > SourcePreferences.maxAbout { break }
            out = next
        }
        return out
    }
}

extension IntelligenceCoordinator {
    /// Who receives what's sent to the chat model: nil when it stays on this Mac (Apple, MLX, Ollama, or
    /// a custom endpoint on this Mac); otherwise the company, by its domain ("groq.com", "Groq"). A
    /// source's Allow is remembered per company, so switching models there doesn't ask again.
    var textRecipient: (key: String, name: String)? {
        Self.recipient(effectivePreferred, anthropicBaseURL: anthropicBaseURL, openAIBaseURL: openAIBaseURL)
    }

    nonisolated static func recipient(_ kind: ProviderKind, anthropicBaseURL: String, openAIBaseURL: String) -> (key: String, name: String)? {
        let base: String
        switch kind {
        case .onDevice, .ollama, .mlx: return nil
        case .anthropic: base = anthropicBaseURL
        case .openAICompatible: base = openAIBaseURL
        }
        guard let host = URL(string: base)?.host?.lowercased() else { return ("unknown", "your cloud model") }
        if PackageValidator.isLoopback(host) { return nil }
        let parts = host.split(separator: ".")
        let domain = parts.count >= 2 ? parts.suffix(2).joined(separator: ".") : host
        let names = ["anthropic.com": "Anthropic", "openai.com": "OpenAI", "groq.com": "Groq", "openrouter.ai": "OpenRouter",
                     "googleapis.com": "Google", "mistral.ai": "Mistral", "deepseek.com": "DeepSeek", "together.xyz": "Together",
                     "x.ai": "xAI", "cerebras.ai": "Cerebras"]
        return (domain, names[domain] ?? domain)
    }
}

// MARK: - describe/1

/// A source package's own What's in it line and picking words (docs/PACKAGE-HOOKS.md), run when the
/// folder is chosen or changes, and at most daily. Lasso's own suggestion stays as the fallback.
@MainActor
enum SourceDescribe {
    private static var running: Set<String> = []

    static func command(of entry: PackageRegistry.Entry) -> PackageCommand? {
        entry.package.commands.first { $0.hook == .describe }
    }

    /// Runs it now (the folder was just chosen or changed).
    static func refresh(_ entry: PackageRegistry.Entry, defaults: UserDefaults = .standard) async {
        guard let command = command(of: entry), !running.contains(entry.package.id) else { return }
        running.insert(entry.package.id)
        defer { running.remove(entry.package.id) }
        do {
            let (about, words) = try await PackageSearch.describe(entry, command)
            if !about.isEmpty { SourcePreferences.setAutomaticAbout(about, entry.package.id, defaults) }
            SourcePreferences.setWords(words, entry.package.id, defaults)
        } catch {
            Log.chat.error("package \(entry.package.id, privacy: .public) · describe didn't work: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// In the background, for sources not described in the last day.
    static func refreshIfDue(_ sources: [PackageSource], defaults: UserDefaults = .standard) {
        for source in sources where command(of: source.entry) != nil {
            if let last = SourcePreferences.described(source.id, defaults), Date().timeIntervalSince(last) < 86_400 { continue }
            let entry = source.entry
            Task { await refresh(entry, defaults: defaults) }
        }
    }
}
