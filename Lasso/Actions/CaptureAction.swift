import CoreGraphics
import SwiftUI

/// Categories of data the detection pre-pass can surface from a selection.
enum DetectedKind: String, Sendable, CaseIterable {
    case url, phone, email, address, date, qr, barcode
}

/// A single piece of actionable data found in the selection (a link, phone number, QR payload…).
struct DetectedItem: Identifiable, Sendable, Hashable {
    let id = UUID()
    let kind: DetectedKind
    /// Human-readable value (the matched string / decoded payload).
    let value: String
    /// A directly openable URL when applicable (https:, tel:, mailto:, maps:…).
    let url: URL?

    init(kind: DetectedKind, value: String, url: URL? = nil) {
        self.kind = kind
        self.value = value
        self.url = url
    }
}

/// Everything an action needs about the current selection. Immutable snapshot of one session.
///
/// `@unchecked Sendable`: the stored `CGImage`s are immutable Core Graphics objects that are
/// safe to read concurrently; we never mutate them after capture. This lets us hand the context
/// to engine `actor`s without copying the pixel buffers.
struct CaptureContext: @unchecked Sendable {
    /// Cropped selection (native pixels).
    let image: CGImage
    /// The whole frozen display the selection came from (for re-selection / object lift).
    let fullFrame: CGImage
    /// Selection rect in that display's points (top-left origin, as on screen).
    let selectionRect: CGRect
    /// OCR text, populated by the pre-pass if it has already run.
    var ocrText: String?
    /// Per-line OCR results with bounding boxes (for inline overlay translation).
    var ocrLines: [OCRLine]
    /// Links / phones / QR codes etc. found in the selection.
    var detectedData: [DetectedItem]
    /// Which display the selection came from.
    let displayID: CGDirectDisplayID

    init(
        image: CGImage,
        fullFrame: CGImage,
        selectionRect: CGRect,
        ocrText: String? = nil,
        ocrLines: [OCRLine] = [],
        detectedData: [DetectedItem] = [],
        displayID: CGDirectDisplayID
    ) {
        self.image = image
        self.fullFrame = fullFrame
        self.selectionRect = selectionRect
        self.ocrText = ocrText
        self.ocrLines = ocrLines
        self.detectedData = detectedData
        self.displayID = displayID
    }
}

/// What an action produces. Rendered/handled by the ResultPane on the main actor.
enum ActionResult {
    /// Static text to show in the ResultPane.
    case text(String)
    /// Streamed output (AI). The pane appends chunks as they arrive.
    case stream(AsyncThrowingStream<String, Error>)
    /// The action put something on the pasteboard; show a brief confirmation.
    case copiedToPasteboard(String)
    /// The action opened a URL externally; no pane needed.
    case openedURL(URL)
    /// A bespoke SwiftUI view (color swatch, table preview, …).
    case custom(AnyView)
    /// Enter inline overlay-translation mode (translate text in place over the selection).
    case inlineTranslate
    /// Nothing to display.
    case none
}

/// The one protocol every capability conforms to. Add a feature == add a `CaptureAction` and
/// register it (see `ActionRegistry`). Actions are coordinated on the main actor; heavy work is
/// delegated to engine `actor`s via `await`.
@MainActor
protocol CaptureAction {
    var id: String { get }
    var title: String { get }
    /// SF Symbol name shown on the pill.
    var systemImage: String { get }
    /// Lower sorts first in the ActionBar.
    var relevancePriority: Int { get }

    /// Is this action useful for the current selection? (e.g. QR only if a code is present.)
    func isRelevant(to ctx: CaptureContext) -> Bool

    /// Does this action need to *see* the image for this selection? Such actions are greyed in the
    /// bar when no vision backend (Ollama or a cloud image model) is available. Default: no.
    func needsVision(for ctx: CaptureContext) -> Bool

    /// Run it. Return a result to show, or perform a side effect and return `.none`.
    func perform(_ ctx: CaptureContext) async throws -> ActionResult
}

extension CaptureAction {
    var relevancePriority: Int { 100 }
    func needsVision(for ctx: CaptureContext) -> Bool { false }
}
