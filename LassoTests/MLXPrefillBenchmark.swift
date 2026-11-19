import Testing
import Foundation
@testable import Lasso

/// How fast MLX reads a long prompt (prefill), per model: the Agent sends ~15k tokens of Hermes
/// instructions per turn, so this decides how long an Agent reply takes to start. Opt-in:
///
///     TEST_RUNNER_LASSO_PREFILL_MODELS="id1,id2" xcodebuild test -scheme Lasso -only-testing:LassoTests/MLXPrefillBenchmark
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["LASSO_PREFILL_MODELS"] != nil))
struct MLXPrefillBenchmark {
    @Test(.timeLimit(.minutes(15)))
    func prefillSpeed() async throws {
        let ids = (ProcessInfo.processInfo.environment["LASSO_PREFILL_MODELS"] ?? "").split(separator: ",").map(String.init)
        let filler = String(repeating: "The quick brown fox jumps over the lazy dog near the river bank. ", count: 300)
        for id in ids {
            for round in 1...2 {
                var usage: (Int, Double)?
                for try await event in MLXProvider.serve(modelID: id, messages: [
                    ["role": "system", "content": filler], ["role": "user", "content": "Say ok."],
                ], tools: nil, maxTokens: 4, temperature: 0) {
                    if case .usage(let prompt, _, let seconds) = event { usage = (prompt, seconds) }
                }
                let (tokens, seconds) = try #require(usage)
                print("[prefill] \(id) round \(round): \(tokens) tokens in \(String(format: "%.1f", seconds))s = \(Int(Double(tokens) / seconds)) tok/s")
            }
        }
    }
}
