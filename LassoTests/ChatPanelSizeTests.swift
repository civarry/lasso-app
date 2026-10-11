import Testing
import AppKit
import SwiftUI
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

    /// The header's menus were `.fixedSize()`, so a long conversation title or model name made the
    /// whole card wider than the window (547pt at any width): the content was cut off on both sides
    /// and the rounded corners were clipped square. At the minimum width it must fit.
    @Test func contentFitsTheMinimumWidthWithALongModelName() {
        let intelligence = IntelligenceCoordinator.shared
        let saved = (intelligence.preferred, intelligence.openAIModel)
        intelligence.preferred = .openAICompatible
        intelligence.openAIModel = "some-provider/an-extremely-long-model-name-for-layout-testing-v2:free"
        defer { intelligence.preferred = saved.0; intelligence.openAIModel = saved.1 }

        let hosting = NSHostingController(rootView: ChatView())
        let width = ChatPanelController.minimumSize.width
        let needed = hosting.sizeThatFits(in: CGSize(width: width, height: ChatPanelController.minimumSize.height))
        #expect(needed.width <= width, "chat content needs \(needed.width)pt at \(width)pt")
    }

    /// The model chip shows only the provider, capped at 22 characters, so it keeps its natural width
    /// beside the close button instead of stretching (a 170pt maxWidth left a gap before the ✕).
    @Test func modelChipShowsAShortProviderName() {
        #expect(ChatView.friendlyModel("Local · Qwen3.5-9B-Uncensored-HauhauCS-Aggressive-MLX-mxfp4") == "Local")
        #expect(ChatView.friendlyModel("Groq · openai/gpt-oss-120b") == "Groq")
        #expect(ChatView.friendlyModel("Apple Intelligence") == "Apple Intelligence")
        let long = ChatView.friendlyModel("My Company's Internal AI Gateway (EU) · some-model")
        #expect(long.count == 22 && long.hasSuffix("…"))
    }
}
