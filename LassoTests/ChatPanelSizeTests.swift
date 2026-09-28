import Testing
import AppKit
@testable import Lasso

/// The chat panel could be resized until nothing was visible: `panel.minSize` was set, but AppKit
/// recomputes an Auto Layout window's limits on the first layout pass and reset it to 0×0.
@MainActor
@Suite(.serialized)
struct ChatPanelSizeTests {
    @Test func minimumSizeSurvivesLayout() async throws {
        let controller = ChatPanelController.shared
        controller.present()
        defer { controller.close() }
        let panel = try #require(controller.panel)
        // Let AppKit run its layout pass, which is what used to wipe the minimum.
        try await Task.sleep(for: .milliseconds(300))
        panel.layoutIfNeeded()
        #expect(panel.minSize.width >= ChatPanelController.minimumSize.width)
        #expect(panel.minSize.height >= ChatPanelController.minimumSize.height)
        // And the panel keeps its real size rather than collapsing to the content's fitting size.
        #expect(panel.frame.width >= ChatPanelController.minimumSize.width)
        #expect(panel.frame.height >= ChatPanelController.minimumSize.height)
    }
}
