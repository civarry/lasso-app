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
        catalog.checked = Date().addingTimeInterval(-60)
        try await shoot("browse", CGSize(width: 520, height: 600),
                        PackageBrowseSheet(dismiss: {}, added: { _ in }).background(SettingsPalette.pageFill))
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
