import CoreGraphics
import Foundation
import Testing
@testable import Lasso

/// QA round 8: regressions around the round 1-7 fixes, chat side. Each test fails on the code as it
/// stands; its comment says what goes wrong for the user.
@MainActor
@Suite(.serialized)
struct ChatRound8Tests {
    static func image() throws -> CGImage {
        let ctx = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        return try #require(ctx.makeImage())
    }

    // MARK: Stop after /help mid-reply

    /// /help and /about run from the slash palette while a reply streams (the palette isn't gated on
    /// `isStreaming`). The note lands after the streaming placeholder, and `cancelStreaming` only looks at
    /// `messages.last`: it settles the note and leaves the real reply spinning forever.
    @Test func stopAfterAHelpNoteMidReplySettlesTheReply() {
        let chat = ChatController.shared
        chat.newChat()
        let id = chat.active.id
        defer { chat.close(id) }
        chat.active.messages = [ChatMessage(role: .user, text: "tell me a story"),
                                ChatMessage(role: .assistant, text: "", isStreaming: true)]
        chat.active.isStreaming = true
        chat.postLocalMessage("HELP TEXT")
        chat.cancelStreaming()
        let reply = chat.active.messages[1]
        #expect(!reply.isStreaming, "the stopped reply still shows as streaming (spinner forever)")
        #expect(reply.text == "(Stopped.)", "the stopped reply's text: \"\(reply.text)\"")
    }

    /// The turn's history is everything before its question and reply. A /help note posted mid-reply
    /// lands after them; "all but the last two" then kept the question, sending it to the model twice.
    @Test func aHelpNoteMidReplyDoesNotRepeatTheQuestionInHistory() {
        var note = ChatMessage(role: .assistant, text: "HELP TEXT")
        note.isLocalNote = true
        let messages = [ChatMessage(role: .user, text: "q1"), ChatMessage(role: .assistant, text: "a1"),
                        ChatMessage(role: .user, text: "tell me a story"),
                        ChatMessage(role: .assistant, text: "", isStreaming: true), note]
        #expect(ChatController.beforeTurn(messages).map(\.text) == ["q1", "a1"])
        #expect(ChatController.beforeTurn(Array(messages.dropLast())).map(\.text) == ["q1", "a1"])
    }

    // MARK: Reply versions and images

    /// Regenerating an Agent reply that was only an image keeps it as `asVersion`, which has no images:
    /// going back to ‹ 1/2 › shows an empty bubble, the image is gone.
    @Test func goingBackToAnImageOnlyAnswerShowsTheImage() throws {
        var old = ChatMessage(role: .assistant, text: "", attachments: [Attachment(image: try Self.image())])
        old.viaAgent = true
        #expect(old.isAnswer, "precondition: an image-only Agent reply is an answer")
        var reply = ChatMessage(role: .assistant, text: "A new text answer")
        reply.versions = [old.asVersion, ReplyVersion(text: "")]
        reply.versionIndex = 1
        reply.showVersion(0)
        #expect(!reply.attachments.isEmpty, "answer 1's image is lost; the bubble is empty")
        #expect(reply.isAnswer, "answer 1 no longer counts as an answer (text \"\(reply.text)\")")
    }

    /// The other direction: a reply's images aren't part of its version, so the newest answer's image
    /// stays under an older text answer when switching.
    @Test func switchingToAnEarlierAnswerDoesNotShowTheNewAnswersImage() throws {
        var reply = ChatMessage(role: .assistant, text: "Here's the chart.", attachments: [Attachment(image: try Self.image())])
        reply.viaAgent = true
        reply.versions = [ReplyVersion(text: "I can't make charts."), reply.asVersion]
        reply.versionIndex = 1
        reply.showVersion(0)
        #expect(reply.text == "I can't make charts.")
        #expect(reply.attachments.isEmpty, "answer 2's chart shows under answer 1's \"I can't make charts.\"")
    }

    // MARK: Code runs of deleted replies

    /// Round 1-3 made close, /clear and eviction drop a chat's code-run outputs (`CodeRunner.forget`).
    /// Deleting a message (or everything from it) doesn't: every output and picture stays in memory for
    /// the session.
    @Test func deletingAReplyDropsItsCodeRuns() {
        let chat = ChatController.shared
        chat.newChat()
        let id = chat.active.id
        defer { chat.close(id) }
        let reply = ChatMessage(role: .assistant, text: "```python\nprint(1)\n```")
        chat.active.messages = [ChatMessage(role: .user, text: "run"), reply]
        let key = CodeRunner.key(reply.id, "print(1)")
        CodeRunner.shared.runs[key] = CodeRunner.Run(title: "Run", lines: [], console: nil, error: nil, running: false,
                                                     started: Date(), elapsed: 0.1, packageID: "p", commandID: "c",
                                                     code: "print(1)", language: "python", reply: reply.text)
        defer { CodeRunner.shared.runs[key] = nil }
        chat.deleteMessage(reply.id)
        #expect(chat.active.messages.isEmpty)
        #expect(CodeRunner.shared.runs[key] == nil, "a deleted reply's code run stays in memory")
    }

