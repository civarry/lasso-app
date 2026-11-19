import Testing
import Foundation
@testable import Lasso

/// Hermes Agent in chat: decoding the `/v1/runs` event stream and folding it into a chat turn.
/// The event lines are real ones recorded from Hermes 0.21's API server (paths shortened).
struct HermesAgentTests {

    private let delta = #"data: {"event": "message.delta", "run_id": "run_7ee7", "timestamp": 1795051448.10, "delta": "(1)"}"#
    private let reasoning = #"data: {"event": "reasoning.available", "run_id": "run_7ee7", "timestamp": 1795051448.96, "text": "(1) blue"}"#
    private let completed = #"data: {"event": "run.completed", "run_id": "run_7ee7", "timestamp": 1795051448.97, "output": "(1) blue (2) hello", "usage": {"input_tokens": 21492, "output_tokens": 123, "total_tokens": 21615}}"#
    private let toolStarted = #"data: {"event": "tool.started", "run_id": "run_f384", "timestamp": 1795050947.67, "tool": "terminal", "preview": "rm -r /tmp/lasso-test/junkdir"}"#
    private let approval = #"data: {"command": "rm -r /tmp/lasso-test/junkdir", "pattern_key": "delete in root path", "pattern_keys": ["delete in root path"], "description": "delete in root path", "allow_permanent": true, "allow_session": true, "request_id": "1423ff30", "event": "approval.request", "run_id": "run_f384", "timestamp": 1795050947.81, "choices": ["once", "session", "always", "deny"]}"#
    private let responded = #"data: {"event": "approval.responded", "run_id": "run_f384", "timestamp": 1795051143.58, "choice": "once", "request_id": "1423ff30", "resolved": 1}"#
    private let toolCompleted = #"data: {"event": "tool.completed", "run_id": "run_f384", "timestamp": 1795051143.60, "tool": "terminal", "duration": 195.933, "error": false}"#
    private let cancelled = #"data: {"event": "run.cancelled", "run_id": "run_a405", "timestamp": 1795051387.08}"#

    private func events(_ lines: [String]) -> [HermesEvent] { lines.compactMap(HermesEvent.parse(sseLine:)) }

    // MARK: Decoding

