import SwiftUI

/// Opt-in: search the selection with Google Lens. Renders the results in a floating card anchored to
/// the selection (`LensResultView`) — same chrome as Identify — that uploads the image and shows the
/// visual matches, the same flow Findit uses.
///
/// It leaves the Mac, so it's off by default, hidden in local-only mode, and only appears once the
/// user enables it in Settings ▸ General ▸ Privacy.
struct LensSearchAction: CaptureAction {
    let id = "lens.search"
    let title = "Google Lens"
    let systemImage = "photo.badge.magnifyingglass"
    let relevancePriority = 13

    static let enabledKey = "lens.search.enabled"

    func isRelevant(to ctx: CaptureContext) -> Bool {
        UserDefaults.standard.bool(forKey: Self.enabledKey) && !PrivacyMode.localOnly
    }

    func perform(_ ctx: CaptureContext) async throws -> ActionResult {
        let anchor = CaptureCoordinator.shared.activeSelectionScreenRect()
        LensPanelController.shared.present(image: ctx.image, anchor: anchor)
        return .none   // CaptureCoordinator.run drops the freeze on .none; the card persists.
    }
}
