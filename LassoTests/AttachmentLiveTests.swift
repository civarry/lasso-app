import Testing
import Foundation
import AppKit
@testable import Lasso

/// Attachments end to end through the chat, on real models. Opt-in:
///
///     TEST_RUNNER_LASSO_ATTACH_LIVE=1 [TEST_RUNNER_LASSO_TEST_MLX=<id>] xcodebuild test -scheme Lasso -only-testing:LassoTests/AttachmentLiveTests
@MainActor
@Suite(.serialized, .timeLimit(.minutes(10)), .enabled(if: ProcessInfo.processInfo.environment["LASSO_ATTACH_LIVE"] == "1"))
struct AttachmentLiveTests {
    private let chat = ChatController.shared
    private let intelligence = IntelligenceCoordinator.shared

    private func lastReply() -> ChatMessage? { chat.messages.last { $0.role == .assistant } }
    private func waitForReply(_ seconds: Double = 300) async throws {
        try await Task.sleep(for: .milliseconds(150))
        let deadline = Date().addingTimeInterval(seconds)
        while chat.isStreaming, Date() < deadline { try await Task.sleep(for: .milliseconds(200)) }
    }
    private func dump(_ label: String) {
        let m = lastReply()
        print("[attach-live] \(label): steps=\(m?.steps.map(\.text) ?? []) text=\(m?.text.prefix(160) ?? "") error=\(m?.isError ?? false)")
    }

    private func textImage(_ text: String) -> CGImage {
        let size = NSSize(width: 520, height: 140)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill(); NSRect(origin: .zero, size: size).fill()
        (text as NSString).draw(at: NSPoint(x: 24, y: 50),
                                withAttributes: [.font: NSFont.boldSystemFont(ofSize: 40), .foregroundColor: NSColor.black])
        image.unlockFocus()
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    }

    private func tempFile(_ name: String, _ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString.prefix(6))-\(name)")
        try Data(text.utf8).write(to: url)
        return url
    }

    @Test func aModelThatCantSeeStillGetsTheImagesText() async throws {
        let (preferred, agent) = (intelligence.preferred, chat.hermesSelected)
        intelligence.preferred = .onDevice
        if chat.hermesSelected { chat.hermesSelected = false }
        chat.newChat()
        let conversation = chat.active.id
        defer { chat.close(conversation); intelligence.preferred = preferred; chat.hermesSelected = agent }
        await chat.refreshCapabilities()
        print("[attach-live] apple: imageInputAvailable=\(chat.imageInputAvailable)")
        chat.attach(textImage("INVOICE 4471"))
        chat.send(text: "What is the invoice number in this image? Reply with just the number.")
        try await waitForReply()
        dump("image on apple")
        let reply = try #require(lastReply())
        #expect(!reply.isError, "\(reply.text.prefix(200))")
        #expect(reply.text.contains("4471"))
    }

    @Test func aTextFileReachesARegularModel() async throws {
        let agent = chat.hermesSelected
        if chat.hermesSelected { chat.hermesSelected = false }
        chat.newChat()
        let conversation = chat.active.id
        let file = try tempFile("notes.txt", "Shopping list\nThe secret word is TAMARIND-58.\n")
        defer { chat.close(conversation); chat.hermesSelected = agent; try? FileManager.default.removeItem(at: file) }
        chat.attachFile(file)
        #expect(chat.pendingFiles.count == 1)
        chat.send(text: "What is the secret word in the attached file? Reply with just the word.")
        try await waitForReply()
        dump("txt on \(intelligence.textEngineLabel)")
        let reply = try #require(lastReply())
        #expect(!reply.isError, "\(reply.text.prefix(200))")
        #expect(reply.text.uppercased().contains("TAMARIND"))
        #expect(chat.messages.first { $0.role == .user }?.files.first?.name == file.lastPathComponent)
    }

    @Test func theAgentOpensAnAttachedFileItself() async throws {
        let model = try #require(ProcessInfo.processInfo.environment["LASSO_TEST_MLX"], "needs TEST_RUNNER_LASSO_TEST_MLX")
        let (preferred, mlxWas, agent) = (intelligence.preferred, intelligence.mlxModel, chat.hermesSelected)
        intelligence.preferred = .mlx
        intelligence.mlxModel = model
        chat.newChat()
        let conversation = chat.active.id
        let file = try tempFile("brief.md", "# Brief\nThe project codename is OKRA-913.\n")
        defer {
            chat.close(conversation); intelligence.preferred = preferred; intelligence.mlxModel = mlxWas
            if chat.hermesSelected != agent { chat.hermesSelected = agent }
            HermesRuntime.shared.stop()
            try? FileManager.default.removeItem(at: file)
        }
        if !chat.hermesSelected { chat.toggleAgent() }
        chat.attachFile(file)
        chat.send(text: "What is the project codename in the attached file?")
        try await waitForReply(400)
        dump("md via agent")
        let reply = try #require(lastReply())
        #expect(!reply.isError, "\(reply.text.prefix(200))")
        #expect(reply.text.uppercased().contains("OKRA-913"))
        #expect(reply.steps.contains { !$0.text.hasPrefix("Answering") && !$0.text.hasPrefix("First reply") },
                "the agent should have used a tool to open the file")
    }
}
