import Foundation

/// Which tools the model is offered on a given turn.
///
/// Registration and exposure are separate concerns. Every tool Lasso knows how to run lives in
/// `registered`; only a small, turn-relevant subset is ever *shown* to the model. That split is the
/// single cheapest reliability win available to a small model: tool-choice accuracy falls off as the
/// menu grows, and every unused definition is context spent on something the model will not call.
/// A small tool surface is a common benchmark setup for exactly this reason.
///
/// Two rules hold as tools are added:
/// 1. **Cap the menu.** At most `maxExposed`, ordered most-likely-first.
/// 2. **Every description says when *not* to call.** A small model over-calls tools unless the
///    negative case is spelled out (see `ChatTool.webSearch`).
///
/// Exposure runs *after* the privacy gate, never as a UI filter: a tool that can leave the device is
/// absent from the menu in local-only mode rather than present and refused.
enum Toolbelt {
    /// Hard cap on tools offered in one turn.
    static let maxExposed = 3

    /// Everything the app can run. One entry today; the registry exists so adding the local tools
    /// (`read_screen`, `translate_text`, `extract_table`, `recall_conversation`) is a list edit plus
    /// an executor, not a new decision about how tools reach the model.
    static let registered: [ChatTool] = [.webSearch]

    /// What the harness knows about this turn when choosing the menu.
    struct Context: Sendable {
        /// The active text provider has a native tool-calling loop. False means the caller must use
        /// the heuristic grounding route instead.
        var providerSupportsTools: Bool
        /// Web grounding is permitted right now: globe on, a connector active, not local-only.
        var webGroundingAllowed: Bool
    }

    /// The tools to offer for this turn. Empty means "no tool loop": the caller answers in one pass.
    static func expose(for context: Context) -> [ChatTool] {
        guard context.providerSupportsTools else { return [] }
        var tools: [ChatTool] = []
        if context.webGroundingAllowed { tools.append(.webSearch) }
        return Array(tools.prefix(maxExposed))
    }
}
