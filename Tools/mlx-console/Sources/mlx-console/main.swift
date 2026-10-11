import Foundation
import HuggingFace  // referenced by the #huggingFaceLoadModelContainer macro expansion
import MLXLLM
import MLXLMCommon
import MLXVLM       // links the VLM factory, matching MLXProvider — harmless for text-only models
import MLXHuggingFace
import Tokenizers   // referenced by the #huggingFaceLoadModelContainer macro expansion

// Mirrors Lasso's `MLXProvider.respond(messages:)` (Lasso/Intelligence/MLXProvider.swift): same
// `ChatSession` API, same default model, same generate parameters — so raw output here matches what
// the app would actually produce, just visible in Terminal instead of the Chat UI.

let defaultModelID = "mlx-community/Qwen3-0.6B-4bit"
let defaultSystemPrompt = """
You help the user understand and act on text they selected on their screen. Be concise and accurate. \
When on-screen text is provided, ground your answer in it.
"""

struct Options {
    var modelID = defaultModelID
    var system = defaultSystemPrompt
    var maxTokens = 1024
    var temperature: Float = 0.2
}

func parseArgs(_ args: [String]) -> Options {
    var o = Options()
    var i = 0
    var positionalUsed = false
    while i < args.count {
        switch args[i] {
        case "--system":
            i += 1
            if i < args.count { o.system = args[i] }
        case "--system-file":
            i += 1
            if i < args.count, let text = try? String(contentsOfFile: args[i], encoding: .utf8) {
                o.system = text
            }
        case "--max-tokens":
            i += 1
            if i < args.count, let n = Int(args[i]) { o.maxTokens = n }
        case "--temperature":
            i += 1
            if i < args.count, let t = Float(args[i]) { o.temperature = t }
        case "--help", "-h":
            print("""
            Usage: mlx-console [modelID] [--system TEXT] [--system-file PATH] \
            [--max-tokens N] [--temperature T]

              Piped stdin  → reads it as ONE prompt, streams the raw response, exits.
              Interactive  → REPL: type a message, watch it stream, repeat. /exit to quit.

            Default model: \(defaultModelID)
            """)
            exit(0)
        default:
            if !positionalUsed, !args[i].hasPrefix("--") {
                o.modelID = args[i]
                positionalUsed = true
            }
        }
        i += 1
    }
    return o
}

func eprint(_ s: String) {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
}

/// Stream one turn's raw response to stdout as it arrives — no formatting, no post-processing.
func streamTurn(_ session: ChatSession, _ text: String) async {
    do {
        for try await chunk in session.streamResponse(to: text, role: .user, images: [], videos: []) {
            print(chunk, terminator: "")
            fflush(stdout)
        }
        print()   // final newline once the turn completes
    } catch {
        eprint("\n[error] \(error)")
    }
}

let options = parseArgs(Array(CommandLine.arguments.dropFirst()))

eprint("Loading \(options.modelID)… (first run downloads it — this can take a while)")
let t0 = Date()
let container: ModelContainer
do {
    container = try await #huggingFaceLoadModelContainer(
        configuration: ModelConfiguration(id: options.modelID),
        progressHandler: { progress in
            let pct = Int(progress.fractionCompleted * 100)
            eprint("\r  \(pct)%")
        })
} catch {
    eprint("Failed to load \(options.modelID): \(error)")
    exit(1)
}
eprint("Loaded in \(Int(Date().timeIntervalSince(t0) * 1000))ms · maxTokens=\(options.maxTokens) temperature=\(options.temperature)")
eprint("System: \(options.system.prefix(120))\(options.system.count > 120 ? "…" : "")")
eprint(String(repeating: "─", count: 60))

let session = ChatSession(
    container,
    instructions: options.system,
    generateParameters: .init(maxTokens: options.maxTokens, temperature: options.temperature))

if isatty(fileno(stdin)) == 0 {
    // Piped input: treat the whole thing as one prompt, stream the raw answer, exit.
    let data = FileHandle.standardInput.readDataToEndOfFile()
    let prompt = String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !prompt.isEmpty else { eprint("(empty stdin, nothing to send)"); exit(0) }
    await streamTurn(session, prompt)
} else {
    // Interactive REPL: same session across turns, so it's genuinely multi-turn like the Chat UI.
    eprint("Type a message and press Enter. /exit to quit.\n")
    while true {
        eprint("")
        print("> ", terminator: "")
        fflush(stdout)
        guard let line = readLine(strippingNewline: true) else { break }
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { continue }
        if trimmed == "/exit" || trimmed == "/quit" { break }
        await streamTurn(session, trimmed)
    }
}
