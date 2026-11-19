import Testing
import SwiftUI
@testable import Lasso

/// Renders a Hermes reply bubble (activity steps + the approval card) to a PNG, for looking at the
/// layout without driving the app. Opt-in: `TEST_RUNNER_LASSO_RENDER_DIR=/some/dir`.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["LASSO_RENDER_DIR"] != nil))
struct HermesChatRenderTests {
    private func render(_ message: ChatMessage, to name: String) throws {
        let dir = try #require(ProcessInfo.processInfo.environment["LASSO_RENDER_DIR"])
        let view = MessageBubble(message: message, fontSize: 13)
            .frame(width: 380)
            .padding(12)
            .background(Color(white: 0.13))
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: dir).appending(path: name))
    }

    @Test func approvalPending() throws {
        var turn = HermesTurn()
        turn.apply(.toolStarted(tool: "search_files", preview: "*.log in ~/Downloads"))
        turn.apply(.toolCompleted(tool: "search_files", duration: 0.3, failed: false))
        turn.apply(.toolStarted(tool: "terminal", preview: "rm -r ~/Downloads/old-logs"))
        let request = HermesApproval(runID: "r", requestID: "q", command: "rm -r ~/Downloads/old-logs",
                                     reason: "recursive delete", choices: ["once", "session", "always", "deny"])
        turn.apply(.approvalRequested(request))
        var message = ChatMessage(role: .assistant, text: "", isStreaming: true)
        message.steps = turn.steps
        message.approval = turn.approval
        try render(message, to: "hermes-approval.png")
    }

    @Test func finishedAnswer() throws {
        var turn = HermesTurn()
        turn.apply(.toolStarted(tool: "web_search", preview: "macOS 27.2 release notes"))
        turn.apply(.toolCompleted(tool: "web_search", duration: 1.6, failed: false))
        turn.apply(.toolStarted(tool: "web_extract", preview: "support.apple.com/en-us/…"))
        turn.apply(.toolCompleted(tool: "web_extract", duration: 2.2, failed: false))
        turn.apply(.completed(output: "**macOS 27.2** adds three things worth knowing:\n\n- Faster Spotlight indexing\n- A new Passwords sharing sheet\n- Fixes for external displays waking", inputTokens: nil, outputTokens: nil))
        var message = ChatMessage(role: .assistant, text: turn.text)
        message.steps = turn.steps
        try render(message, to: "hermes-answer.png")
    }

    @Test func unattendedNotice() throws {
        var turn = HermesTurn()
        turn.apply(.toolStarted(tool: "terminal", preview: "rm -r ~/Downloads/old-logs"))
        turn.apply(.toolCompleted(tool: "terminal", duration: 0.4, failed: false))
        turn.apply(.completed(output: "Removed the old logs folder.", inputTokens: nil, outputTokens: nil))
        var message = ChatMessage(role: .assistant, text: turn.text)
        message.steps = turn.steps
        message.notice = HermesAgent.unattendedNotice
        try render(message, to: "hermes-unattended.png")
    }
}
