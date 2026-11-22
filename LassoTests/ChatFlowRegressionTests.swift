import Foundation
import Network
import Testing
@testable import Lasso

/// Chat flow bugs a QA pass found; each test asserts the right behaviour.
@MainActor
@Suite(.serialized)
struct QAVersionTests {
    @Test func showingAGoodEarlierAnswerClearsTheErrorStyling() {
        var reply = ChatMessage(role: .assistant, text: "Couldn't reach the model.")
        reply.isError = true
        reply.versions = [ReplyVersion(text: "The good answer"), ReplyVersion(text: "")]
        reply.versionIndex = 1
        reply.showVersion(0)
        #expect(reply.text == "The good answer")
        #expect(!reply.isError, "good answer still flagged isError")
    }

    @Test func regenerateAfterGoingBackToTheGoodAnswerKeepsIt() {
        let chat = ChatController.shared
        chat.newChat()
        let id = chat.active.id
        defer { chat.close(id) }
        var reply = ChatMessage(role: .assistant, text: "Couldn't reach the model.")
        reply.isError = true
        reply.versions = [ReplyVersion(text: "The good answer"), ReplyVersion(text: "")]
        reply.versionIndex = 1
        chat.active.messages = [ChatMessage(role: .user, text: "hi"), reply]
        chat.showVersion(reply.id, 0)
        chat.regenerate(reply.id)
        chat.cancelStreaming()
        let last = chat.active.messages.last!
        #expect(last.versions.map(\.text).contains("The good answer"), "versions now: \(last.versions.map(\.text))")
    }

    @Test func regenerateOnALocalHelpMessageKeepsTheRealAnswer() {
        let chat = ChatController.shared
        chat.newChat()
        let id = chat.active.id
        defer { chat.close(id) }
        chat.active.messages = [ChatMessage(role: .user, text: "q1"), ChatMessage(role: .assistant, text: "real answer")]
        chat.postLocalMessage("HELP TEXT")
        let help = chat.active.messages.last!
        chat.regenerate(help.id)
        chat.cancelStreaming()
        let texts = chat.active.messages.map(\.text)
        let vers = chat.active.messages.last!.versions.map(\.text)
        #expect(texts.contains("real answer"), "messages now: \(texts), versions: \(vers)")
    }
}

@MainActor
@Suite(.serialized)
struct QASnippetTests {
    @Test func snippetAfterSharpSIsAroundTheWord() {
        let text = "Größe Straße weiß heißen Fuß Maß Grüße " + String(repeating: "x", count: 60) + " needle " + String(repeating: "y", count: 60)
        let s = ChatSearch.snippet(text, around: "needle")
        #expect(s.contains("needle"), "snippet: \(s)")
    }
}

@MainActor
@Suite(.serialized)
struct QASnippetCrashTests {
    @Test func snippetDoesNotCrashOnManySharpS() {
        let text = String(repeating: "ß", count: 40) + " needle"
        let s = ChatSearch.snippet(text, around: "needle")
        #expect(s.contains("needle"))
    }
}

/// A server that accepts and never answers, so a package run hangs until cancelled.
final class HangingServer: @unchecked Sendable {
    let listener: NWListener
    var held: [NWConnection] = []
    let queue = DispatchQueue(label: "qa.hang")
    var port = 0
    init() async throws {
        let p = NWParameters.tcp
        p.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: p)
        listener.newConnectionHandler = { [weak self] c in self?.held.append(c); c.start(queue: self!.queue) }
        port = try await withCheckedThrowingContinuation { (k: CheckedContinuation<Int, Error>) in
            let once = OnceFlag()
            listener.stateUpdateHandler = { [listener] s in
                if case .ready = s, once.claim() { k.resume(returning: Int(listener.port?.rawValue ?? 0)) }
            }
            listener.start(queue: queue)
        }
    }
    var base: String { "http://127.0.0.1:\(port)" }
    func stop() { listener.cancel(); held.forEach { $0.cancel() } }
}

