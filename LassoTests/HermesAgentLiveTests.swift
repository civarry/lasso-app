import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import Lasso

/// The chat's Hermes path against a real Hermes gateway: the same `HermesClient` + `HermesTurn` the
/// chat uses. Opt-in, because it runs a real agent (and costs model tokens):
///
///     TEST_RUNNER_LASSO_HERMES=1 TEST_RUNNER_HERMES_URL=http://127.0.0.1:8742 \
///     TEST_RUNNER_HERMES_KEY_FILE=/path/to/key xcodebuild test -scheme Lasso \
///         -only-testing:LassoTests/HermesAgentLiveTests
///
/// Every command the agent is asked to run stays inside a fresh folder under /private/tmp.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["LASSO_HERMES"] == "1"))
struct HermesAgentLiveTests {
    private let client: HermesClient

    init() throws {
        let env = ProcessInfo.processInfo.environment
        let key = try String(contentsOfFile: try #require(env["HERMES_KEY_FILE"]), encoding: .utf8)
        client = try #require(HermesClient(baseURLString: env["HERMES_URL"] ?? HermesAgent.defaultBaseURL, apiKey: key))
    }

    private func sandbox() throws -> URL {
        let dir = URL(fileURLWithPath: "/private/tmp/lasso-hermes-live-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Runs one turn the way the chat does; `onApproval` answers any approval card.
    private func run(_ text: String, images: [String] = [], history: [(role: String, content: String)] = [],
                     onApproval: ((HermesApproval) async throws -> Void)? = nil) async throws -> (HermesTurn, Double) {
        let started = Date()
        let runID = try await client.start(.init(text: text, imageJPEGBase64s: images, history: history,
                                                 sessionID: "lasso-livetest-\(UUID().uuidString.prefix(8))",
                                                 instructions: HermesAgent.instructions))
        var turn = HermesTurn()
        for try await event in client.events(runID: runID) {
            turn.apply(event)
            if case .approvalRequested(let request) = event { try await onApproval?(request) }
            if event.endsRun { break }
        }
        if turn.outcome == nil { turn.streamEnded() }
        let seconds = Date().timeIntervalSince(started)
        print("[hermes-live] \(String(format: "%.1f", seconds))s steps=\(turn.steps.map(\.text)) text=\(turn.text.prefix(120))")
        return (turn, seconds)
    }

    @Test func checkFindsTheRunEndpoints() async throws {
        let model = try await client.check()
        #expect(!model.isEmpty)
    }

    /// The gate the chat applies before every turn, against the real profile serving these tests
    /// (which must have approvals.mode: manual for the approval tests below to mean anything).
    @Test func gateLetsThisManualProfileThrough() async throws {
        let profile = try await client.check()
        let mode = HermesAgent.approvalMode(profile: profile, baseURL: client.baseURL)
        #expect(mode == .manual, "profile \(profile) isn't set to manual approvals")
        #expect(HermesAgent.gate(mode, local: true, confirmed: false) == .allowed)
    }

    @Test func wrongKeyIsReportedAsSuch() async throws {
        let bad = try #require(HermesClient(baseURLString: client.baseURL.absoluteString, apiKey: "wrong-key"))
        await #expect(throws: HermesError.self) { _ = try await bad.check() }
        do { _ = try await bad.check() } catch { #expect(error.localizedDescription.contains("API key")) }
    }

    @Test func plainAnswer() async throws {
        let (turn, _) = try await run("Reply with exactly: lasso-ok. Use no tools.")
        #expect(turn.outcome == .completed)
        #expect(turn.text.contains("lasso-ok"))
    }

    @Test func toolCallsBecomeSteps() async throws {
        let dir = try sandbox()
        for name in ["alpha.txt", "beta.txt"] {
            try "x".write(to: dir.appending(path: name), atomically: true, encoding: .utf8)
        }
        let (turn, _) = try await run("Use a tool to list the files in \(dir.path), then reply with just their names.")
        #expect(turn.outcome == .completed)
        #expect(turn.text.contains("alpha.txt") && turn.text.contains("beta.txt"))
        let toolSteps = turn.steps.filter { !$0.text.hasPrefix("Answering") }
        #expect(!toolSteps.isEmpty)
        let allDone = turn.steps.allSatisfy { $0.done }
        #expect(allDone)
    }

    private func deletionPrompt(_ target: URL) -> String {
        "Run exactly this terminal command and nothing else: rm -r \(target.path) . "
            + "If it is blocked or denied, do not try any alternative; just say what happened in one sentence."
    }

    @Test func allowedCommandRuns() async throws {
        let dir = try sandbox()
        let target = dir.appending(path: "junk")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        var asked = false
        let (turn, _) = try await run(deletionPrompt(target)) { request in
            asked = true
            #expect(request.command?.contains("rm -r") == true)
            try await client.respond(runID: request.runID, requestID: request.requestID, choice: "once")
        }
        #expect(asked, "Hermes ran rm -r without asking")
        #expect(turn.outcome == .completed)
        #expect(turn.steps.contains { $0.text == "You allowed the command" })
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    @Test func deniedCommandDoesNotRun() async throws {
        let dir = try sandbox()
        let target = dir.appending(path: "junk")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        var asked = false
        let (turn, _) = try await run(deletionPrompt(target)) { request in
            asked = true
            try await client.respond(runID: request.runID, requestID: request.requestID, choice: "deny")
        }
        #expect(asked)
        #expect(turn.steps.contains { $0.text == "You denied the command" })
        #expect(FileManager.default.fileExists(atPath: target.path), "a denied rm -r deleted the folder")
    }

    /// Stop in the chat cancels the task reading the stream; that must stop the command on the server,
    /// not just close the connection (a disconnect alone leaves the tool running).
    @Test func stopKillsARunningCommand() async throws {
        let dir = try sandbox()
        let marker = dir.appending(path: "marker")
        let runID = try await client.start(.init(
            text: "Run this single terminal command in the foreground and wait for it: sleep 20 && touch \(marker.path) . Then say done.",
            sessionID: "lasso-livetest-stop", instructions: HermesAgent.instructions))
        let reader = Task {
            for try await event in client.events(runID: runID) {
                if case .toolStarted = event { return true }
                if event.endsRun { return false }
            }
            return false
        }
        #expect(try await reader.value, "the command never started")
        // The chat's Stop: cancel the consumer of a fresh stream.
        let consumer = Task { for try await _ in client.events(runID: runID) {} }
        try await Task.sleep(for: .seconds(1))
        let stoppedAt = Date()
        consumer.cancel()
        var status = ""
        for _ in 0..<20 {
            status = try await runStatus(runID)
            if status == "cancelled" { break }
            try await Task.sleep(for: .milliseconds(250))
        }
        print("[hermes-live] stop → \(status) in \(String(format: "%.2f", Date().timeIntervalSince(stoppedAt)))s")
        #expect(status == "cancelled")
        try await Task.sleep(for: .seconds(22))
        #expect(!FileManager.default.fileExists(atPath: marker.path), "the command kept running after Stop")
    }

    @Test func seesAnAttachedImage() async throws {
        let (turn, _) = try await run("What single colour fills this image? Answer with one word. Use no tools.",
                                      images: [try solidJPEG(red: 1, green: 0, blue: 0)])
        #expect(turn.outcome == .completed)
        #expect(turn.text.lowercased().contains("red"))
    }

    @Test func usesTheChatHistoryLassoSends() async throws {
        let (turn, _) = try await run("What is my codeword? Answer with the word only. Use no tools.",
                                      history: [("user", "My codeword is walrus."), ("assistant", "Noted.")])
        #expect(turn.text.lowercased().contains("walrus"))
    }

    // MARK: Helpers

    private func runStatus(_ runID: String) async throws -> String {
        var req = URLRequest(url: client.baseURL.appending(path: "v1/runs/\(runID)"))
        req.setValue("Bearer \(client.apiKey)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: req)
        let o = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return o?["status"] as? String ?? ""
    }

    private func solidJPEG(red: CGFloat, green: CGFloat, blue: CGFloat) throws -> String {
        let ctx = try #require(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(red: red, green: green, blue: blue, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let image = try #require(ctx.makeImage())
        return try #require(ImageEncoder.jpegBase64(image))
    }
}
