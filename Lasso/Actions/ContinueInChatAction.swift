import SwiftUI

/// Bridge from a capture into the persistent Chat panel: seed a conversation with the selection's
/// text (and image) so the user can keep asking follow-ups — the thing Chrome's page-only assistant
/// can't do, since this works on anything on screen.
struct ContinueInChatAction: CaptureAction {
    let id = "chat.continue"
    let title = "Continue in chat"
    let systemImage = "bubble.left.and.text.bubble.right"
    let relevancePriority = 45   // just after Ask AI (40)

    func isRelevant(to ctx: CaptureContext) -> Bool { true }

    func perform(_ ctx: CaptureContext) async throws -> ActionResult {
        ChatPanelController.shared.open(seedText: ctx.ocrText, seedImage: ctx.image)
        return .none   // CaptureCoordinator tears down the capture session on `.none`
    }
}
