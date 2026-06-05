import Foundation
import FoundationModels

/// Stub for FoundationModels tool calling: lets the on-device session decide when a query needs
/// external facts and route to a web/cloud provider (Spec §8). Disabled by default — wiring a real
/// search backend is an explicit opt-in (M6) so the "no network unless asked" promise holds.
///
/// Conforms to FoundationModels' `Tool` protocol so it can be attached to a `LanguageModelSession`.
struct WebSearchTool: Tool {
    let name = "webSearch"
    let description = "Search the web for current, real-world facts the on-device model may not know."

    @Generable
    struct Arguments {
        @Guide(description: "The search query")
        var query: String
    }

    func call(arguments: Arguments) async throws -> String {
        // Intentionally not implemented: returns a clear signal instead of making a network call.
        // Implement against a chosen search backend in M6, behind an explicit user toggle.
        Log.intelligence.notice("webSearch tool invoked (disabled): \(arguments.query, privacy: .public)")
        return "Web search is disabled. Enable a search backend in Settings to use this."
    }
}
