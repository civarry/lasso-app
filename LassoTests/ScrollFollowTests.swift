import CoreGraphics
import Testing
@testable import Lasso

/// The chat follows a streaming reply until the reader scrolls up. It used to switch itself off
/// whenever a new piece of the reply made the content taller before the view scrolled down to it.
struct ScrollFollowTests {
    private typealias P = ScrollFollow.Position

    @Test func contentGrowingDoesNotStopFollowing() {
        // Same offset, no longer at the bottom: the reply grew.
        #expect(ScrollFollow.follows(was: true, from: P(offset: 500, atBottom: true), to: P(offset: 500, atBottom: false)))
    }

    @Test func scrollingUpStopsFollowing() {
        #expect(!ScrollFollow.follows(was: true, from: P(offset: 500, atBottom: true), to: P(offset: 420, atBottom: false)))
    }

    @Test func stillScrolledUpWhileTheReplyGrows() {
        #expect(!ScrollFollow.follows(was: false, from: P(offset: 420, atBottom: false), to: P(offset: 420, atBottom: false)))
    }

    @Test func backAtTheBottomFollowsAgain() {
        #expect(ScrollFollow.follows(was: false, from: P(offset: 420, atBottom: false), to: P(offset: 900, atBottom: true)))
    }

    @Test func agentStepsCountAsGrowth() {
        var message = ChatMessage(role: .assistant, text: "")
        let before = ScrollFollow.growth(message)
        message.steps.append(ActivityStep(icon: "terminal", text: "Ran a command"))
        #expect(ScrollFollow.growth(message) != before)
        let withStep = ScrollFollow.growth(message)
        message.steps[0].done = true
        #expect(ScrollFollow.growth(message) != withStep)
    }
}
