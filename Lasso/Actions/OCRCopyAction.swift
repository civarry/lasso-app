import SwiftUI

/// Copy recognized text from the selection to the pasteboard.
struct OCRCopyAction: CaptureAction {
    let id = "ocr.copy"
    nonisolated static let defaultTitle = BuiltInContent.Title.copyText
    var title: String { PatchState.title(id, default: Self.defaultTitle) }
    var systemImage: String { PatchState.symbol(id, default: BuiltInContent.Symbol.copyText) }
    let relevancePriority = 10

    func isRelevant(to ctx: CaptureContext) -> Bool { true }
    func disabledReason(for ctx: CaptureContext, visionAvailable: Bool) -> String? {
        ctx.ocrText?.isEmpty == false ? nil : "No text detected in the selection."
    }

    func perform(_ ctx: CaptureContext) async throws -> ActionResult {
        guard let text = ctx.ocrText, !text.isEmpty else { return .none }
        Pasteboard.copy(text)
        return .copiedToPasteboard("Copied \(text.count) characters")
    }
}
