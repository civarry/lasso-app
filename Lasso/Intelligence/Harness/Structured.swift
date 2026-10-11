import Foundation

/// How a structured value was actually obtained. The call site does not choose a rung: the runner
/// walks down until something works, so the *same* code gets constrained decoding on Apple silicon,
/// a JSON-schema request on Ollama or a cloud endpoint, and a parsed line format on MLX.
///
/// This ladder is the point of the whole layer. A 1B model on `.guided` emits a valid plan more
/// reliably than a frontier model on `.lineFormat`, because on `.guided` an invalid plan is not a
/// thing the decoder can produce.
enum StructuredRung: String, Sendable {
    /// Native constrained decoding (Apple `@Generable`). Malformed output is impossible.
    case guided
    /// The backend's own JSON-schema mode (Ollama `format`, OpenAI `response_format`, Anthropic
    /// forced tool use). Schema-shaped, but the transport may still wrap or truncate it.
    case jsonSchema
    /// Plain text in a labeled line format, parsed leniently. The floor, and MLX's only rung.
    case lineFormat
    /// Nothing usable came back. The call site applies its own deterministic fallback.
    case none
}

/// A value the harness can ask a model for. Conformers describe themselves once and become usable on
/// every backend: the runner picks the best available rung and hands back a parsed value.
///
/// Deliberately not `Codable`: the whole difficulty is *lenient* reading of imperfect model output,
/// which a synthesized decoder gets exactly wrong by failing the whole object on one bad field.
protocol StructuredOutput: Sendable {
    /// Schema identifier sent to backends that name their schemas (OpenAI, Anthropic). Also the log tag.
    static var schemaName: String { get }
    /// JSON Schema as a string. A string, not `[String: Any]`, so it crosses isolation freely under
    /// strict concurrency and every provider can decode it where it needs it.
    static var schemaJSON: String { get }
    /// Instructions appended to the prompt on the `.lineFormat` rung, describing the labeled lines to
    /// emit. Never sent on `.guided` (the schema is enforced) or `.jsonSchema` (the schema is sent).
    static var lineFormatSpec: String { get }

    /// Read the value out of a decoded JSON object. Should salvage what it can rather than fail.
    static func parse(json: [String: Any]) -> Self?
    /// Read the value out of free text in the line format. Should also fail softly.
    static func parse(text: String) -> Self?

    /// Rung 1: produce the value through Apple's guided generation. Types that have no `@Generable`
    /// mirror inherit the default and simply start at rung 2.
    static func generateOnDevice(_ provider: OnDeviceProvider, prompt: String,
                                 maxTokens: Int) async throws -> Self?
}

extension StructuredOutput {
    static func generateOnDevice(_ provider: OnDeviceProvider, prompt: String,
                                 maxTokens: Int) async throws -> Self? { nil }
}

/// What the runner produced, and which rung produced it. `value == nil` means every rung failed and
/// the caller should fall back to a hand-computed value: the runner never throws, because a harness
/// that can fail is a harness the call site has to defend against.
struct StructuredResult<Value: StructuredOutput>: Sendable {
    let value: Value?
    let rung: StructuredRung

    var succeeded: Bool { value != nil }
}

/// Walks the rung ladder for one structured request.
enum StructuredRunner {
    /// Cap on the raw text we will read back on the line-format rung. The structured replies this
    /// layer asks for are tiny; anything longer is a model that started writing an essay.
    static let maxRawChars = 1_200

    static func run<Value: StructuredOutput>(
        _ type: Value.Type,
        prompt: String,
        provider: any IntelligenceProvider,
        maxTokens: Int = 256
    ) async -> StructuredResult<Value> {
        if Task.isCancelled { return .init(value: nil, rung: .none) }

        // Rung 1 — native constrained decoding. Only Apple's on-device model has it, and only for
        // types that ship a `@Generable` mirror.
        if let onDevice = provider as? OnDeviceProvider {
            do {
                if let value = try await Value.generateOnDevice(onDevice, prompt: prompt,
                                                                maxTokens: maxTokens) {
                    return .init(value: value, rung: .guided)
                }
            } catch {
                Log.intelligence.notice(
                    "structured · \(Value.schemaName, privacy: .public) guided rung failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        if Task.isCancelled { return .init(value: nil, rung: .none) }

        // Rung 2 — the backend's own JSON-schema mode. Providers without one return nil immediately.
        do {
            if let raw = try await provider.respondJSON(prompt: prompt,
                                                        schemaName: Value.schemaName,
                                                        schemaJSON: Value.schemaJSON,
                                                        maxTokens: maxTokens),
               let object = ModelText.firstJSONObject(in: raw),
               let value = Value.parse(json: object) {
                return .init(value: value, rung: .jsonSchema)
            }
        } catch {
            Log.intelligence.notice(
                "structured · \(Value.schemaName, privacy: .public) json rung failed: \(error.localizedDescription, privacy: .public)")
        }
        if Task.isCancelled { return .init(value: nil, rung: .none) }

        // Rung 3 — ask in a labeled line format and parse leniently. A model that ignores the line
        // format and emits JSON anyway is still understood, which happens often enough to matter.
        var raw = ""
        do {
            for try await delta in provider.respond(prompt: prompt + "\n\n" + Value.lineFormatSpec,
                                                    context: nil) {
                if Task.isCancelled { return .init(value: nil, rung: .none) }
                raw += delta
                if raw.count > maxRawChars { break }
            }
        } catch {
            Log.intelligence.notice(
                "structured · \(Value.schemaName, privacy: .public) line rung failed: \(error.localizedDescription, privacy: .public)")
            return .init(value: nil, rung: .none)
        }
        if let value = Value.parse(text: raw) { return .init(value: value, rung: .lineFormat) }
        if let object = ModelText.firstJSONObject(in: raw), let value = Value.parse(json: object) {
            return .init(value: value, rung: .lineFormat)
        }
        return .init(value: nil, rung: .none)
    }
}
