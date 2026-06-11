import AppKit
import KeyboardShortcuts
import SwiftUI
import UniformTypeIdentifiers

/// Orchestrates a single capture session end-to-end on the main actor (Spec §3, §6):
/// freeze → overlay → select → pre-pass (OCR / data / barcode) → ActionBar → run actions.
/// Heavy work is delegated to engine `actor`s; large images are released on teardown.
@MainActor
@Observable
final class CaptureCoordinator {
    static let shared = CaptureCoordinator()

    // Dependencies, injected at launch by LassoApp.
    private var registry: ActionRegistry?
    private(set) var intelligence: IntelligenceCoordinator?
    let permissions = PermissionsService()

    // Engines (lazy-ish; cheap to hold, work is isolated).
    private let ocr = OCREngine()
    private let barcode = BarcodeEngine()
    private let dataDetector = DataDetector()

    // Session state, observed by the overlay views.
    private(set) var shots: [DisplayShot] = []
    private(set) var isActive = false
    private(set) var activeDisplayID: CGDirectDisplayID?
    private(set) var committedRect: CGRect?           // local points in the active display
    private(set) var context: CaptureContext?
    private(set) var actions: [any CaptureAction] = []
    /// User-applied drag offset for the floating bar/result panel (movable for large/multi-display
    /// setups). Reset on each new selection. The in-place translation boxes are unaffected.
    var panelDragOffset: CGSize = .zero

    /// Speculative pre-translation cache for the current selection: translated text keyed by OCR
    /// line id, plus the target language and time it took. Seeded by TranslationPrewarmer in the
    /// background so tapping Translate is instant. Reset on each new selection.
    var pretranslated: [UUID: String] = [:]
    var pretranslatedTarget: Locale.Language?
    var pretranslatedDuration: TimeInterval?
    /// When true, the overlay shows inline translated text over the selection instead of the
    /// normal action bar (Google "translate in place" style).
    private(set) var translating = false

    private var overlayWindows: [OverlayWindow] = []
    private var keyMonitor: Any?
    private var runTask: Task<Void, Never>?

    private init() {}

    func configure(registry: ActionRegistry, intelligence: IntelligenceCoordinator) {
        self.registry = registry
        self.intelligence = intelligence
    }

    // MARK: - Session lifecycle

    func begin() {
        guard !isActive else { return }
        Task { await start() }
    }

    /// Same-hotkey toggle: start a session, or dismiss the current one (Circle-to-Search style).
    func toggle() {
        if isActive {
            cancel()
        } else {
            begin()
        }
    }

    private func start() async {
        FloatingPanelController.shared.close()   // clear any prior result card
        guard permissions.hasScreenRecording else {
            // First attempt: show only the system prompt. If it was already shown before and the
            // user still hasn't granted, surface the deep-link alert instead of double-prompting.
            let alreadyAsked = permissions.hasRequestedOnce
            permissions.requestScreenRecording()
            if alreadyAsked { presentPermissionAlert() }
            return
        }
        do {
            shots = try await ScreenCaptureService.captureAllDisplays()
        } catch {
            Log.capture.error("Capture failed: \(error.localizedDescription, privacy: .public)")
            presentPermissionAlert()
            return
        }
        guard !shots.isEmpty else { return }
        isActive = true
        // Refresh vision availability in the background (don't block the overlay) so the bar greys
        // the right pills — and picks up Ollama having just come up.
        if let intelligence { Task { await intelligence.refreshVisionAvailability() } }
        KeyboardShortcuts.enable(.cancelCapture)
        presentOverlays()
        installKeyMonitor()
    }

    func cancel() { teardown() }

    /// Leave inline-translation mode and return to the action bar.
    func exitTranslate() { translating = false }

    /// The current selection in global screen (AppKit, bottom-left origin) coordinates — used to
    /// anchor the floating image-search card at the same spot the result pane would appear.
    func activeSelectionScreenRect() -> CGRect? {
        guard let id = activeDisplayID, let rect = committedRect,
              let shot = shots.first(where: { $0.id == id }) else { return nil }
        let frame = shot.frame   // global, bottom-left origin
        return CGRect(x: frame.minX + rect.minX,
                      y: frame.maxY - rect.maxY,
                      width: rect.width,
                      height: rect.height)
    }

    private func teardown() {
        KeyboardShortcuts.disable(.cancelCapture)
        runTask?.cancel(); runTask = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        overlayWindows.forEach { $0.orderOut(nil) }
        overlayWindows.removeAll()
        shots.removeAll()
        activeDisplayID = nil
        committedRect = nil
        context = nil
        actions = []
        translating = false
        panelDragOffset = .zero
        pretranslated = [:]
        pretranslatedTarget = nil
        pretranslatedDuration = nil
        isActive = false
    }

