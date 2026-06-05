import AppKit

/// Open or copy a detected QR / barcode payload.
struct QRAction: CaptureAction {
    let id = "qr.open"
    let title = "Open code"
    let systemImage = "qrcode.viewfinder"
    let relevancePriority = 15

    func isRelevant(to ctx: CaptureContext) -> Bool {
        ctx.detectedData.contains { $0.kind == .qr || $0.kind == .barcode }
    }

    func perform(_ ctx: CaptureContext) async throws -> ActionResult {
        guard let item = ctx.detectedData.first(where: { $0.kind == .qr || $0.kind == .barcode })
        else { return .none }
        if let url = item.url {
            NSWorkspace.shared.open(url)
            return .openedURL(url)
        }
        Pasteboard.copy(item.value)
        return .copiedToPasteboard("Copied payload: \(item.value)")
    }
}
