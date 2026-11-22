import AppKit
import SwiftUI
import Testing
@testable import Lasso

/// The README's app screenshots, rendered from Lasso's real views in set-up states (never this Mac's
/// chats, packages or settings). Rerun for every release so the README shows what ships:
///
///     TEST_RUNNER_LASSO_README_SHOTS=$PWD/screenshots/app xcodebuild test -scheme Lasso \
///       -derivedDataPath /tmp/lasso-dd -skipMacroValidation -only-testing:LassoTests/ReadmeScreenshotTests
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["LASSO_README_SHOTS"] != nil))
struct ReadmeScreenshotTests {
    private var folder: URL { URL(fileURLWithPath: ProcessInfo.processInfo.environment["LASSO_README_SHOTS"]!) }

    /// The view at `size`, with rounded corners and a soft shadow on a transparent background, at 2×.
    private func shoot<V: View>(_ name: String, _ size: CGSize, _ view: V) async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let pad: CGFloat = 28
        let framed = view
            .frame(width: size.width, height: size.height, alignment: .top)
            .background(SettingsPalette.pageFill)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.12)))
            .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
            .padding(pad)
            .environment(\.colorScheme, .dark)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: size.width + pad * 2, height: size.height + pad * 2),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = NSHostingView(rootView: framed)
        window.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(1200))
        let content = try #require(window.contentView)
        let rep = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: rep)
        try #require(rep.representation(using: .png, properties: [:])).write(to: folder.appending(path: "\(name).png"))
        window.orderOut(nil); window.contentView = nil
    }

    private static let currency = """
    {"lasso": 1, "id": "currency", "version": "1.0.0", "name": "Currency", "summary": "Converts money at today's rate.",
     "author": "Lasso", "hosts": ["api.frankfurter.app"], "commands": [
       {"id": "convert", "title": "Convert currency", "surfaces": ["tool"], "input": ["args"], "output": "markdown",
        "run": {"http": {"url": "https://api.frankfurter.app/latest", "query": {"amount": "{{args.amount}}", "to": "{{args.to}}"}}},
        "tool": {"name": "convert_currency", "description": "Convert an amount of US dollars to another currency at today's rate.",
                 "args": {"amount": "number", "to": "string"}}}]}
    """

    private static let tasks = """
    {"lasso": 1, "id": "tasks", "version": "1.0.0", "name": "Tasks", "summary": "Adds things to your task list.",
     "author": "Lasso", "hosts": ["tasks.example.com"], "commands": [
       {"id": "add", "title": "Add a task", "surfaces": ["send", "tool"], "input": ["text"], "output": "notify",
        "run": {"http": {"method": "POST", "url": "https://tasks.example.com/add", "json": {"t": "{{text}}"}}},
        "tool": {"name": "add_task", "description": "Add a task to the user's list.", "args": {"text": "string"}}}]}
    """

    /// A package that only changes Lasso (patches), for the review screenshot.
    static let writingKit = """
    {"lasso": 1, "id": "writing-kit", "version": "1.0.0", "name": "Writing Kit", "summary": "Shorter summaries, British spelling, a calmer toolbar.",
     "author": "Lasso", "icon": {"symbol": "pencil.and.scribble"}, "patches": [
       {"target": "action.ai.summarize.prompt", "set": "Summarize the text as at most 5 short bullet points. Keep names and numbers exactly as written."},
       {"target": "action.ai.summarize.title", "set": "Bullets"},
       {"target": "toolbar.hidden", "add": ["lens.search", "color.pick"]},
       {"target": "chat.suggestions", "add": {"title": "Make this email shorter"}},
       {"target": "chat.instructions", "add": "Use British spelling. Keep answers under 150 words unless asked for more."}]}
    """

    /// Searches a notes folder with a script, and sends to Reminders with a Shortcut.
    static let meetingNotes = """
    {"lasso": 1, "id": "meeting-notes", "version": "1.0.0", "name": "Meeting Notes", "summary": "Search your notes folder, and turn a line into a reminder.",
     "author": "Lasso", "icon": {"symbol": "note.text"},
     "settings": [{"id": "notes", "label": "Notes folder", "kind": "folder"}],
     "requires": [{"command": "sh"}],
     "commands": [
       {"id": "search", "title": "My notes", "surfaces": ["search"], "input": ["query"], "output": "results",
        "run": {"script": {"path": "scripts/search.sh", "timeout": 5}}, "test": {"query": "standup"}},
       {"id": "remind", "title": "Add to Reminders", "symbol": "checklist", "surfaces": ["send"], "input": ["text"], "output": "notify",
        "run": {"shortcut": {"name": "Add to Reminders from Lasso", "get": "https://www.icloud.com/shortcuts/0123456789abcdef", "offline": true}}}]}
    """

    /// The catalog's packages, as its index lists them (hashes aren't used here).
    static let catalogIndex: String = {
        let rows: [(id: String, version: String, name: String, summary: String, permissions: String)] = [
            ("study-tools", "1.1.0", "Study tools", "Explain and flashcards for anything you lasso.", #"{"hosts": [], "model": true}"#),
            ("notes-search", "1.0.0", "My notes", "Adds a folder of Markdown notes to Lasso's search.", #"{"hosts": [], "script": true}"#),
            ("table-to-csv", "1.0.0", "Table to CSV", "Turns a table you lasso into a CSV file.", #"{"hosts": [], "script": true}"#),
            ("tavily", "1.0.0", "Tavily", "Web search results from Tavily.", #"{"hosts": ["api.tavily.com"], "key": true}"#),
            ("track-package", "1.0.0", "Track package", "Opens tracking for a parcel number you lasso.", #"{"hosts": ["parcelsapp.com"]}"#),
            ("writing-kit", "1.0.0", "Writing Kit", "Bullet-point summaries and a calmer toolbar.", #"{"hosts": [], "patches": true}"#),
        ]
        let list = rows.map { row in
            """
            {"id": "\(row.id)", "version": "\(row.version)", "name": "\(row.name)", "summary": "\(row.summary)", "author": "Lasso",
             "url": "https://raw.githubusercontent.com/civarry/lasso-packages/main/dist/\(row.id)-\(row.version).lassopkg",
             "sha256": "0", "permissions": \(row.permissions)}
            """
        }
        return #"{"lasso": 1, "packages": ["# + list.joined(separator: ",") + "]}"
    }()

    @Test func renderTheReadmeScreenshots() async throws {
        // A throwaway package store with a few packages, so nothing of this Mac's shows.
        let name = "lasso-readme-\(UUID().uuidString.prefix(6))"
        let root = FileManager.default.temporaryDirectory.appending(path: name, directoryHint: .isDirectory)
        let real = PackageStore.shared
        let store = PackageStore(root: root, defaults: UserDefaults(suiteName: name)!)
        PackageStore.shared = store
        defer { PackageStore.shared = real; real.reload(); try? FileManager.default.removeItem(at: root) }
        try store.install(try #require(BundledPackages.data("tavily")), origin: .bundled)
        try store.install(Data(PackageCommandTests.study.utf8), origin: .file)
        try store.install(Data(Self.currency.utf8), origin: .file)
        try store.install(Data(Self.tasks.utf8), origin: .file)
        store.reload()

        // Settings › Packages.
        try await shoot("packages", CGSize(width: 520, height: 1010),
                        PackagesHub(webSearchOn: .constant(true), localOnly: false, openPackage: { _ in })
                            .background(SettingsPalette.pageFill))
        // The review before a package is added.
        try await shoot("package-review", CGSize(width: 480, height: 600),
                        AddPackageSheet(dismiss: {}, added: { _ in }, reviewing: nil,
                                        preload: (Data(Self.tasks.replacingOccurrences(of: "\"id\": \"tasks\"", with: "\"id\": \"tasks-2\"").utf8), .file)))
        // A package that changes Lasso itself, on its page, where another package also changes the
        // Summarize prompt.
        try store.install(Data(Self.writingKit.utf8), origin: .file)
        try store.install(Data("""
            {"lasso": 1, "id": "plain-english", "version": "1.0.0", "name": "Plain English", "summary": "Simpler words.",
             "author": "Lasso", "patches": [{"target": "action.ai.summarize.prompt", "set": "Summarize in plain English."}]}
            """.utf8), origin: .file)
        try await shoot("package-patches", CGSize(width: 520, height: 840),
                        ScrollView { PackagePage(id: "writing-kit", localOnly: false, removed: {}) }
                            .background(SettingsPalette.pageFill))
        // A package with a script (sandboxed, reading a folder the user picked) and a Shortcut.
        let notesFolder = FileManager.default.temporaryDirectory.appending(path: "\(name)-files", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: notesFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: notesFolder) }
        try store.install(Data(Self.meetingNotes.utf8), files: ["scripts/search.sh": Data("#!/bin/sh\necho '{\"results\": []}'\n".utf8)], origin: .file)
        try await shoot("package-scripts", CGSize(width: 520, height: 1240),
                        ScrollView { PackagePage(id: "meeting-notes", localOnly: false, removed: {}) }
                            .background(SettingsPalette.pageFill))
        // Browse: the catalog, with one update waiting (Study tools 1.0.0 is installed above).
        let catalog = PackageCatalog.shared
        let saved = (catalog.entries, catalog.state, catalog.checked)
        defer { (catalog.entries, catalog.state, catalog.checked) = saved }
        catalog.entries = try PackageCatalog.parse(Data(Self.catalogIndex.utf8))
        catalog.state = .loaded
        catalog.checked = Date()
        try await shoot("browse", CGSize(width: 520, height: 600),
                        PackageBrowseSheet(dismiss: {}, added: { _ in }).background(SettingsPalette.pageFill))
        // A source with its folder chosen: its page, and a chat that looked in it.
        let shotNotes = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "Lasso README/Notes", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: shotNotes, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: shotNotes.deletingLastPathComponent()) }
        try "# Pricing\nEnterprise is per seat, $12 a month. Annual plans get 10% off.".write(
            to: shotNotes.appending(path: "pricing.md"), atomically: true, encoding: .utf8)
        if let folder = store.installed.first(where: { $0.id == "meeting-notes" })?.package.setting("notes") {
            store.setValue(shotNotes.path, "meeting-notes", folder)
        }
        SourcePreferences.setAbout("pricing, roadmap, standup decisions, launch plan", "meeting-notes")
        defer { SourcePreferences.forget("meeting-notes") }
        try await shoot("source-page", CGSize(width: 520, height: 1200),
                        ScrollView { PackagePage(id: "meeting-notes", localOnly: false, removed: {}) }
                            .background(SettingsPalette.pageFill))

        let sourcesChat = ChatController.shared
        sourcesChat.newChat()
        let sourcesConversation = sourcesChat.active.id
        defer { sourcesChat.close(sourcesConversation) }
        var looked = ChatMessage(role: .assistant, text: "You decided on **per-seat pricing at $12 a month** for enterprise, with 10% off annual plans (pricing.md).")
        looked.steps = [ActivityStep(icon: "note.text", text: "Looked in Meeting Notes · sent 1 passage", done: true,
                                     actions: [.answerWithout(source: "meeting-notes", name: "Meeting Notes"),
                                               .onlyWhenMentioned(source: "meeting-notes", name: "Meeting Notes")])]
        looked.sourceHits = [SourceHit(source: "Meeting Notes", title: "pricing", url: shotNotes.appending(path: "pricing.md"),
                                       snippet: "Enterprise is per seat, $12 a month.")]
        var asked = ChatMessage(role: .user, text: "and the launch date?")
        asked.mentions = ["Meeting Notes"]
        var nothing = ChatMessage(role: .assistant, text: "Your notes don't mention a launch date yet.")
        nothing.steps = [ActivityStep(icon: "note.text", text: "Searched Meeting Notes · nothing matched", done: true)]
        sourcesChat.messages = [ChatMessage(role: .user, text: "what did we decide on pricing?"), looked, asked, nothing]
        sourcesChat.mention("meeting-notes")
        try await shoot("sources-chat", CGSize(width: 420, height: 560), ChatView().background(Color(white: 0.12)))

        // 0.26: a folder of docs next to your own notes. The file list by folder, and a question that
        // needs both a note and a doc page.
        let kestrel = shotNotes.appending(path: "projects/kestrel.md"), whatsNew = shotNotes.appending(path: "python-3.15/whatsnew/3.15.md")
        for file in [kestrel, whatsNew] {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "# x".write(to: file, atomically: true, encoding: .utf8)
        }
        var listed = ChatMessage(role: .assistant, text: "557 notes. **python-3.15/** is the Python 3.15 documentation (552 pages). Your own: **projects/** (kestrel.md), **meetings/** (1), **inbox/** (1), and adobo.md and todo.md at the top.")
        listed.steps = [ActivityStep(icon: "note.text", text: "Listed the files in Meeting Notes", done: true)]
        var mixed = ChatMessage(role: .assistant, text: "Kestrel runs **Python 3.12** (kestrel.md). Lazy imports (`lazy import`, PEP 810) are new in **3.15**, so it can't use them until it upgrades.")
        mixed.steps = [ActivityStep(icon: "note.text", text: "Looked in Meeting Notes · sent 2 passages", done: true,
                                    actions: [.answerWithout(source: "meeting-notes", name: "Meeting Notes"),
                                              .onlyWhenMentioned(source: "meeting-notes", name: "Meeting Notes")])]
        mixed.sourceHits = [SourceHit(source: "Meeting Notes", title: "Project Kestrel (projects/kestrel)", url: kestrel,
                                      snippet: "Stack: Python 3.12 on the servers, FastAPI, Postgres 16."),
                            SourceHit(source: "Meeting Notes", title: "What's new in Python 3.15", url: whatsNew,
                                      snippet: "PEP 810: Explicit lazy imports")]
        sourcesChat.messages = [ChatMessage(role: .user, text: "what's in my notes?"), listed,
                                ChatMessage(role: .user, text: "which python version does project Kestrel use, and can it use lazy imports?"), mixed]
        sourcesChat.active.mentions = []
        try await shoot("notes-and-docs", CGSize(width: 420, height: 640), ChatView().background(Color(white: 0.12)))

        // 0.27: the source's own offer for a typo (a step for the user, never the model), and a
        // follow-up the source answers with the previous question's subject.
        var typo = ChatMessage(role: .assistant, text: "Your notes don't mention “frozendcit”, and I don't know that name.")
        typo.steps = [ActivityStep(icon: "note.text", text: "Searched Meeting Notes · nothing matched", done: true,
                                   actions: [.searchFor(source: "meeting-notes", name: "Meeting Notes", query: "frozendict", label: "Did you mean “frozendict”?")])]
        var fixed = ChatMessage(role: .assistant, text: "`frozendict` is new in **3.15** (PEP 814): an immutable dict you can hash and use as a key.")
        fixed.steps = [ActivityStep(icon: "note.text", text: "Searched Meeting Notes for “frozendict” · sent 2 passages", done: true)]
        fixed.sourceHits = [SourceHit(source: "Meeting Notes", title: "What's new in Python 3.15", url: whatsNew, snippet: "PEP 814: Add frozendict built-in type")]
        var example = ChatMessage(role: .assistant, text: "```python\nconfig = frozendict(host=\"localhost\", port=8080)\ncache[config] = load()\n```")
        example.steps = [ActivityStep(icon: "note.text", text: "Looked in Meeting Notes for “frozendict example” · sent 1 passage", done: true,
                                      actions: [.answerWithout(source: "meeting-notes", name: "Meeting Notes")])]
        example.sourceHits = [SourceHit(source: "Meeting Notes", title: "Built-in Types", url: whatsNew, snippet: "class frozendict(**kwargs)")]
        sourcesChat.messages = [ChatMessage(role: .user, text: "how does frozendcit work"), typo, fixed,
                                ChatMessage(role: .user, text: "show me an example"), example]
        try await shoot("source-hooks-chat", CGSize(width: 420, height: 720), ChatView().background(Color(white: 0.12)))

        // 0.27: a source on the hooks, its review lines, and Go back after an update.
        let hooked = """
        {"lasso": 1, "id": "notes-hooks", "version": "VERSION", "name": "My notes", "summary": "Lets chat answer from a folder of your Markdown notes.",
         "author": "Lasso", "settings": [{"id": "notes", "label": "Notes folder", "kind": "folder"}],
         "commands": [{"id": "search", "title": "My notes", "surfaces": ["search"], "input": ["query"], "output": "results", "hook": "source/1", "ranks": true,
                       "run": {"script": {"path": "scripts/search.sh", "timeout": 5}}, "test": {"query": "standup"}},
                      {"id": "describe", "title": "What's in it", "hook": "describe/1", "run": {"script": {"path": "scripts/search.sh"}}}]}
        """
        let shScript = ["scripts/search.sh": Data("#!/bin/sh\necho '{\"status\": \"nothing\", \"results\": []}'\n".utf8)]
        try store.install(Data(hooked.replacingOccurrences(of: "VERSION", with: "1.4.0").utf8), files: shScript, origin: .catalog)
        try store.install(Data(hooked.replacingOccurrences(of: "VERSION", with: "1.5.0").utf8), files: shScript, origin: .catalog)
        if let folder = store.installed.first(where: { $0.id == "notes-hooks" })?.package.setting("notes") {
            store.setValue(shotNotes.path, "notes-hooks", folder)
        }
        SourcePreferences.setAbout("adobo, meetings, projects, python, todo", "notes-hooks")
        defer { SourcePreferences.forget("notes-hooks") }
        try await shoot("source-hooks-page", CGSize(width: 520, height: 1500),
                        ScrollView { PackagePage(id: "notes-hooks", localOnly: false, removed: {}) }
                            .background(SettingsPalette.pageFill))

        // Table to CSV: how to use it, said plainly.
        try store.install(Data("""
            {"lasso": 1, "id": "table-to-csv", "version": "1.1.0", "name": "Table to CSV", "summary": "Turns a table you lasso into a CSV file.",
             "author": "Lasso", "icon": {"symbol": "tablecells"}, "commands": [{"id": "to-csv", "title": "Table to CSV", "symbol": "tablecells",
               "surfaces": ["toolbar"], "input": ["table"], "when": {"detects": ["table"]}, "output": "file",
               "howTo": "Lasso a table on screen (a spreadsheet, a web page, a screenshot), then click **Table to CSV**. The file shows in Finder.",
               "run": {"script": {"path": "scripts/to-csv.py"}}}]}
            """.utf8), files: ["scripts/to-csv.py": Data("#!/usr/bin/env python3\n".utf8)], origin: .catalog)
        try await shoot("table-to-csv", CGSize(width: 520, height: 470),
                        ScrollView { PackagePage(id: "table-to-csv", localOnly: false, removed: {}) }
                            .background(SettingsPalette.pageFill))
        // A package that runs by itself on every capture, once allowed.
        try store.install(Data("""
            {"lasso": 1, "id": "capture-log", "version": "1.0.0", "name": "Capture Log", "summary": "Keeps a dated log of what you lasso.",
             "author": "Lasso", "icon": {"symbol": "list.bullet.rectangle"}, "commands": [{"id": "log", "title": "Capture log",
               "surfaces": ["event"], "on": ["capture"], "input": ["text", "image", "source"], "output": "file",
               "run": {"script": {"path": "scripts/log.py"}}}]}
            """.utf8), files: ["scripts/log.py": Data("#!/usr/bin/env python3\n".utf8)], origin: .catalog)
        try await shoot("events", CGSize(width: 520, height: 880),
                        ScrollView { PackagePage(id: "capture-log", localOnly: false, removed: {}) }
                            .background(SettingsPalette.pageFill))
        // Settings › Privacy › Permissions.
        try await shoot("permissions", CGSize(width: 520, height: 236),
                        Form { PermissionsSection() }.formStyle(.grouped).background(SettingsPalette.pageFill))

        let chat = ChatController.shared
        chat.newChat()
        let conversation = chat.active.id
        defer { chat.close(conversation) }
        let chatSize = CGSize(width: 420, height: 560)

        // Package tools in chat: one that only looks something up, one that asks first.
        var converted = ChatMessage(role: .assistant, text: "5 US dollars is about **4.61 euros** at today's rate.")
        converted.steps = [ActivityStep(icon: "shippingbox", text: "Used Convert currency", done: true)]
        var asking = ChatMessage(role: .assistant, text: "", isStreaming: true)
        asking.steps = [ActivityStep(icon: "shippingbox", text: "Add a task")]
        asking.toolApproval = PackageToolRequest(packageName: "Tasks", title: "Add a task", symbol: "checklist",
                                                 effect: "Sends the text below to tasks.example.com",
                                                 arguments: [.init(name: "text", value: "Buy milk on the way home")])
        chat.messages = [
            ChatMessage(role: .user, text: "How much is $5 in euros?"),
            converted,
            ChatMessage(role: .user, text: "Remind me to buy milk on the way home"),
            asking,
        ]
        try await shoot("chat-tools", chatSize, ChatView().background(Color(white: 0.12)))

        // The Agent: steps, then a command it wants to run.
        var counted = ChatMessage(role: .assistant, text: "There are **3** Markdown files in your Documents folder. The longest is `notes.md`.")
        counted.steps = [ActivityStep(icon: "magnifyingglass", text: "Searched files · *.md", done: true),
                         ActivityStep(icon: "doc.text", text: "Read a file · notes.md", done: true)]
        counted.viaAgent = true
        var risky = ChatMessage(role: .assistant, text: "", isStreaming: true)
        risky.viaAgent = true
        risky.steps = [ActivityStep(icon: "hand.raised", text: "Waiting for your approval")]
        risky.approval = HermesApproval(runID: "r", requestID: "1", command: "rm -r ~/Downloads/old-builds",
                                        reason: "recursive delete", choices: ["once", "session", "deny"])
        chat.messages = [
            ChatMessage(role: .user, text: "How many markdown files are in Documents?"),
            counted,
            ChatMessage(role: .user, text: "Clean up my old builds in Downloads"),
            risky,
        ]
        try await shoot("agent", chatSize, ChatView().background(Color(white: 0.12)))
    }
}
