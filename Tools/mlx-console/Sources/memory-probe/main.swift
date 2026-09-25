import Foundation
import HuggingFace
import MLXLLM
import MLXLMCommon
import MLXVLM
import MLXHuggingFace
import Tokenizers

// Automated version of the manual "does it fabricate a decision" test: drives the REAL Lasso memory
// pipeline (LassoMemoryCore.swift, synced from Chat/ChatContextBuilder.swift + Chat/ChatController.swift)
// against the real local model, turn by turn — building context with ChatContextBuilder, folding new
// exchanges into ConversationMemory with the actual summarizationPrompt/parseMemory, then asking recall
// questions and checking whether DECISIONS correctly separates "suggested" from "decided".

func eprint(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

/// Mirrors AnthropicProvider.streamMessage (Lasso/Intelligence/AnthropicProvider.swift), minus tool
/// calling — same endpoint, same SSE parsing, same request shape, so a probe run against Claude is
/// exercising the same wire format the app actually uses, not a reimplementation guess.
func anthropicSend(system: String, messages: [[String: Any]], apiKey: String, model: String) async throws -> String {
    let body: [String: Any] = [
        "model": model, "max_tokens": 1024, "stream": true, "system": system, "messages": messages,
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: body) else {
        throw NSError(domain: "memory-probe", code: 1, userInfo: [NSLocalizedDescriptionKey: "encode failed"])
    }
    var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    request.httpBody = data

    let (bytes, response) = try await URLSession.shared.bytes(for: request)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        throw NSError(domain: "memory-probe", code: code,
                      userInfo: [NSLocalizedDescriptionKey: "Anthropic returned HTTP \(code)"])
    }
    var text = ""
    for try await line in bytes.lines {
        guard line.hasPrefix("data:") else { continue }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard let d = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              json["type"] as? String == "content_block_delta",
              let delta = json["delta"] as? [String: Any],
              let t = delta["text"] as? String else { continue }
        text += t
    }
    return text
}