@MainActor
@Suite(.serialized)
struct QAPackageFlowTests {
    private func withStore(server: String, _ body: () async throws -> Void) async throws {
        let name = "lasso-qa-\(UUID().uuidString.prefix(6))"
        let root = FileManager.default.temporaryDirectory.appending(path: name, directoryHint: .isDirectory)
        let real = PackageStore.shared
        let store = PackageStore(root: root, defaults: UserDefaults(suiteName: name)!)
        PackageStore.shared = store
        defer { PackageStore.shared = real; real.reload(); try? FileManager.default.removeItem(at: root) }
        let package = try store.install(Data(PackageSurfaceTests.manifest.utf8), origin: .file)
        store.setValue(server, package.id, try #require(package.setting("server")))
        try await body()
    }

    @Test func regeneratingASlashReplyDoesNotLeakVersionsIntoTheNextReply() async throws {
        let server = try await RecordingServer()
        defer { server.stop() }
        server.answer(.init(body: Data(#"{"out": "hola mundo"}"#.utf8)))
        try await withStore(server: server.base) {
            let chat = ChatController.shared
            chat.newChat()
            let id = chat.active.id
            defer { chat.close(id) }
            chat.send(text: "/tr hello world")
            for _ in 0..<50 where chat.isStreaming || chat.messages.count < 2 { try await Task.sleep(for: .milliseconds(100)) }
            let reply = try #require(chat.messages.last)
            chat.regenerate(reply.id)
            try await Task.sleep(for: .milliseconds(100))
            for _ in 0..<50 where chat.isStreaming || chat.messages.count < 2 { try await Task.sleep(for: .milliseconds(100)) }
            let again = try #require(chat.messages.last)
            #expect(again.versions.count == 2, "regenerated slash reply versions: \(again.versions.map(\.text))")
            #expect(chat.active.carriedVersions.isEmpty, "carried left over: \(chat.active.carriedVersions.map(\.text))")
            chat.send(text: "an unrelated question")
            chat.cancelStreaming()
            let next = try #require(chat.messages.last)
            #expect(next.versions.isEmpty, "unrelated reply got versions: \(next.versions.map(\.text))")
        }
    }

    @Test func stoppingASlashCommandShowsStoppedNotAnError() async throws {
        let server = try await HangingServer()
        defer { server.stop() }
        try await withStore(server: server.base) {
            let chat = ChatController.shared
            chat.newChat()
            let id = chat.active.id
            defer { chat.close(id) }
            chat.send(text: "/tr hello world")
            try await Task.sleep(for: .milliseconds(400))
            #expect(chat.isStreaming)
            chat.cancelStreaming()
            // Send the next one right away (same main-actor turn as the Stop click is the extreme; next tick here).
            chat.send(text: "/tr second one")
            try await Task.sleep(for: .milliseconds(600))
            let first = chat.messages[1]
            #expect(!first.isError, "stopped reply shown as: \(first.text)")
            #expect(chat.messages.count == 4)
            #expect(chat.messages.last?.isStreaming == true)
            #expect(chat.isStreaming, "second command still running but composer flag cleared")
            chat.cancelStreaming()
        }
    }

    @Test func closingAChatWhileASlashCommandRunsDoesNotBringItBack() async throws {
        let server = try await HangingServer()
        defer { server.stop() }
        try await withStore(server: server.base) {
            let chat = ChatController.shared
            chat.newChat()
            let id = chat.active.id
            chat.send(text: "/tr hello world")
            try await Task.sleep(for: .milliseconds(400))
            chat.close(id)
            try await Task.sleep(for: .milliseconds(800))
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Lasso/conversations/\(id.uuidString).json")
            let exists = FileManager.default.fileExists(atPath: dir.path)
            ConversationStore.delete(id: id)
            #expect(!exists, "closed chat's file was rewritten: \(dir.path)")
        }
    }
}
