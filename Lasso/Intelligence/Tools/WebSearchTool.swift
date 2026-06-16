import Foundation
import FoundationModels

/// FoundationModels tool that lets the on-device model decide when a turn needs web facts and route
/// to the app's connectors (the industry-standard function-calling path for Apple Intelligence). The
/// framework invokes `call` when the model emits a tool call, then continues the turn with the result.
///
/// The actual search runs in app land — this just bridges the model's `query` to the supplied
/// executor, so privacy/connector gating stays in one place (`ChatController`). Only attached when a
/// connector is active and local-only mode is off.
struct WebSearchTool: Tool {
    let name = "web_search"
    let description = "Search the web for current, real-world, or factual information that may be "
        + "outside your knowledge (recent events, prices, specs, people, places, products). Only call "
        + "this when external facts would materially improve the answer — skip it for greetings, "
        + "opinions, writing/editing tasks, or things you already know."

    /// Bridges the model's query to the app's connector-backed search; returns text to ground on.
    let run: @Sendable (String) async -> String

    @Generable
    struct Arguments {
        @Guide(description: "A focused search query capturing what to look up.")
        var query: String
    }

    func call(arguments: Arguments) async throws -> String {
        Log.intelligence.notice("web_search tool called: \(arguments.query, privacy: .public)")
        return await run(arguments.query)
    }
}
