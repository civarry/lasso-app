import CoreGraphics
import Foundation

/// One image attached to a chat turn. Carries a stable `id` (so the composer can remove/reorder
/// without index bugs) plus cached, structured `caption`/`ocr` — the canonical *textual*
/// representation used for text-only models and for history (so pixels aren't re-sent every follow-up).
///
/// `@unchecked Sendable`: the `CGImage` is an immutable Core Graphics object, safe to read concurrently.
struct Attachment: Identifiable, @unchecked Sendable {
    let id = UUID()
    let image: CGImage
    /// Vision-model description (generated once, cached). Kept separate from `ocr` so providers can
    /// format them however their model prefers.
    var caption: String?
    /// On-screen text recognized in the image (generated once, cached).
    var ocr: String?
}

/// One message shown in the Chat panel. `attachments` are the user's images (rendered as thumbnails);
/// they're encoded natively and/or described separately when the turn is sent to a provider.
///
/// `@unchecked Sendable`: stored `CGImage`s are immutable Core Graphics objects, safe to read
/// concurrently; we never mutate them after attaching.
struct ChatMessage: Identifiable, @unchecked Sendable {
    enum Role: Sendable { case user, assistant }

    let id = UUID()
    let role: Role
    /// What's shown in the bubble (the user's typed text).
    var text: String
    var attachments: [Attachment] = []
    var isStreaming: Bool = false
    /// Set on an assistant message when the request failed, so the bubble can style it as an error.
    var isError: Bool = false
    /// Live progress shown before the first token arrives ("Looking at the image…", "Thinking…").
    var statusText: String?

    /// The text actually sent to the model for this turn — may differ from `text` because it folds in
    /// seeded capture context or an image description. Used to rebuild conversation history so context
    /// (e.g. an image's description) carries across follow-up turns. Falls back to `text`.
    var promptText: String?
    /// Base64 JPEGs sent natively for this turn (multimodal models), re-sent in history so the images
    /// stay in context for follow-ups. Empty for the describe-then-text path.
    var imageBase64s: [String] = []
    /// Web/connector sources used to ground this assistant turn, shown as tappable links.
    var sources: [WebSourcesProvider.Hit] = []

    /// Background activity for this assistant turn (looked at image, searched web, read pages…),
    /// shown as an expandable trace like other LLM chats.
    var steps: [ActivityStep] = []
    /// The model's chain-of-thought, if it emits one (e.g. Qwen3 / DeepSeek `<think>…</think>`).
    /// Shown in a collapsible "Thought for Xs" section, separate from the answer.
    var reasoning: String = ""
    /// Seconds the model spent reasoning (set when the `<think>` block closes).
    var reasoningSeconds: Int?
}

/// One step in an assistant turn's background activity trace.
struct ActivityStep: Identifiable, Sendable {
    let id = UUID()
    var icon: String
    var text: String
    var links: [WebSourcesProvider.Hit] = []
    var done: Bool = false
}