// Everything lives inside one local function (not top-level globals) so `history`/`memory` are ordinary
// local `var`s with no actor-isolation ceremony — top-level `var`s in an async main.swift pick up
// implicit MainActor isolation in Swift 6, which turns every access into an `await` for no real reason
// here (nothing is actually concurrent).
func run() async throws {
    var args = CommandLine.arguments.dropFirst()
    var provider = "mlx"
    var modelID = "mlx-community/Qwen3-0.6B-4bit"
    var i = args.startIndex
    var positionalSeen = false
    while i < args.endIndex {
        switch args[i] {
        case "--provider":
            i = args.index(after: i)
            if i < args.endIndex { provider = args[i] }
        case "--model":
            i = args.index(after: i)
            if i < args.endIndex { modelID = args[i] }
        default:
            if !positionalSeen { modelID = args[i]; positionalSeen = true }
        }
        i = args.index(after: i)
    }
    if provider == "anthropic", !positionalSeen { modelID = "claude-opus-5" }

    // Stand-in for Lasso's chat system prompt — not byte-identical to the shipped one (that lives inline
    // in ChatController and wasn't worth duplicating here); not what this probe is testing — only the
    // injected memory block's content is under test.
    let systemPrompt = "You are Lasso's chat assistant. Be concise and accurate."

    let send: ([ChatTurn]) async throws -> String
    if provider == "anthropic" {
        guard let apiKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !apiKey.isEmpty else {
            eprint("Set ANTHROPIC_API_KEY in your shell environment first.")
            exit(1)
        }
        eprint("Using Anthropic · \(modelID) (no local model load)\n")
        send = { turns in
            let visible = turns.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            let systemText = visible.filter { $0.role == .system }.map(\.text).joined(separator: "\n\n")
            let wire: [[String: Any]] = visible.filter { $0.role != .system }.map {
                ["role": $0.role.rawValue, "content": $0.text]
            }
            return try await anthropicSend(system: systemText.isEmpty ? systemPrompt : systemText,
                                           messages: wire, apiKey: apiKey, model: modelID)
        }
    } else {
        eprint("Loading \(modelID)…")
        let container = try await #huggingFaceLoadModelContainer(configuration: ModelConfiguration(id: modelID))
        eprint("Loaded.\n")

        // Mirrors MLXProvider.history(from:) — Lasso rebuilds a fresh ChatSession from Swift-owned
        // context on every turn rather than trusting the model's own session history.
        func toSessionInputs(_ turns: [ChatTurn]) -> (instructions: String, prior: [Chat.Message], prompt: String) {
            let visible = turns.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            let last = visible.last ?? ChatTurn(role: .user, text: "")
            let systemText = visible.dropLast().filter { $0.role == .system }.map(\.text).joined(separator: "\n\n")
            let instructions = systemText.isEmpty ? systemPrompt : systemText
            let prior = visible.dropLast().compactMap { turn -> Chat.Message? in
                switch turn.role {
                case .system: return nil
                case .user: return .user(turn.text)
                case .assistant: return .assistant(turn.text)
                }
            }
            return (instructions, Array(prior), last.text)
        }
        send = { turns in
            let (instructions, prior, prompt) = toSessionInputs(turns)
            let session = ChatSession(container, instructions: instructions, history: prior,
                                      generateParameters: .init(maxTokens: 600, temperature: 0.2))
            var out = ""
            for try await chunk in session.streamResponse(to: prompt, role: .user, images: [], videos: []) {
                out += chunk
            }
            return out
        }
    }

    var history: [ChatContextBuilder.HistoryTurn] = []
    var memory = ConversationMemory()
    var summarizedCount = 0
    let builder = ChatContextBuilder()

    /// One ordinary chat turn: build context the real way, send it, print Q/raw-A, fold into history.
    func chat(_ userText: String, label: String) async throws {
        eprint("\n" + String(repeating: "=", count: 70))
        eprint("[\(label)] USER: \(userText)")
        let out = builder.build(systemPrompt: systemPrompt, memory: memory, history: history,
                                currentUserText: userText, currentImageBase64s: [])
        if let mem = out.turns.first(where: { $0.text.hasPrefix(ChatContextBuilder.summaryPreamble) }) {
            eprint("--- injected memory block ---\n\(mem.text)\n---")
        } else {
            eprint("(no memory block injected yet — still inside the recent-verbatim window)")
        }
        // Synced with ChatController.buildTurns: on a recall question, override the general "give your
        // best interpretation" instinct with "say so if it wasn't decided" — inserted right before the
        // question so it's the most recent thing the model reads.
        var turns = out.turns
        if MemoryCore.hasRecallIntent(userText) {
            let note = ChatTurn(role: .system, text: """
                This question asks about the conversation's own history or decisions. Answer strictly \
                from the Decisions/Facts memory above (if present) and the visible conversation — do \
                NOT apply "provide your best interpretation": if something isn't recorded there as \
                decided, say plainly that it wasn't decided rather than guessing one.
                """)
            turns.insert(note, at: max(0, turns.count - 1))
            eprint("--- recall-intent note injected ---")
        }
        let raw = try await send(turns)
        let answer = MemoryCore.stripThoughtBlocks(from: raw)
        print("[\(label)] ANSWER: \(answer)\n")   // stdout: the thing a human grader reads

        history.append(.init(role: .user, text: userText))
        history.append(.init(role: .assistant, text: answer))

        // Fold any newly-overflowed turns into memory — the same trigger Lasso uses (new overflow beyond
        // what's already been summarized).
        let check = builder.build(systemPrompt: systemPrompt, memory: memory, history: history,
                                  currentUserText: "", currentImageBase64s: [])
        if check.overflow.count > summarizedCount {
            let newTurns = Array(check.overflow[summarizedCount...])
            let transcript = MemoryCore.transcript(of: newTurns)
            let prompt = MemoryCore.summarizationPrompt(prior: memory, newTranscript: transcript)
            let sumRaw = try await send([ChatTurn(role: .user, text: prompt)])
            let candidate = MemoryCore.parseMemory(from: sumRaw, prior: memory)
            eprint("--- summarizer raw output ---\n\(sumRaw)\n---")
            if MemoryCore.isNewContentGrounded(updated: candidate, prior: memory, transcript: transcript) {
                memory = candidate
                summarizedCount = check.overflow.count
                eprint("--- parsed memory (ACCEPTED) ---\nFACTS: \(memory.durableFacts)\nDECISIONS: \(memory.decisions)\nTOPICS: \(memory.topicTrace)\n---")
            } else {
                eprint("--- REJECTED — new content ungrounded in the real exchange, keeping prior memory ---")
            }
        }
    }

    // The scripted probe: a settled decision, a mere suggestion the model itself makes, a rejection, two
    // distractor topics (unrelated technical questions), then three recall questions whose correct
    // answers are known in advance because this script wrote the "ground truth" itself.
    try await chat("I'm building Lasso, a local-first AI assistant for macOS. For chat, I want ordinary conversation to be excellent even on a small local model.", label: "1 setup")
    try await chat("The three most important things are adaptive memory, context budgeting, and conversation state.", label: "2 priorities")
    try await chat("What summarization technique could we use for the structured summaries — just suggest one option, don't decide anything yet.", label: "3 suggestion (should NOT become a decision)")
    try await chat("Let's not lock in a specific summarization algorithm yet — we'll keep it generic structured summaries for now. Also, let's not use semantic retrieval.", label: "4 real decision + rejection")
    try await chat("What's the difference between TCP and UDP?", label: "5 distractor")
    try await chat("Explain what a hash table is in one sentence.", label: "6 distractor")
    try await chat("Going back to Lasso — what did we decide about semantic retrieval?", label: "7 RECALL: expect 'rejected', never 'we decided to use it'")
    try await chat("What summarization algorithm did we decide on?", label: "8 RECALL: expect 'not decided / generic', NOT the specific algorithm merely suggested in turn 3")
    try await chat("What were the three most important things we identified for Lasso's chat?", label: "9 RECALL: expect adaptive memory / context budgeting / conversation state")

    eprint("\nDone. Grade turns 7–9 against the labeled expectations above.")
}

try await run()
