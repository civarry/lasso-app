import SwiftUI

/// "Identify": run a local vision model + (opt-in) TinEye reverse search in parallel, then
/// synthesize a summary with the user's text provider. Results show in a floating card.
struct IdentifyAction: CaptureAction {
    let intelligence: IntelligenceCoordinator

    let id = "identify"
    let title = "Identify"
    let systemImage = "sparkle.magnifyingglass"
    let relevancePriority = 12

    func isRelevant(to ctx: CaptureContext) -> Bool { true }

    func perform(_ ctx: CaptureContext) async throws -> ActionResult {
        let anchor = CaptureCoordinator.shared.activeSelectionScreenRect()
        FloatingPanelController.shared.present(
            AnyView(IdentifyView(image: ctx.image, ocrText: ctx.ocrText, intelligence: intelligence)),
            anchor: anchor)
        return .none   // CaptureCoordinator.run drops the freeze on .none
    }
}
