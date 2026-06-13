import CoreGraphics
import Foundation

/// One message shown in the Chat panel. The optional `image` is the user's attachment (rendered as a
/// thumbnail); it's encoded / described separately when the turn is sent to a provider.
///
/// `@unchecked Sendable`: the stored `CGImage` is an immutable Core Graphics object, safe to read
/// concurrently; we never mutate it after attaching.
struct ChatMessage: Identifiable, @unchecked Sendable {
    enum Role: Sendable { case user, assistant }

    let id = UUID()
    let role: Role
    /// What's shown in the bubble (the user's typed text).
    var text: String
    var image: CGImage?
    var isStreaming: Bool = false
    /// Set on an assistant message when the request failed, so the bubble can style it as an error.
    var isError: Bool = false
    /// Live progress shown before the first token arrives ("Looking at the image…", "Thinking…").
    var statusText: String?

    /// The text actually sent to the model for this turn — may differ from `text` because it folds in
    /// seeded capture context or an image description. Used to rebuild conversation history so context
    /// (e.g. an image's description) carries across follow-up turns. Falls back to `text`.
    var promptText: String?
    /// Base64 JPEG sent natively for this turn (multimodal models), re-sent in history so the image
    /// stays in context for follow-ups. Nil for the describe-then-text path.
    var imageBase64: String?
    /// Web/connector sources used to ground this assistant turn, shown as tappable links.
    var sources: [WebSourcesProvider.Hit] = []
}
