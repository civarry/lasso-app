import Testing
import AppKit
import SwiftUI
@testable import Lasso

/// Renders the chat panel with typical content (plain reply, a reply with tool steps, an error, a
/// waiting approval) at a normal and the narrowest width, and the empty state. Opt-in:
/// TEST_RUNNER_LASSO_CHAT_SNAPSHOTS=<folder>.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["LASSO_CHAT_SNAPSHOTS"] != nil))
struct ChatSnapshotTests {
    @Test func renderTheChat() async throws {
        let folder = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LASSO_CHAT_SNAPSHOTS"]))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let chat = ChatController.shared
        chat.newChat()
        let conversation = chat.active.id
        defer { chat.close(conversation) }

        func render(_ name: String, width: CGFloat, height: CGFloat) async throws {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = NSColor(white: 0.12, alpha: 1)
            window.contentView = NSHostingView(rootView: ChatView())
            window.orderFrontRegardless()
            try await Task.sleep(for: .milliseconds(1200))
            let view = try #require(window.contentView)
            let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            try #require(rep.representation(using: .png, properties: [:])).write(to: folder.appending(path: "\(name).png"))
            window.orderOut(nil); window.contentView = nil
        }

        try await render("empty", width: 420, height: 520)

        var tools = ChatMessage(role: .assistant, text: "There are **3** Markdown files in your Documents folder.")
        tools.steps = [ActivityStep(icon: "magnifyingglass", text: "Searched files · *.md", done: true),
                       ActivityStep(icon: "doc.text", text: "Read a file · notes.md", done: true)]
        tools.viaAgent = true
        var failed = ChatMessage(role: .assistant, text: "The model didn't answer: the connection timed out.")
        failed.isError = true
        var asking = ChatMessage(role: .assistant, text: "", isStreaming: true)
        asking.steps = [ActivityStep(icon: "hand.raised", text: "Waiting for your approval")]
        asking.approval = HermesApproval(runID: "r", requestID: "1", command: "rm -r ~/Downloads/old-builds",
                                         reason: "recursive delete", choices: ["once", "session", "deny"])
        asking.approvalsWaiting = 2
        chat.messages = [
            ChatMessage(role: .user, text: "hi"),
            ChatMessage(role: .assistant, text: "Hey. What can I help with?"),
            ChatMessage(role: .user, text: "how many markdown files are in Documents?"),
            tools,
            ChatMessage(role: .user, text: "summarize the long one"),
            failed,
            ChatMessage(role: .user, text: "clean up old builds"),
            asking,
        ]
        try await render("conversation", width: 420, height: 760)
        try await render("narrow", width: 340, height: 760)
    }
}
