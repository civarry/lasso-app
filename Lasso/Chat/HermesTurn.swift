import Foundation

/// What a Hermes run has shown so far, folded from its events: the answer text, one activity step per
/// tool call, and the approvals waiting on the user. Pure, so the chat's handling of a run is testable
/// without a server.
struct HermesTurn {
    enum Outcome: Equatable {
        case completed
        case failed(String)
        case cancelled
    }

    private(set) var text = ""
    private(set) var steps: [ActivityStep] = []
    /// Requests still waiting, oldest first. The chat shows the first one.
    private(set) var pendingApprovals: [HermesApproval] = []
    private(set) var outcome: Outcome?
    private(set) var inputTokens: Int?
    private(set) var outputTokens: Int?
    /// The run these events belong to; fills in an approval that arrives without one.
    let runID: String
    /// The answering step, added when answer text arrives (so the trace reads tools → answer).
    private var answerStepID: UUID?
    /// Open tool steps, oldest first, with the tool each one is for.
    private var openTools: [(tool: String, stepID: UUID)] = []
    /// Each waiting approval's step, by `HermesApproval.key`.
    private var approvalSteps: [String: UUID] = [:]

    /// Names the model in the answer step ("Answering · Claude Sonnet").
    let answerLabel: String

    init(runID: String = "", answerLabel: String = "Hermes Agent", steps: [ActivityStep] = []) {
        self.runID = runID
        self.answerLabel = answerLabel
        self.steps = steps
    }

    var approval: HermesApproval? { pendingApprovals.first }

    mutating func apply(_ event: HermesEvent) {
        guard outcome == nil else { return }
        switch event {
        case .delta(let piece):
            guard !piece.isEmpty else { return }
            // No "Answering · model" step: the header already says who answers, and the step gave
            // every reply an Activity disclosure. The trace is for work: tools and approvals.
            text += piece

        case .toolStarted(let tool, let preview):
            // Text streamed before a tool call is the agent narrating ("Let me check…"). The final
            // answer replaces it on completion; until then, keep the pieces apart.
            closeAnswerStep()
            if !text.isEmpty, !text.hasSuffix("\n") { text += "\n\n" }
            var label = Self.label(for: tool)
            if let preview { label += " · \(Self.shorten(preview))" }
            let step = ActivityStep(icon: Self.icon(for: tool), text: label)
            steps.append(step)
            openTools.append((tool, step.id))

        case .toolCompleted(let tool, let duration, let failed):
            // Calls of the same tool finish in the order they started.
            guard let open = openTools.firstIndex(where: { $0.tool == tool }) else { return }
            let stepID = openTools.remove(at: open).stepID
            guard let i = steps.firstIndex(where: { $0.id == stepID }) else { return }
            steps[i].done = true
            if failed { steps[i].text += " (failed)" }
            else if let duration, duration >= 1 { steps[i].text += String(format: " · %.0fs", duration) }

        case .approvalRequested(var request):
            if request.runID.isEmpty { request = request.withRunID(runID) }
            guard !pendingApprovals.contains(where: { $0.key == request.key }) else { return }
            pendingApprovals.append(request)
            let step = ActivityStep(icon: "hand.raised", text: "Waiting for your approval")
            steps.append(step)
            approvalSteps[request.key] = step.id

        case .approvalResolved(let requestID, let choice):
            // Match the answered request; without an id, the oldest one.
            let index = requestID.flatMap { id in pendingApprovals.firstIndex { $0.requestID == id } }
                ?? (pendingApprovals.isEmpty ? nil : 0)
            guard let index else { return }
            let resolved = pendingApprovals.remove(at: index)
            if let stepID = approvalSteps.removeValue(forKey: resolved.key),
               let i = steps.firstIndex(where: { $0.id == stepID }) {
                steps[i].done = true
                steps[i].text = choice == "deny" ? "You denied the command" : "You allowed the command"
            }

        case .completed(let output, let input, let outputCount):
            // The final answer, without the narration that came before tool calls.
            if !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { text = output }
            inputTokens = input
            outputTokens = outputCount
            finish(.completed)

        case .failed(let message):
            finish(.failed(message))

        case .cancelled:
            finish(.cancelled)

        case .other:
            break
        }
    }

    /// The stream ended without an end event (connection dropped).
    mutating func streamEnded() {
        if outcome == nil { finish(.failed("The connection to Hermes closed before the turn finished.")) }
    }

    private mutating func closeAnswerStep() {
        if let id = answerStepID, let i = steps.firstIndex(where: { $0.id == id }) { steps[i].done = true }
        answerStepID = nil
    }

    /// Every step is closed when a run ends: Hermes doesn't always report a tool as finished.
    private mutating func finish(_ result: Outcome) {
        outcome = result
        pendingApprovals = []
        openTools = []
        approvalSteps = [:]
        for i in steps.indices where !steps[i].done { steps[i].done = true }
    }

    // MARK: - Labels

    /// Lasso's own tools (`LassoAgentTools`, through its Hermes plugin).
    static func lassoTool(_ tool: String) -> String? {
        [LassoAgentTools.lookAtScreen, LassoAgentTools.lookAtImage].contains(tool) ? tool : nil
    }

    static func label(for tool: String) -> String {
        switch lassoTool(tool) {
        case "look_at_screen": return "Looked at your screen"
        case "look_at_image": return "Looked at an image"
        default: break
        }
        return switch tool {
        case "terminal", "process": "Ran a command"
        case "web_search": "Searched the web"
        case "web_extract": "Read a page"
        case "read_file": "Read a file"
        case "search_files": "Searched files"
        case "write_file", "patch": "Edited a file"
        case "vision_analyze": "Looked at an image"
        case "memory": "Used memory"
        case "todo": "Planned"
        case "execute_code": "Ran code"
        case "delegate_task": "Asked a helper agent"
        case "skill_view", "skills_list", "skill_manage": "Used a skill"
        case "session_search": "Searched past chats"
        default:
            tool.hasPrefix("browser") ? "Used the browser" : "Used \(tool.replacingOccurrences(of: "_", with: " "))"
        }
    }

    static func icon(for tool: String) -> String {
        if lassoTool(tool) != nil { return "eye" }
        return switch tool {
        case "terminal", "process", "execute_code": "terminal"
        case "web_search", "web_extract": "globe"
        case "read_file", "search_files", "session_search": "doc.text.magnifyingglass"
        case "write_file", "patch": "square.and.pencil"
        case "vision_analyze": "eye"
        case "memory": "brain"
        case "todo": "checklist"
        default: tool.hasPrefix("browser") ? "safari" : "wrench.and.screwdriver"
        }
    }

    static func shorten(_ text: String, limit: Int = 80) -> String {
        let oneLine = text.replacingOccurrences(of: "\n", with: " ")
        return oneLine.count <= limit ? oneLine : String(oneLine.prefix(limit - 1)) + "…"
    }
}
