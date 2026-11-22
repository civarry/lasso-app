import Foundation
import Testing
@testable import Lasso

/// Review of the QA round 8 fixes (f9e3774). Each test fails on that commit; its comment says what goes
/// wrong for the user.
@MainActor
@Suite(.serialized)
struct Round8ReviewTests {

    // MARK: Regenerate a /command: the `prepare` closure

    private func withTranslate(_ body: (RecordingServer) async throws -> Void) async throws {
        let server = try await RecordingServer()
        let name = "lasso-r8review-\(UUID().uuidString.prefix(6))"
        let root = FileManager.default.temporaryDirectory.appending(path: name, directoryHint: .isDirectory)
        let real = PackageStore.shared
        let store = PackageStore(root: root, defaults: UserDefaults(suiteName: name)!)
        PackageStore.shared = store
        defer { PackageStore.shared = real; real.reload(); try? FileManager.default.removeItem(at: root); server.stop() }
        let package = try store.install(Data(PackageSurfaceTests.manifest.utf8), origin: .file)
        store.setValue(server.base, package.id, try #require(package.setting("server")))
        // Required: without it the regenerate would go to this Mac's real model.
        try #require(PackageRegistry.shared.slashCommands().map(\.name) == ["/tr"], "precondition: /tr is offered")
        server.answer(.init(body: Data(#"{"out": "hola de nuevo"}"#.utf8)))
        try await body(server)
    }

    /// Regenerate on a /command captures `uIdx` (the question's index) and removes
    /// `uIdx..<messages.count` later, inside the Task, after the async `detects` check. Nothing is
    /// streaming during that wait, so Delete is enabled. Deleting an earlier exchange shifts the indices:
    /// the closure then removes the wrong range (here nothing), and the new reply is appended after the
    /// old one, so the old /command exchange stays as a duplicate.
    @Test func deletingAnEarlierExchangeWhileARegeneratedCommandStartsDoesNotDuplicateIt() async throws {
        try await withTranslate { _ in
            let chat = ChatController.shared
            chat.newChat()
            let id = chat.active.id
            defer { chat.close(id) }
            let a1 = ChatMessage(role: .assistant, text: "one")
            var reply = ChatMessage(role: .assistant, text: "hola mundo")
            reply.caption = "Surface test"
            chat.active.messages = [ChatMessage(role: .user, text: "first"), a1,
                                    ChatMessage(role: .user, text: "/tr hello world"), reply]
            chat.regenerate(reply.id)
            // Before the Task runs (in the app: while `detects` is awaited), the user deletes exchange 1.
            chat.deleteMessage(a1.id)
            for _ in 0..<50 where chat.isStreaming || chat.messages.last?.text != "hola de nuevo" {
                try await Task.sleep(for: .milliseconds(100))
            }
            let texts = chat.active.messages.map(\.text)
            #expect(texts.filter { $0 == "/tr hello world" }.count == 1,
                    "the regenerated command's question is in the chat twice: \(texts)")
        }
    }

    // MARK: isInsideCode and ~~~ inside a ``` block

    /// A ``` block that shows a ~~~ line (a Markdown example, a diff) toggles the new ~~~ tracking once and
    /// leaves it "open" after the block closes. A reasoning round after it (a tool loop thinks again) is
    /// then taken for text inside code: the raw `<think>` shows in the answer.
    @Test func aTildeLineInsideABacktickBlockDoesNotHideALaterThinkTag() {
        let raw = "Fence it like this:\n```markdown\n~~~\ncode\n```\nDone.<think>check the tool result</think>All set."
        let split = ChatController.splitReasoning(raw)
        #expect(split.reasoning == "check the tool result", "reasoning: \"\(split.reasoning)\"")
        #expect(!split.answer.contains("<think>"), "the think tag shows in the answer: \(split.answer)")
    }

    @Test func isInsideCodeIsFalseAfterAClosedBacktickBlockWithATildeLine() {
        let prefix: Substring = "```\n~~~\n```\nnow prose "
        #expect(!ChatController.isInsideCode(prefix))
    }

    // MARK: `$$` rule

    /// Multi-line display math whose closing line goes on with text ("$$ … \n … $$ where …") is common
    /// in model output. The lookahead needs the first `$$` line to END with `$$`, so the whole thing is
    /// now a paragraph with raw `$$` and LaTeX. Before f9e3774 it rendered as math plus a sentence.
    @Test func multiLineMathWithTextAfterTheCloserIsStillMath() {
        let text = "The line is\n\n$$y = m x +\nb$$ where m is the slope."
        let blocks = MarkdownParser.parse(text)
        #expect(blocks.contains { if case .math = $0 { return true }; return false }, "blocks: \(blocks)")
    }

    @Test func multiLineMathEndingWithAPeriodIsStillMath() {
        let text = "So\n\n$$E = m c^2 +\np^2 c^2$$."
        let blocks = MarkdownParser.parse(text)
        #expect(blocks.contains { if case .math = $0 { return true }; return false }, "blocks: \(blocks)")
    }

    /// Streaming: `$$x = 1 +` with the rest not yet arrived has no closer below it, so it now renders as
    /// a paragraph of raw LaTeX, then snaps into an equation when the closing line lands. Before, it
    /// streamed as (unterminated) math from the first token.
    @Test func halfArrivedMultiLineMathStreamsAsMath() {
        let text = "The sum is\n\n$$\\sum_{i=1}^{n} i =\n\\frac{n(n+1)}"
        let blocks = MarkdownParser.parse(text, streaming: true)
        #expect(blocks.contains { if case .math = $0 { return true }; return false },
                "mid-stream math shows as raw text: \(blocks)")
    }

    // MARK: outsideCode

    /// `outsideCode` joins the pieces around a code span with a space, so "*`make`" becomes "* " and the
    /// lone `*` reads as a bullet-like star. Mid-stream, italic-wrapped code is no longer closed: a raw
    /// `*` shows until the closer arrives. (Before f9e3774 it was closed.)
    @Test func streamingItalicWrappedCodeIsClosed() {
        let line = "Run *`make`"
        #expect(StreamStabilizer.stabilize(line) == "Run *`make`*", "stabilized to: \(StreamStabilizer.stabilize(line))")
    }
}

/// Run alone: on f9e3774 this crashes the test process ("Range requires lowerBound <= upperBound").
@MainActor
@Suite(.serialized)
struct Round8ReviewCrashTests {
    /// Same window as above, but the chat gets shorter than the captured `uIdx`: the `prepare` closure's
    /// `session.messages[uIdx...]` traps and Lasso quits.
    @Test func deletingTwoEarlierExchangesWhileARegeneratedCommandStartsDoesNotCrash() async throws {
        let server = try await RecordingServer()
        let name = "lasso-r8crash-\(UUID().uuidString.prefix(6))"
        let root = FileManager.default.temporaryDirectory.appending(path: name, directoryHint: .isDirectory)
        let real = PackageStore.shared
        let store = PackageStore(root: root, defaults: UserDefaults(suiteName: name)!)
        PackageStore.shared = store
        defer { PackageStore.shared = real; real.reload(); try? FileManager.default.removeItem(at: root); server.stop() }
        let package = try store.install(Data(PackageSurfaceTests.manifest.utf8), origin: .file)
        store.setValue(server.base, package.id, try #require(package.setting("server")))
        try #require(PackageRegistry.shared.slashCommands().map(\.name) == ["/tr"], "precondition: /tr is offered")
        server.answer(.init(body: Data(#"{"out": "hola de nuevo"}"#.utf8)))

        let chat = ChatController.shared
        chat.newChat()
        let id = chat.active.id
        defer { chat.close(id) }
        let a1 = ChatMessage(role: .assistant, text: "one"), a2 = ChatMessage(role: .assistant, text: "two")
        var reply = ChatMessage(role: .assistant, text: "hola mundo")
        reply.caption = "Surface test"
        chat.active.messages = [ChatMessage(role: .user, text: "first"), a1, ChatMessage(role: .user, text: "second"), a2,
                                ChatMessage(role: .user, text: "/tr hello world"), reply]
        chat.regenerate(reply.id)
        chat.deleteMessage(a1.id)
        chat.deleteMessage(a2.id)
        for _ in 0..<50 where chat.isStreaming || chat.messages.last?.text != "hola de nuevo" {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(chat.active.messages.map(\.text).filter { $0 == "/tr hello world" }.count == 1)
    }
}
