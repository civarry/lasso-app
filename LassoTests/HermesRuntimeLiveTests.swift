import Testing
import Foundation
@testable import Lasso

/// Lasso's own Hermes (`HermesRuntime`) on this Mac: set-up, start, a turn through the model route,
/// a model switch, and stop. Opt-in, because it creates the real `lasso` Hermes profile and runs a
/// model turn:
///
///     TEST_RUNNER_LASSO_HERMES_RUNTIME=1 xcodebuild test -scheme Lasso \
///         -only-testing:LassoTests/HermesRuntimeLiveTests
@MainActor
@Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: ProcessInfo.processInfo.environment["LASSO_HERMES_RUNTIME"] == "1"))
struct HermesRuntimeLiveTests {
    private let runtime = HermesRuntime.shared
    private let profile = HermesRuntime.profileDirectory

    private func file(_ name: String) throws -> String {
        try String(contentsOf: profile.appending(path: name), encoding: .utf8)
    }

    @Test func setUpMakesASafeProfile() async throws {
        try await runtime.setUp()
        let env = try file(".env"), config = try file("config.yaml")
        // No messaging credentials: a second gateway on the user's bot would take their messages.
        for prefix in ["TELEGRAM_", "DISCORD_", "SLACK_", "WHATSAPP_", "SIGNAL_"] {
            #expect(!env.contains("\n\(prefix)") && !env.hasPrefix(prefix), "\(prefix) left in .env")
        }
        #expect(env.contains("API_SERVER_KEY=\(HermesAgent.managedKey)"))
        #expect(env.contains("API_SERVER_HOST=127.0.0.1"))
        #expect(HermesRuntime.profileIsLassos)
        #expect(HermesAgent.approvalMode(inConfig: config) == .manual)
        let mode = try FileManager.default.attributesOfItem(atPath: profile.appending(path: ".env").path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test func startsTalksThroughTheRouteAndStops() async throws {
        let others = Self.otherGatewayPIDs()

        // Hermes's own model (what Apple Intelligence / MLX users get).
        let client = try await runtime.ready(route: nil)
        #expect(runtime.state == .running)
        let name = try await client.check()
        #expect(name == HermesRuntime.profileName)
        #expect(HermesAgent.gate(HermesAgent.approvalMode(profile: name, baseURL: client.baseURL),
                                 local: true, confirmed: false) == .allowed)
        try await expectAnswer(client, model: nil)

        // Switching Lasso's model rewrites the route and restarts the gateway, once.
        let route = HermesRoute(provider: "anthropic", model: "claude-haiku-4-5", baseURL: nil, apiKey: nil,
                                label: "Anthropic · claude-haiku-4-5")
        let started = Date()
        let routed = try await runtime.ready(route: route)
        print("[hermes-runtime] restart for a model switch: \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
        #expect(runtime.activeRoute == route)
        #expect(try file("config.yaml").contains("model: \"claude-haiku-4-5\""))
        try await expectAnswer(routed, model: "lasso")
        // Same route again: no restart.
        let again = Date()
        _ = try await runtime.ready(route: route)
        #expect(Date().timeIntervalSince(again) < 0.5)

        runtime.stop()
        #expect(runtime.state == .stopped)
        // stop() returns at once (no UI freeze); the gateway must be gone within its 3 s grace period.
        var gone = false
        for _ in 0..<20 where !gone {
            gone = (try? await routed.check()) == nil
            if !gone { try await Task.sleep(for: .milliseconds(200)) }
        }
        #expect(gone, "Lasso's gateway still answering 4 s after stop()")
        // The user's own gateways were left alone.
        #expect(Self.otherGatewayPIDs().isSuperset(of: others))
    }

    /// Stop while a start is under way (Agent turned off, local-only turned on): the start gives up and
    /// leaves nothing running, instead of launching the gateway afterwards.
    @Test func stopCancelsAStartInProgress() async throws {
        runtime.stop()
        let starting = Task { try await runtime.ready(route: nil) }
        try await Task.sleep(for: .milliseconds(50))
        runtime.stop()
        await #expect(throws: (any Error).self) { _ = try await starting.value }
        try await Task.sleep(for: .seconds(2))
        #expect(runtime.state != .running)
        #expect(HermesRuntime.recordedLassoGatewayRunning() == false)
    }

    private func expectAnswer(_ client: HermesClient, model: String?) async throws {
        let runID = try await client.start(.init(model: model, text: "Reply with exactly: lasso-ok. Use no tools.",
                                                 sessionID: "lasso-runtime-test-\(UUID().uuidString.prefix(6))",
                                                 instructions: HermesAgent.instructions))
        var turn = HermesTurn(runID: runID)
        for try await event in client.events(runID: runID) {
            turn.apply(event)
            if event.endsRun { break }
        }
        print("[hermes-runtime] model=\(model ?? "default") outcome=\(String(describing: turn.outcome)) text=\(turn.text.prefix(80))")
        #expect(turn.outcome == .completed)
        #expect(turn.text.contains("lasso-ok"))
    }

    /// PIDs of Hermes gateways that aren't Lasso's.
    private static func otherGatewayPIDs() -> Set<Int32> {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-axo", "pid=,command="]
        let pipe = Pipe()
        proc.standardOutput = pipe
        try? proc.run()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        proc.waitUntilExit()
        var pids: Set<Int32> = []
        for line in out.split(separator: "\n") where line.contains("hermes") && line.contains("gateway") {
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
            if let pid = Int32(parts.first ?? ""), !line.contains("--external-supervisor") { pids.insert(pid) }
        }
        return pids
    }
}
