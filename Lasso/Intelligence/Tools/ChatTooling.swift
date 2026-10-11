import Foundation

/// Provider-agnostic tool definitions for industry-standard function calling. Each provider
/// translates a `ChatTool` into its own wire format (OpenAI `tools`, Anthropic `tools`,
/// Ollama `tools`) and reports calls back as `ToolCall`s. Kept deliberately small — just enough to
/// express the web-search tool — so adding a tool is a few lines, not a new subsystem.
///
/// The model decides *when* to call (the whole point of going tool-based instead of rule-based);
/// the app supplies a `ToolExecutor` that actually runs the work and returns text to feed back.
struct ChatTool: Sendable {
    let name: String
    let description: String
    let parameters: [Parameter]

    struct Parameter: Sendable {
        let name: String
        let type: String          // JSON-schema type, e.g. "string"
        let description: String
        let required: Bool
    }

    /// JSON-schema `parameters` object — the shape OpenAI and Ollama expect, and what Anthropic wants
    /// under `input_schema`.
    var jsonSchema: [String: Any] {
        var properties: [String: Any] = [:]
        for p in parameters {
            properties[p.name] = ["type": p.type, "description": p.description]
        }
        return [
            "type": "object",
            "properties": properties,
            "required": parameters.filter(\.required).map(\.name),
        ]
    }

    /// The web-search tool offered in chat. The model calls it with a focused query when it needs
    /// current / real-world facts; the executor runs the user's configured connectors.
    static let webSearch = ChatTool(
        name: "web_search",
        description: "Search the web for current, real-world, or factual information that may be "
            + "outside the model's knowledge (recent events, prices, specs, people, places, products). "
            + "Only call this when external facts would materially improve the answer — skip it for "
            + "greetings, opinions, writing/editing tasks, or things you already know.",
        parameters: [
            .init(name: "query", type: "string",
                  description: "A focused search query capturing what to look up.", required: true),
        ])
}

/// A tool invocation requested by the model, normalized across providers.
struct ToolCall: Sendable {
    let id: String              // provider's call id, echoed back when returning the result
    let name: String
    let argumentsJSON: String   // raw JSON object, e.g. {"query":"..."}

    /// Pull a string field out of the argument JSON (tolerant of malformed/partial JSON).
    func string(_ key: String) -> String? {
        guard let data = argumentsJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object[key] as? String
    }
}

/// Runs a tool call in app land (web search, etc.) and returns a text result to feed back to the
/// model. `@Sendable` so providers can call it from their streaming task.
typealias ToolExecutor = @Sendable (ToolCall) async -> String

/// How many model→tool→model round-trips to allow before forcing a final answer (guards against a
/// model that keeps calling tools). Two is plenty for "search, then answer".
let maxToolRounds = 3