    @Test func deletingFromHereDropsTheCodeRunsBelow() {
        let chat = ChatController.shared
        chat.newChat()
        let id = chat.active.id
        defer { chat.close(id) }
        let reply = ChatMessage(role: .assistant, text: "```python\nprint(2)\n```")
        chat.active.messages = [ChatMessage(role: .user, text: "q1"), ChatMessage(role: .assistant, text: "a1"),
                                ChatMessage(role: .user, text: "run"), reply]
        let key = CodeRunner.key(reply.id, "print(2)")
        CodeRunner.shared.runs[key] = CodeRunner.Run(title: "Run", lines: [], console: nil, error: nil, running: false,
                                                     started: Date(), elapsed: 0.1, packageID: "p", commandID: "c",
                                                     code: "print(2)", language: "python", reply: reply.text)
        defer { CodeRunner.shared.runs[key] = nil }
        chat.deleteFromHere(chat.active.messages[2].id)
        #expect(chat.active.messages.count == 2)
        #expect(CodeRunner.shared.runs[key] == nil, "code runs of the truncated replies stay in memory")
    }

    // MARK: Save and load

    /// The `@My notes` line on a user bubble (`ChatMessage.mentions`) isn't in `MessageDTO`: after a
    /// relaunch the bubble no longer says which sources the question was sent with.
    @Test func mentionsOnAUserMessageSurviveSaveAndLoad() {
        let c = Conversation()
        var user = ChatMessage(role: .user, text: "what did I write about tides?")
        user.mentions = ["My notes"]
        c.messages = [user, ChatMessage(role: .assistant, text: "You wrote...")]
        let back = ConversationStore.rebuild(ConversationStore.snapshot(c))
        #expect(back.messages[0].mentions == ["My notes"], "mentions after reload: \(back.messages[0].mentions)")
    }

    /// An image the Agent showed from this Mac opens its file on click (`Attachment.sourcePath`). The
    /// path isn't saved (`AttachmentDTO` has no field), so after relaunch the click opens a 512px
    /// thumbnail with no file.
    @Test func anAgentImagesFilePathIsSaved() throws {
        let c = Conversation()
        var reply = ChatMessage(role: .assistant, text: "",
                                attachments: [Attachment(image: try Self.image(), sourcePath: "/tmp/qa8-chart.png")])
        reply.viaAgent = true
        c.messages = [ChatMessage(role: .user, text: "show me the chart"), reply]
        let data = try JSONEncoder().encode(ConversationStore.snapshot(c))
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("qa8-chart.png"), "the image's file path isn't in the saved conversation")
    }

    /// A native-vision turn sends its pictures as `imageBase64s` and folds no description into
    /// `promptText`. Neither survives a relaunch (the thumbnail does, so the image still shows): a
    /// follow-up about the picture goes to a model that has no trace of it.
    @Test func aReloadedImageTurnStillGivesTheModelTheImage() {
        let c = Conversation()
        var user = ChatMessage(role: .user, text: "what breed is this dog?")
        user.promptText = "what breed is this dog?"
        user.imageBase64s = ["/9j/4AAQSkZJRgABAQ"]
        c.messages = [user, ChatMessage(role: .assistant, text: "A beagle.")]
        let before = ChatController.historyTurns(from: c.messages[...])
        #expect(before[0].imageBase64s.count == 1, "precondition")
        let back = ConversationStore.rebuild(ConversationStore.snapshot(c))
        let after = ChatController.historyTurns(from: back.messages[...])
        #expect(!after[0].imageBase64s.isEmpty || after[0].text != "what breed is this dog?",
                "after reload the image turn is just \"\(after[0].text)\": no image, no description")
    }

    // MARK: Regenerate a /command that can't run now

    /// Regenerate removes the exchange first, then `send` hands it to `runPackageSlash`, which shows a
    /// composer notice and returns when the command can't run now (a setting cleared, local-only on).
    /// The question and every answer it had are gone, with no undo.
    @Test func regeneratingASlashReplyThatCantRunKeepsTheExchange() throws {
        let name = "lasso-qa8-\(UUID().uuidString.prefix(6))"
        let root = FileManager.default.temporaryDirectory.appending(path: name, directoryHint: .isDirectory)
        let real = PackageStore.shared
        let store = PackageStore(root: root, defaults: UserDefaults(suiteName: name)!)
        PackageStore.shared = store
        defer { PackageStore.shared = real; real.reload(); try? FileManager.default.removeItem(at: root) }
        // Installed, but its server setting is empty: "Finish setting it up in Settings › Packages."
        _ = try store.install(Data(PackageSurfaceTests.manifest.utf8), origin: .file)
        // Required, not expected: without it the regenerate would go to this Mac's real model.
        try #require(PackageRegistry.shared.slashCommands().map(\.name) == ["/tr"], "precondition: /tr is offered")

        let chat = ChatController.shared
        chat.newChat()
        let id = chat.active.id
        defer { chat.close(id) }
        var reply = ChatMessage(role: .assistant, text: "hola mundo")
        reply.caption = "Surface test"
        chat.active.messages = [ChatMessage(role: .user, text: "/tr hello world"), reply]
        chat.regenerate(reply.id)
        let texts = chat.active.messages.map(\.text)
        #expect(texts.contains("hola mundo"), "the exchange was deleted; messages now: \(texts), notice: \(chat.composerNotice ?? "nil")")
        chat.composerNotice = nil
    }
}
