import CoreGraphics
import Foundation
import Observation

/// One conversation. The Chat panel holds several of these (`ChatController.sessions`) and shows one
/// at a time (`active`) — so opening "Continue in chat" or an Ask-AI thread spawns a *new* session
/// instead of wiping the one you were working in.
///
/// This is a self-contained state container: its own message history, two-track summary memory,
/// semantic index, pending attachments, and in-flight task handles. `ChatController` owns the logic
/// and drives whichever session is `active`; background tasks capture their session so they always
/// update the right conversation even after the user switches away.
@MainActor
@Observable
final class Conversation: Identifiable {
    let id = UUID()
    let createdAt = Date()
    /// Where this conversation came from, used as a fallback title before the first message
    /// ("Selection", "Ask AI", "Image"…). nil for a plain new chat.
    var originLabel: String?

    // MARK: Conversation state
    var messages: [ChatMessage] = []
    var input = ""
    var pendingAttachments: [Attachment] = []
    var seededContext: String?
    var isStreaming = false
    var trimmedNotice = false
    var streamTask: Task<Void, Never>?

    // MARK: Memory (two-track summary + in-session semantic retrieval) — per session
    var memory = ConversationMemory()
    var summarizedTurnCount = 0
    var summaryTask: Task<Void, Never>?
    let memoryIndex = ChatMemoryIndex()
    var indexTask: Task<Void, Never>?

    /// Header/recents-menu label: the first user message (truncated), else the origin, else "New chat".
    var title: String {
        if let first = messages.first(where: { $0.role == .user })?
            .text.trimmingCharacters(in: .whitespacesAndNewlines), !first.isEmpty {
            return String(first.prefix(42))
        }
        return originLabel ?? "New chat"
    }

    var hasMessages: Bool { !messages.isEmpty }
    /// Whether there's anything to clear (drives New chat / can-clear affordances).
    var canClear: Bool {
        !messages.isEmpty || !input.isEmpty || !pendingAttachments.isEmpty || seededContext != nil
    }

    /// Cancel any in-flight work — called before a session is dropped or switched away from.
    func cancelWork() {
        streamTask?.cancel(); streamTask = nil
        summaryTask?.cancel(); summaryTask = nil
        indexTask?.cancel(); indexTask = nil
    }
}
