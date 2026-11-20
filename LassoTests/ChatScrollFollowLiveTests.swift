import Testing
import AppKit
import SwiftUI
@testable import Lasso

/// The real chat view in a window: a streaming reply keeps the view at the bottom, scrolling up stops
/// that, and an Agent's steps (which grow the reply without changing its text) are followed too.
/// Needs a window on screen (not a locked screen). Opt-in: TEST_RUNNER_LASSO_CHAT_SCROLL=1.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["LASSO_CHAT_SCROLL"] == "1"))
struct ChatScrollFollowLiveTests {
    private func scrollView(in view: NSView) -> NSScrollView? {
        if let s = view as? NSScrollView, s.documentView != nil, s.hasVerticalScroller { return s }
        for sub in view.subviews { if let s = scrollView(in: sub) { return s } }
        return nil
    }

    /// Points between the bottom of what's shown and the end of the content.
    private func distanceFromBottom(_ s: NSScrollView) -> CGFloat {
        guard let doc = s.documentView else { return .infinity }
        let visible = s.contentView.bounds
        return doc.isFlipped ? doc.frame.height - visible.maxY : visible.minY
    }

    @Test func followsTheReplyUntilYouScrollUp() async throws {
        let chat = ChatController.shared
        chat.newChat()
        let conversation = chat.active.id
        defer { chat.close(conversation) }
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 420, height: 420),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: ChatView())
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.contentView = nil }

        let line = "This is a line of a long streaming reply that keeps on growing as tokens arrive. "
        chat.messages = (0..<4).flatMap { i in
            [ChatMessage(role: .user, text: "question \(i)"), ChatMessage(role: .assistant, text: String(repeating: line, count: 4))]
        } + [ChatMessage(role: .user, text: "go"), ChatMessage(role: .assistant, text: "", isStreaming: true)]
        try await Task.sleep(for: .milliseconds(800))
        let content = try #require(window.contentView)
        let scroll = try #require(scrollView(in: content))
        let last = chat.messages.count - 1
        let atBottom: CGFloat = 12   // the list's 10 pt bottom padding, and rounding

        // 1. Streaming at a real model's pace (a word every few milliseconds): at the bottom throughout.
        var worst: CGFloat = 0
        for (i, word) in String(repeating: line, count: 25).split(separator: " ").enumerated() {
            chat.messages[last].text += word + " "
            try await Task.sleep(for: .milliseconds(8))
            if i > 20, i.isMultiple(of: 10) { worst = max(worst, distanceFromBottom(scroll)) }
        }
        print("[scroll] worst lag while streaming: \(worst)")
        try await Task.sleep(for: .milliseconds(400))
        print("[scroll] after streaming: \(distanceFromBottom(scroll))")
        #expect(distanceFromBottom(scroll) <= atBottom, "the view fell behind the streaming reply")

        // 2. An Agent's steps grow the reply without changing its text.
        for i in 0..<8 {
            chat.messages[last].steps.append(ActivityStep(icon: "terminal", text: "Ran a command · step \(i)", done: true))
            try await Task.sleep(for: .milliseconds(80))
        }
        try await Task.sleep(for: .milliseconds(400))
        print("[scroll] after steps: \(distanceFromBottom(scroll))")
        #expect(distanceFromBottom(scroll) <= atBottom, "the view didn't follow the Agent's steps")

        // 2b. The reported bug: after the steps, the old view had decided you'd scrolled away, showed
        // "Latest", and the answer that followed streamed in off screen.
        for word in String(repeating: line, count: 6).split(separator: " ") {
            chat.messages[last].text += word + " "
            try await Task.sleep(for: .milliseconds(8))
        }
        try await Task.sleep(for: .milliseconds(400))
        print("[scroll] answer after steps: \(distanceFromBottom(scroll))")
        #expect(distanceFromBottom(scroll) <= atBottom, "stopped following after the Agent's steps")

        // 3. Scrolling up stops following: more tokens don't pull the reader back down.
        let doc = try #require(scroll.documentView)
        let up = doc.isFlipped ? NSPoint(x: 0, y: 0) : NSPoint(x: 0, y: doc.frame.height - scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: up)
        scroll.reflectScrolledClipView(scroll.contentView)
        try await Task.sleep(for: .milliseconds(300))
        let before = scroll.contentView.bounds.origin.y
        for _ in 0..<10 {
            chat.messages[last].text += line
            try await Task.sleep(for: .milliseconds(60))
        }
        try await Task.sleep(for: .milliseconds(400))
        print("[scroll] after scrolling up: moved \(abs(scroll.contentView.bounds.origin.y - before))")
        #expect(abs(scroll.contentView.bounds.origin.y - before) < 2, "pulled back down after scrolling up")
        chat.messages[last].isStreaming = false
    }
}
