import Testing
import Foundation
@testable import Lasso

/// The chat prompt used to call the device time "authoritative" and tell the model to "answer
/// directly"; a local model (Qwen3.5 9B on MLX) then answered "hey" with "Monday, September 28, 2026 at
/// 2:34 PM GMT+8." The date is background: present for questions that need it, never volunteered.
@MainActor
struct ChatDatePromptTests {
    @Test func theDateIsBackgroundNotAnInstruction() {
        let prompt = ChatController.systemPrompt
        #expect(prompt.contains("the device clock reads"))
        #expect(prompt.contains("don't mention it otherwise"))
        #expect(!prompt.contains("authoritative"))
    }
}

/// Greetings get no date; time questions still get it. Against a real model, opt-in:
///     TEST_RUNNER_LASSO_LIVE=1 [TEST_RUNNER_LASSO_MLX_LOCAL=1] xcodebuild test -only-testing:LassoTests/ChatDatePromptLiveTests
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["LASSO_LIVE"] == "1"
                              || ProcessInfo.processInfo.environment["LASSO_MLX_LOCAL"] == "1"))
@MainActor
struct ChatDatePromptLiveTests {
    private func providers() -> [(String, IntelligenceProvider)] {
        var list: [(String, IntelligenceProvider)] = []
        let local = "TheCluster/Qwen3.5-9B-Uncensored-HauhauCS-Aggressive-MLX-mxfp4"
        if ProcessInfo.processInfo.environment["LASSO_MLX_LOCAL"] == "1", MLXProvider.isDownloaded(local) {
            list.append(("MLX Qwen3.5 9B", MLXProvider(modelID: local)))
        }
        if ProcessInfo.processInfo.environment["LASSO_LIVE"] == "1",
           let groq = KeysRegistry.load().entries.first(where: { $0.name == "Groq" }) {
            list.append(("Groq gpt-oss-120b", OpenAICompatibleProvider(baseURL: URL(string: groq.baseURL)!,
                apiKey: Keychain.get(groq.keychainAccount) ?? "", model: "openai/gpt-oss-120b", displayName: "Groq")))
        }
        return list
    }

    private func ask(_ provider: IntelligenceProvider, _ user: String) async throws -> String {
        var out = ""
        for try await d in provider.respond(messages: [ChatTurn(role: .system, text: ChatController.systemPrompt),
                                                       ChatTurn(role: .user, text: user)]) {
            out += d; if out.count > 400 { break }
        }
        return out
    }

    @Test func greetingsDontGetTheDateButTimeQuestionsDo() async throws {
        let year = String(Calendar.current.component(.year, from: .now))
        let weekday = DateFormatter().weekdaySymbols[Calendar.current.component(.weekday, from: .now) - 1]
        for (name, provider) in providers() {
            for greeting in ["hey", "hellooo", "you good?", "thanks!"] {
                let reply = try await ask(provider, greeting)
                print("[date] \(name) · \(greeting) → \(reply.prefix(120))")
                #expect(!reply.contains(year), "\(name) volunteered the date for \"\(greeting)\": \(reply)")
            }
            let today = try await ask(provider, "What day of the week is it today?")
            print("[date] \(name) · today? → \(today.prefix(120))")
            #expect(today.contains(weekday), "\(name) lost the date: \(today)")
        }
    }
}
