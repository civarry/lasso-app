import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Lasso

@MainActor
@Suite(.serialized)
struct ChatUIRegressionTests {
    /// A finished reply whose last fence never closed (cut off, stopped, or the model forgot) is still
    /// `closed: false`, so CodeBlockView withholds Copy and Run forever.
    @Test func finishedTextCompletesAnUnclosedFence() {
        let blocks = MarkdownParser.parse("Here:\n```python\nprint(1)", streaming: false)
        guard case .code(_, _, let closed)? = blocks.last else { Issue.record("no code block"); return }
        #expect(closed, "finished text: the block should count as complete")
    }

    /// Snippet indexes the original text with an offset measured in the folded text.
    @Test func snippetOffsetFromFoldedText() {
        let text = String(repeating: "ß", count: 30) + " needle and more text after it"
        let s = ChatSearch.snippet(text, around: "needle")
        print("QA snippet =", s)
        #expect(s.contains("needle"), "snippet lost the word: \(s)")
    }

    @Test func snippetCrashes() {
        let text = String(repeating: "ß", count: 80) + " needle"
        let s = ChatSearch.snippet(text, around: "needle")
        #expect(s.contains("needle"))
    }

    /// Esc in the chat panel (nothing else to cancel) should close the chat, not some other window.
    @Test func escInChatClosesTheResultCardInstead() async throws {
        FloatingPanelController.shared.present(AnyView(Text("result").frame(width: 320, height: 120)), anchor: nil)
        defer { FloatingPanelController.shared.close() }
        ChatPanelController.shared.present()
        defer { ChatPanelController.shared.close() }
        try await Task.sleep(for: .milliseconds(200))
        let chatPanel = try #require(ChatPanelController.shared.panel)
        let cardsBefore = NSApp.windows.filter { $0 is FloatingPanel && $0 !== chatPanel && $0.isVisible }.count
        chatPanel.cancelOperation(nil)
        try await Task.sleep(for: .milliseconds(100))
        let cardsAfter = NSApp.windows.filter { $0 is FloatingPanel && $0 !== chatPanel && $0.isVisible }.count
        print("QA cards before/after Esc in chat:", cardsBefore, cardsAfter, "chat open:", ChatPanelController.shared.isOpen)
        #expect(cardsAfter == cardsBefore, "Esc in the chat closed the result card")
        #expect(!ChatPanelController.shared.isOpen, "Esc in the chat left the chat open")
    }

    private func composer(in view: NSView) -> NSTextView? {
        if let t = view as? ComposerNSTextView { return t }
        for sub in view.subviews { if let t = composer(in: sub) { return t } }
        return nil
    }

    /// "thanks @bob" (no source called bob, or none installed): Return does nothing.
    @Test func returnSwallowedAfterAtWord() async throws {
        let chat = ChatController.shared
        chat.newChat()
        let id = chat.active.id
        defer { chat.close(id) }
        ChatPanelController.shared.present()
        defer { ChatPanelController.shared.close() }
        try await Task.sleep(for: .milliseconds(300))
        let panel = try #require(ChatPanelController.shared.panel)
        let content = try #require(panel.contentView)
        let tv = try #require(composer(in: content))
        panel.makeFirstResponder(tv)
        chat.active.input = "thanks @bob"
        tv.string = chat.active.input
        try await Task.sleep(for: .milliseconds(300))
        let before = chat.active.messages.count
        tv.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        try await Task.sleep(for: .milliseconds(300))
        let after = chat.active.messages.count
        if chat.isStreaming { chat.cancelStreaming() }
        print("QA @: sources=\(PackageRegistry.shared.sources(localOnly: false).map(\.name)) input='\(chat.active.input)' messages \(before)->\(after)")
        #expect(after > before, "Return didn't send 'thanks @bob'")
    }
    /// "thanks bob" (no source called bob, or none installed): Return does nothing.
    @Test func controlReturnSendsPlain() async throws {
        let chat = ChatController.shared
        chat.newChat()
        let id = chat.active.id
        defer { chat.close(id) }
        ChatPanelController.shared.present()
        defer { ChatPanelController.shared.close() }
        try await Task.sleep(for: .milliseconds(300))
        let panel = try #require(ChatPanelController.shared.panel)
        let content = try #require(panel.contentView)
        let tv = try #require(composer(in: content))
        panel.makeFirstResponder(tv)
        chat.active.input = "thanks bob"
        tv.string = chat.active.input
        try await Task.sleep(for: .milliseconds(300))
        let before = chat.active.messages.count
        tv.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        try await Task.sleep(for: .milliseconds(300))
        let after = chat.active.messages.count
        if chat.isStreaming { chat.cancelStreaming() }
        print("QA @: sources=\(PackageRegistry.shared.sources(localOnly: false).map(\.name)) input='\(chat.active.input)' messages \(before)->\(after)")
        #expect(after > before, "Return didn't send 'thanks @bob'")
    }

    /// Two identical code blocks in one reply, and the same code in another answer, keep their own runs.
    @Test func identicalCodeBlocksHaveTheirOwnRuns() {
        let id = UUID()
        #expect(CodeRunner.key(id, "print(1)", index: 0) != CodeRunner.key(id, "print(1)", index: 1))
        #expect(CodeRunner.key(id, "print(1)", version: 0) != CodeRunner.key(id, "print(1)", version: 1))
    }

    /// A half-typed message in the composer is wiped by Regenerate (and Edit/Resend).
    @Test func regenerateWipesComposerDraft() {
        let chat = ChatController.shared
        chat.newChat()
        let id = chat.active.id
        defer { chat.close(id) }
        let answer = ChatMessage(role: .assistant, text: "The first answer")
        chat.active.messages = [ChatMessage(role: .user, text: "hi"), answer]
        chat.active.input = "my half-written follow-up"
        chat.regenerate(answer.id)
        chat.cancelStreaming()
        print("QA draft after regenerate: '\(chat.active.input)' last user: '\(chat.active.messages.first?.text ?? "")'")
        #expect(chat.active.input == "my half-written follow-up", "draft lost")
    }
}