    @Test func decodesEveryRecordedEvent() throws {
        #expect(HermesEvent.parse(sseLine: delta) == .delta("(1)"))
        #expect(HermesEvent.parse(sseLine: reasoning) == .other("reasoning.available"))
        #expect(HermesEvent.parse(sseLine: completed) == .completed(output: "(1) blue (2) hello", inputTokens: 21492, outputTokens: 123))
        #expect(HermesEvent.parse(sseLine: toolStarted) == .toolStarted(tool: "terminal", preview: "rm -r /tmp/lasso-test/junkdir"))
        #expect(HermesEvent.parse(sseLine: toolCompleted) == .toolCompleted(tool: "terminal", duration: 195.933, failed: false))
        #expect(HermesEvent.parse(sseLine: responded) == .approvalResolved(requestID: "1423ff30", choice: "once"))
        #expect(HermesEvent.parse(sseLine: cancelled) == .cancelled)

        guard case .approvalRequested(let request) = try #require(HermesEvent.parse(sseLine: approval)) else {
            Issue.record("not an approval"); return
        }
        #expect(request.runID == "run_f384")
        #expect(request.requestID == "1423ff30")
        #expect(request.command == "rm -r /tmp/lasso-test/junkdir")
        #expect(request.reason == "delete in root path")
        // "Always" is never offered from the chat.
        #expect(request.offered == ["once", "session", "deny"])
    }

    @Test func ignoresNonEventLines() {
        #expect(HermesEvent.parse(sseLine: "") == nil)
        #expect(HermesEvent.parse(sseLine: ": keep-alive") == nil)
        #expect(HermesEvent.parse(sseLine: "event: message") == nil)
        #expect(HermesEvent.parse(sseLine: "data: not json") == nil)
        #expect(HermesEvent.parse(sseLine: #"data: {"no_event": 1}"#) == nil)
    }

    @Test func failedRunKeepsItsMessage() {
        let line = #"data: {"event": "run.failed", "run_id": "r", "timestamp": 1, "error": "Provider authentication failed"}"#
        #expect(HermesEvent.parse(sseLine: line) == .failed("Provider authentication failed"))
    }

    // MARK: Folding a run into the chat

    @Test func plainAnswerStreamsThenSettlesOnTheFinalText() {
        var turn = HermesTurn()
        for e in events([delta, reasoning]) { turn.apply(e) }
        #expect(turn.text == "(1)")
        #expect(turn.steps.map(\.text) == ["Answering · Hermes Agent"])
        #expect(turn.outcome == nil)
        for e in events([completed]) { turn.apply(e) }
        #expect(turn.text == "(1) blue (2) hello")
        #expect(turn.outcome == .completed)
        #expect(turn.inputTokens == 21492)
        #expect(turn.steps.allSatisfy { $0.done })
    }

    @Test func approvalShowsCardThenRecordsTheAnswer() {
        var turn = HermesTurn()
        for e in events([toolStarted, approval]) { turn.apply(e) }
        #expect(turn.approval?.requestID == "1423ff30")
        #expect(turn.steps.map(\.text) == ["Ran a command · rm -r /tmp/lasso-test/junkdir", "Waiting for your approval"])
        #expect(turn.steps.map(\.done) == [false, false])

        for e in events([responded, toolCompleted]) { turn.apply(e) }
        #expect(turn.approval == nil)
        #expect(turn.steps.map(\.text) == ["Ran a command · rm -r /tmp/lasso-test/junkdir · 196s", "You allowed the command"])
        #expect(turn.steps.allSatisfy { $0.done })
    }

    @Test func deniedApprovalSaysSo() {
        var turn = HermesTurn()
        turn.apply(.approvalRequested(HermesApproval(runID: "r", requestID: "q", command: "rm -r x", reason: nil, choices: [])))
        turn.apply(.approvalResolved(requestID: "q", choice: "deny"))
        #expect(turn.steps.last?.text == "You denied the command")
    }

    @Test func narrationBeforeAToolIsReplacedByTheFinalAnswer() {
        var turn = HermesTurn()
        turn.apply(.delta("Let me look."))
        turn.apply(.toolStarted(tool: "search_files", preview: "*.md"))
        turn.apply(.toolCompleted(tool: "search_files", duration: 0.2, failed: false))
        turn.apply(.delta("There are 3 files."))
        turn.apply(.completed(output: "There are 3 files.", inputTokens: nil, outputTokens: nil))
        #expect(turn.text == "There are 3 files.")
        #expect(turn.steps.map(\.text) == ["Answering · Hermes Agent", "Searched files · *.md", "Answering · Hermes Agent"])
    }

    @Test func failedToolIsMarked() {
        var turn = HermesTurn()
        turn.apply(.toolStarted(tool: "web_search", preview: nil))
        turn.apply(.toolCompleted(tool: "web_search", duration: 0.4, failed: true))
        #expect(turn.steps.first?.text == "Searched the web (failed)")
        #expect(turn.steps.first?.icon == "globe")
    }

    /// Hermes doesn't always report a tool as finished (seen with file writes): the end of the run
    /// closes whatever is open, so no spinner is left running.
    @Test func endOfRunClosesOpenSteps() {
        var turn = HermesTurn()
        turn.apply(.toolStarted(tool: "write_file", preview: "notes.md"))
        turn.apply(.approvalRequested(HermesApproval(runID: "r", requestID: "q", command: "x", reason: nil, choices: [])))
        turn.apply(.cancelled)
        #expect(turn.outcome == .cancelled)
        #expect(turn.approval == nil)
        #expect(turn.steps.allSatisfy { $0.done })
    }

    @Test func droppedConnectionIsAFailureNotASilentFinish() {
        var turn = HermesTurn()
        turn.apply(.delta("half an ans"))
        turn.streamEnded()
        guard case .failed = turn.outcome else { Issue.record("expected failure"); return }
        #expect(turn.text == "half an ans")
    }

    // MARK: History and configuration

    @MainActor
    @Test func historyKeepsNewestAndSkipsFailures() {
        var user1 = ChatMessage(role: .user, text: "first")
        user1.promptText = "Context: screen text\n\nfirst"
        let error = { () -> ChatMessage in var m = ChatMessage(role: .assistant, text: "HTTP 500"); m.isError = true; return m }()
        let messages = [user1, error,
                        ChatMessage(role: .user, text: "second"),
                        ChatMessage(role: .assistant, text: "<think>hm</think>answer two"),
                        ChatMessage(role: .assistant, text: "(Stopped.)")]
        let history = ChatController.hermesHistory(from: messages[...])
        #expect(history.map(\.role) == ["user", "user", "assistant"])
        #expect(history.map(\.content) == ["Context: screen text\n\nfirst", "second", "answer two"])

        let capped = ChatController.hermesHistory(from: messages[...], maxMessages: 2)
        #expect(capped.map(\.content) == ["second", "answer two"])
    }

    // MARK: Lasso's own Hermes profile

    @Test func envKeepsProviderKeysAndDropsMessaging() {
        let env = "ANTHROPIC_API_KEY=sk-a\nTELEGRAM_BOT_TOKEN=123:abc\nexport DISCORD_TOKEN=x\nOPENROUTER_API_KEY=or\nAPI_SERVER_KEY=old\nHERMES_YOLO_MODE=1\n\n"
        let out = HermesProfileFiles.filteredEnv(env + "NEWCHAT_BOT_TOKEN=b\nFOO_WEBHOOK_URL=w\n", apiKey: "lasso-k", port: 8655)
        #expect(out == "ANTHROPIC_API_KEY=sk-a\nOPENROUTER_API_KEY=or\nAPI_SERVER_KEY=lasso-k\nAPI_SERVER_HOST=127.0.0.1\nAPI_SERVER_PORT=8655\n")
    }

    @Test func managedBlockIsRewrittenNotStacked() {
        let user = "model:\n  default: claude-opus-4-8\napprovals:\n  mode: smart\n"
        let route = HermesRoute(provider: "custom", model: "qwen3:30b", baseURL: "http://127.0.0.1:11434/v1",
                                apiKey: "ollama", label: "Ollama")
        let once = HermesProfileFiles.withManagedBlock(user, port: 8653, route: route)
        let twice = HermesProfileFiles.withManagedBlock(once, port: 8653, route: route)
        #expect(once == twice)
        #expect(once.hasPrefix(user))
        #expect(once.components(separatedBy: HermesProfileFiles.beginMarker).count == 2)
        // The appended block wins over the user's earlier `smart`, as it does in PyYAML.
        #expect(HermesAgent.approvalMode(inConfig: once) == .manual)
        #expect(once.contains("      port: 8653"))
        #expect(once.contains("          base_url: \"http://127.0.0.1:11434/v1\""))
        #expect(once.contains("  telegram:\n    enabled: false"))
        // A model switch replaces the route; no route leaves Hermes's own model.
        // The user's opt-out turns Lasso's own profile to Hermes's smart mode (the gate then warns).
        let smart = HermesProfileFiles.withManagedBlock(once, port: 8653, route: route, letHermesDecide: true)
        #expect(HermesAgent.approvalMode(inConfig: smart) == .other("smart"))
        let none = HermesProfileFiles.withManagedBlock(once, port: 8653, route: nil)
        #expect(!none.contains("model_routes"))
        #expect(none.hasPrefix(user))
    }

    /// Hermes's side tasks (titles, history summaries) follow the top-level `model:`, not the request's
    /// route, so the block sets that too: the user's own model (here a cloud Opus) must not survive.
    @Test func managedBlockReplacesTheMainModel() {
        let user = "model:\n  provider: anthropic\n  default: claude-opus-4-8\n"
        let route = HermesRoute(provider: "custom", model: "Qwen3.5-9B", baseURL: "http://127.0.0.1:60801/v1",
                                apiKey: "tok", label: "MLX")
        let block = HermesProfileFiles.withManagedBlock(user, port: 8653, route: route)
            .components(separatedBy: HermesProfileFiles.beginMarker)[1]
        #expect(block.hasPrefix("\nmodel:\n  provider: \"custom\"\n  default: \"Qwen3.5-9B\"\n  base_url: \"http://127.0.0.1:60801/v1\"\n  api_key: \"tok\"\n"))
        // No route (the Agent then doesn't run): Lasso writes no model rather than invent one.
        let none = HermesProfileFiles.withManagedBlock(user, port: 8653, route: nil)
            .components(separatedBy: HermesProfileFiles.beginMarker)[1]
        #expect(!none.contains("model:"))
    }

    @Test func routeValuesAreQuotedSafely() {
        #expect(HermesProfileFiles.quoted("a\"b: c # d") == #""a\"b: c # d""#)
        #expect(HermesProfileFiles.quoted("https://x.example/v1") == #""https://x.example/v1""#)
        let key = HermesProfileFiles.newKey()
        #expect(key.hasPrefix("lasso-") && key.count == 54)
    }

    @Test func routeEqualityIgnoresTheLabel() {
        let a = HermesRoute(provider: "anthropic", model: "m", baseURL: nil, apiKey: "k", label: "Anthropic · m")
        var b = a
        b.label = "Claude"
        #expect(a == b)
        b.apiKey = "other"
        #expect(a != b)
    }

    /// Lasso's gateway gets only what Hermes needs, so an inherited API_SERVER_HOST=0.0.0.0 (Lasso run
    /// from a shell) can't expose it beyond loopback.
    @Test func gatewayEnvironmentIsMinimal() {
        let env = HermesRuntime.childEnvironment(home: URL(fileURLWithPath: "/tmp/h"))
        #expect(env["HERMES_HOME"] == "/tmp/h")
        #expect(env.keys.allSatisfy { ["HOME", "USER", "LOGNAME", "LANG", "LC_ALL", "TMPDIR", "SHELL", "PATH", "HERMES_HOME"].contains($0) })
    }

    @Test func privateFilesAreOwnerOnlyAndNeverFollowLinks() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "hermes-write-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appending(path: ".env")
        try HermesRuntime.writePrivate("A=1\n", to: file)
        try HermesRuntime.writePrivate("A=2\n", to: file)
        #expect(try String(contentsOf: file, encoding: .utf8) == "A=2\n")
        #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int) == 0o600)
        let link = dir.appending(path: "config.yaml")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(throws: (any Error).self) { try HermesRuntime.writePrivate("x", to: link) }
        #expect(try String(contentsOf: file, encoding: .utf8) == "A=2\n")
    }

    /// With Agent off, the regular model must not see its "own" past replies claiming actions: the
    /// Agent's reply moves into a note on the user's turn, and the assistant turn declines to act.
    @MainActor
    @Test func agentRepliesBecomeNotesInRegularHistory() {
        var agent = ChatMessage(role: .assistant, text: "Opened Chrome for you.")
        agent.viaAgent = true
        let messages = [ChatMessage(role: .user, text: "open chrome"), agent,
                        ChatMessage(role: .user, text: "thanks"), ChatMessage(role: .assistant, text: "Anytime.")]
        let turns = ChatController.historyTurns(from: messages[...])
        #expect(turns.map(\.role) == [.user, .assistant, .user, .assistant])
        #expect(turns[0].text.hasPrefix("open chrome"))
        #expect(turns[0].text.contains("Opened Chrome for you."))
        #expect(turns[1].text == ChatController.agentTurnStandIn)
        #expect(!turns[1].text.lowercased().contains("opened"))
        #expect(turns[3].text == "Anytime.")
    }

    @Test func clientNormalizesTheAddress() {
        #expect(HermesClient(baseURLString: "http://127.0.0.1:8642/v1/", apiKey: "k")?.baseURL.absoluteString == "http://127.0.0.1:8642")
        #expect(HermesClient(baseURLString: " http://localhost:8642 ", apiKey: " k ")?.apiKey == "k")
        #expect(HermesClient(baseURLString: "http://127.0.0.1:8642", apiKey: "") == nil)
        #expect(HermesClient(baseURLString: "localhost:8642", apiKey: "k") == nil)
        #expect(HermesClient(baseURLString: "ftp://host", apiKey: "k") == nil)
    }

    /// Only `manual` makes Hermes ask Lasso; anything else, including no setting (Hermes's `smart`
    /// default), gets the warning.
    @Test func readsTheApprovalMode() {
        #expect(HermesAgent.approvalMode(inConfig: "model:\n  default: x\napprovals:\n  mode: manual\n") == .manual)
        #expect(HermesAgent.approvalMode(inConfig: "approvals:\n  timeout: 300\n  mode: \"smart\"  # default\n") == .other("smart"))
        #expect(HermesAgent.approvalMode(inConfig: "model:\n  default: x\n") == .other("smart"))
        // A `mode:` under another section is not the approval mode.
        #expect(HermesAgent.approvalMode(inConfig: "display:\n  mode: manual\napprovals:\n  timeout: 60\n") == .other("smart"))
        // Only the direct child counts, and the last one wins.
        #expect(HermesAgent.approvalMode(inConfig: "approvals:\n  overrides:\n    x:\n      mode: manual\n  mode: smart\n") == .other("smart"))
        #expect(HermesAgent.approvalMode(inConfig: "approvals:\n  mode: manual\napprovals:\n  mode: off\n") == .other("off"))
        // A later `approvals:` block without a mode replaces the manual one: Hermes falls back to smart.
        #expect(HermesAgent.approvalMode(inConfig: "approvals:\n  mode: manual\nmodel:\n  default: x\napprovals:\n  timeout: 60\n") == .other("smart"))
        #expect(HermesAgent.approvalMode(inConfig: "approvals:\n  mode:manual\n") == .other("smart"))
        // YAML booleans, case, CRLF, and comments read the way Hermes reads them.
        #expect(HermesAgent.approvalMode(inConfig: "approvals:\r\n  mode: Manual\r\n") == .manual)
        #expect(HermesAgent.approvalMode(inConfig: "approvals:\n  mode: off\n") == .other("off"))
        #expect(HermesAgent.approvalMode(inConfig: "approvals:\n  mode: smart # manual later\n") == .other("smart"))
        // Something Lasso can't read with certainty is never taken as manual.
        #expect(HermesAgent.approvalMode(inConfig: "approvals: {mode: manual}\n") != .manual)
        #expect(HermesAgent.approvalMode(inConfig: "approvals:\n  mode: auto\n") == .other("auto"))
    }

    /// Lasso sends nothing to a Hermes that would run risky commands unasked. A config it can't read
    /// (Hermes on another machine) needs the user's confirmation; a readable non-manual one can't be
    /// confirmed away.
    @Test func gateRefusesUnlessApprovalsAreManual() {
        #expect(HermesAgent.gate(.manual, local: true, confirmed: false) == .allowed)
        #expect(HermesAgent.gate(.unknown, local: false, confirmed: true) == .allowed)
        guard case .blocked(let smart) = HermesAgent.gate(.other("smart"), local: false, confirmed: true) else {
            Issue.record("smart mode was allowed"); return
        }
        #expect(smart.contains("mode: manual"))
        guard case .blocked = HermesAgent.gate(.unknown, local: false, confirmed: false) else {
            Issue.record("unverified Hermes was allowed"); return
        }
        // The explicit opt-out lets any mode through, flagged so every reply carries the warning; it
        // changes nothing for a manual Hermes.
        #expect(HermesAgent.gate(.other("smart"), local: true, confirmed: false, letHermesDecide: true) == .unattended)
        #expect(HermesAgent.gate(.other("off"), local: true, confirmed: false, letHermesDecide: true) == .unattended)
        #expect(HermesAgent.gate(.unknown, local: true, confirmed: false, letHermesDecide: true) == .unattended)
        #expect(HermesAgent.gate(.manual, local: true, confirmed: false, letHermesDecide: true) == .allowed)
        // On this Mac the config should be readable: not finding it is never confirmed away.
        guard case .blocked = HermesAgent.gate(.unknown, local: true, confirmed: true) else {
            Issue.record("a local Hermes with no readable config was allowed"); return
        }
    }

    @Test func approvalModeIsOnlyReadForAGatewayOnThisMac() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "hermes-home-\(UUID().uuidString)")
        let profile = home.appending(path: ".hermes/profiles/lab")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        try "approvals:\n  mode: manual\n".write(to: profile.appending(path: "config.yaml"), atomically: true, encoding: .utf8)
        let local = try #require(URL(string: "http://127.0.0.1:8642"))
        let remote = try #require(URL(string: "https://agent.example.com"))
        #expect(HermesAgent.approvalMode(profile: "lab", baseURL: local, home: home) == .manual)
        #expect(HermesAgent.approvalMode(profile: "lab", baseURL: remote, home: home) == .unknown)
        #expect(HermesAgent.approvalMode(profile: "hermes-agent", baseURL: local, home: home) == .unknown)
    }

    /// Same conversation and first message → same Hermes session; a cleared or rewritten first turn →
    /// a new one, so Hermes can't bring the old thread back.
    @Test func sessionIDFollowsTheThread() {
        let conversation = UUID(), first = UUID()
        let id = HermesAgent.sessionID(conversation: conversation, firstMessage: first)
        #expect(id == HermesAgent.sessionID(conversation: conversation, firstMessage: first))
        #expect(id.hasPrefix("lasso-"))
        #expect(id != HermesAgent.sessionID(conversation: conversation, firstMessage: UUID()))
    }

    // MARK: Review fixes

    @Test func secondApprovalWaitsItsTurnAndEachAnswerClosesItsOwnStep() {
        var turn = HermesTurn(runID: "run_1")
        turn.apply(.approvalRequested(HermesApproval(runID: "run_1", requestID: "a", command: "rm -r x", reason: nil, choices: [])))
        turn.apply(.approvalRequested(HermesApproval(runID: "run_1", requestID: "b", command: "rm -r y", reason: nil, choices: [])))
        #expect(turn.approval?.requestID == "a")
        turn.apply(.approvalResolved(requestID: "b", choice: "deny"))
        #expect(turn.approval?.requestID == "a")
        #expect(turn.steps.map(\.text) == ["Waiting for your approval", "You denied the command"])
        turn.apply(.approvalResolved(requestID: "a", choice: "once"))
        #expect(turn.approval == nil)
        #expect(turn.steps.map(\.text) == ["You allowed the command", "You denied the command"])
    }

    @Test func approvalWithoutARunIDGetsTheRunsID() {
        var turn = HermesTurn(runID: "run_9")
        turn.apply(.approvalRequested(HermesApproval(runID: "", requestID: nil, command: "rm -r x", reason: nil, choices: [])))
        #expect(turn.approval?.runID == "run_9")
        // No request id: still a distinct, stable key, and the card still has buttons.
        #expect(turn.approval?.key.contains("rm -r x") == true)
        #expect(turn.approval?.offered == ["once", "deny"])
    }

    @Test func toolStepsCloseByToolNotByLabel() {
        var turn = HermesTurn()
        turn.apply(.toolStarted(tool: "foo", preview: nil))
        turn.apply(.toolStarted(tool: "foobar", preview: nil))
        turn.apply(.toolCompleted(tool: "foobar", duration: nil, failed: false))
        #expect(turn.steps.map(\.done) == [false, true])
    }

    @Test func narrationPiecesStaySeparate() {
        var turn = HermesTurn()
        turn.apply(.delta("Checking."))
        turn.apply(.toolStarted(tool: "web_search", preview: nil))
        turn.apply(.delta("Found it."))
        turn.apply(.failed("boom"))
        #expect(turn.text == "Checking.\n\nFound it.")
    }

    @Test func eventsAfterTheEndAreIgnored() {
        var turn = HermesTurn()
        turn.apply(.cancelled)
        turn.apply(.approvalRequested(HermesApproval(runID: "r", requestID: "q", command: nil, reason: nil, choices: [])))
        #expect(turn.approval == nil)
    }
}