    // MARK: - Selection

    func commitSelection(rectInPoints rect: CGRect, displayID: CGDirectDisplayID) {
        guard let shot = shots.first(where: { $0.id == displayID }),
              rect.width >= 4, rect.height >= 4 else { return }
        activeDisplayID = displayID
        committedRect = rect
        panelDragOffset = .zero
        pretranslated = [:]
        pretranslatedTarget = nil
        pretranslatedDuration = nil

        let pixelRect = CGRect(x: rect.minX * shot.scale, y: rect.minY * shot.scale,
                               width: rect.width * shot.scale, height: rect.height * shot.scale)
        guard let crop = shot.image.cropping(toPixelRect: pixelRect) else { return }

        let base = CaptureContext(image: crop, fullFrame: shot.image,
                                  selectionRect: rect, displayID: displayID)
        context = base
        actions = registry?.relevantActions(for: base) ?? []   // show immediately
        // Warm the local vision model now (while the user reads the toolbar) so Identify is snappy.
        if actions.contains(where: { $0 is IdentifyAction }) { intelligence?.prewarmVision() }
        Task { await runPrePass(crop: crop, base: base) }
    }

    private func runPrePass(crop: CGImage, base: CaptureContext) async {
        let ocrResult = (try? await ocr.recognize(crop)) ?? .empty
        let bars = (try? await barcode.detect(in: crop)) ?? []
        let detected = await dataDetector.detect(in: ocrResult.text)

        var ctx = base
        ctx.ocrText = ocrResult.isEmpty ? nil : ocrResult.text
        ctx.ocrLines = ocrResult.lines
        ctx.detectedData = detected + bars
        context = ctx
        actions = registry?.relevantActions(for: ctx) ?? []
        Log.capture.debug("Pre-pass: \(ocrResult.lines.count) OCR lines, \(ctx.detectedData.count) items")
    }

    // MARK: - Running actions

    func run(_ action: any CaptureAction) {
        guard let ctx = context else { return }
        // Anchor for the floating result, captured before we tear down the overlay.
        let anchor = activeSelectionScreenRect()
        runTask = Task {
            do {
                let outcome = try await action.perform(ctx)
                switch outcome {
                case .text, .stream, .custom:
                    // We have the data — drop the freeze and float the result (persists; Esc/✕ to close).
                    FloatingPanelController.shared.present(
                        AnyView(FloatingResultView(title: action.title, result: outcome)), anchor: anchor)
                    teardown()
                case .inlineTranslate:
                    translating = true   // needs the frozen image; stays in the overlay
                case .copiedToPasteboard, .openedURL, .none:
                    teardown()
                }
            } catch {
                FloatingPanelController.shared.present(
                    AnyView(FloatingResultView(title: action.title,
                                               result: .text("Error: \(error.localizedDescription)"))),
                    anchor: anchor)
                teardown()
            }
        }
    }

    func open(_ item: DetectedItem) {
        if let url = item.url { NSWorkspace.shared.open(url) }
        else { Pasteboard.copy(item.value) }
        teardown()
    }

    // MARK: - Quick crop actions (Send-to)

    func copyImageAndClose() {
        if let crop = context?.image { Pasteboard.copy(crop) }
        teardown()
    }

    func saveImageAndClose() {
        guard let crop = context?.image else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "Lasso \(Self.timestamp()).png"
        panel.begin { [weak self] response in
            if response == .OK, let url = panel.url {
                let rep = NSBitmapImageRep(cgImage: crop)
                if let data = rep.representation(using: .png, properties: [:]) {
                    try? data.write(to: url)
                }
            }
            self?.teardown()
        }
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return f.string(from: Date())
    }

    // MARK: - Windows & input

    private func presentOverlays() {
        NSApp.activate(ignoringOtherApps: true)
        for shot in shots {
            let window = OverlayWindow(shot: shot, coordinator: self)
            overlayWindows.append(window)
            window.orderFront(nil)
        }
        // Make the primary display's overlay the key window so keyboard events (Esc) are delivered.
        if let key = overlayWindows.first {
            key.makeKeyAndOrderFront(nil)
            key.makeFirstResponder(key.contentView)
        }
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 { // Esc
                self.cancel()
                return nil
            }
            return event
        }
    }

    private func presentPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "Screen Recording permission needed"
        alert.informativeText = """
        Lasso needs Screen Recording access to capture your screen. \
        Enable it in System Settings → Privacy & Security → Screen Recording, then try again.
        """
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            permissions.openScreenRecordingSettings()
        }
    }
}
