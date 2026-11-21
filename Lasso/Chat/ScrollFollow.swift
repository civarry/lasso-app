import CoreGraphics

/// When the chat follows a reply as it streams in.
///
/// Following stops only when the reader scrolls up, and starts again when they're back at the bottom.
/// Deciding from "is it at the bottom?" alone doesn't work: each new piece of a reply makes the content
/// taller a moment before the view scrolls down to it, so for that moment it isn't at the bottom, and
/// following switched itself off mid-reply (the "Latest" button showing while you hadn't touched it).
enum ScrollFollow {
    struct Position: Equatable {
        var offset: CGFloat
        var atBottom: Bool
    }

    static func follows(was following: Bool, from old: Position, to new: Position) -> Bool {
        if new.atBottom { return true }
        // Content growing leaves the offset where it was; only the reader scrolling up lowers it.
        if new.offset < old.offset - 1 { return false }
        return following
    }

    /// Everything about the latest message that makes it taller: its text, and for the Agent its steps,
    /// approval card, thinking and status line, which change without the text changing.
    struct Growth: Equatable {
        var text: Int, reasoning: Int, steps: Int, stepsDone: Int
        var status: String?, approval: Bool, sources: Int, notice: Bool
    }

    static func growth(_ m: ChatMessage) -> Growth {
        Growth(text: m.text.count, reasoning: m.reasoning.count, steps: m.steps.count,
               stepsDone: m.steps.filter(\.done).count, status: m.statusText, approval: m.approval != nil || m.toolApproval != nil,
               sources: m.sources.count, notice: m.notice != nil)
    }
}
