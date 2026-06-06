import SwiftUI

/// Reverse image search via Google (embedded, in-app). Opt-in: only appears when the user has
/// enabled "Web image search" in Settings, because it's the one feature that leaves the Mac
/// (the crop is sent to Google). Spec §2/§17: no native reverse-image API, so we hand off to a
/// web service — here, rendered inside the app rather than bouncing to the browser.
struct ImageSearchAction: CaptureAction {
    let id = "image.search"
    let title = "Search image"
    let systemImage = "photo.badge.magnifyingglass"
    let relevancePriority = 45

    func isRelevant(to ctx: CaptureContext) -> Bool {
        UserDefaults.standard.bool(forKey: "imageSearch.enabled")
    }

    func perform(_ ctx: CaptureContext) async throws -> ActionResult {
        // Show results in a floating card (independent of the freeze overlay) and dismiss the
        // overlay, so the user can open matches in the browser while the results persist on top.
        let anchor = CaptureCoordinator.shared.activeSelectionScreenRect()
        FloatingPanelController.shared.present(AnyView(ImageSearchView(image: ctx.image)), anchor: anchor)
        return .none
    }
}
