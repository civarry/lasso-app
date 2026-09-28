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

    /// When set, the session skips the action bar and auto-runs this action's `id` once the selection
    /// (or full-screen grab) and pre-pass are ready — the "direct shortcut" path (e.g. ⇧⌘ → Lens).
    private(set) var pendingDirectActionID: String?

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

    /// Direct shortcut: drag a selection, then auto-run `actionID` (no action bar). Mirrors the normal
    /// selection flow but pre-binds the action.
    func beginDirect(actionID: String) {
        guard !isActive else { return }
        guard passesDirectGate(actionID) else { return }
        pendingDirectActionID = actionID
        begin()
    }

    /// Direct full-screen shortcut: grab the display under the pointer (no drag, no overlay) and
    /// auto-run `actionID` — Findit's "Full Screen Search".
    func beginFullScreen(actionID: String) {
        guard !isActive else { return }
        guard passesDirectGate(actionID) else { return }
        Task { await startFullScreen(actionID: actionID) }
    }

    /// The one place every direct hotkey is checked before a pixel is captured.
    ///
    /// The direct path skips the action bar, and with it `CaptureAction.isRelevant` — which is where
    /// Lens's Google-upload opt-in and local-only mode live. Both entry points funnel through here so
    /// there is exactly one thing to get right (see `DirectActionGate` for the reasoning). Refusals
    /// are shown, never swallowed: a hotkey that silently does nothing reads as a broken binding.
    private func passesDirectGate(_ actionID: String) -> Bool {
        let action = registry?.actions.first { $0.id == actionID }
        let environment = DirectActionGate.Environment(
            knownActionIDs: Set(registry?.actions.map(\.id) ?? []),
            lensEnabled: UserDefaults.standard.bool(forKey: LensSearchAction.enabledKey),
            localOnly: PrivacyMode.localOnly,
            visionAvailable: intelligence?.visionAvailable ?? false,
            textModelConfigured: intelligence?.textModelConfigured ?? false)

        switch DirectActionGate.decide(actionID: actionID, title: action?.title ?? "Lasso",
                                       environment: environment) {
        case .allow:
            return true
        case .refuse(let title, let reason):
            // (shared with the content check in `start()` via `presentRefusal`)
            // `visionAvailable` is a cached value refreshed at launch, after Save, and on capture, so
            // it can lag a model the user has only just installed. Kick a refresh on the way out so a
            // stale "no image model" answers itself by the next keypress instead of sticking.
            if let intelligence { Task { await intelligence.refreshVisionAvailability() } }
            presentRefusal(actionID: actionID, title: title, reason: reason)
            return false
        }
    }

    /// Tell the user why a hotkey did nothing. A refused direct action that stays silent reads as a
    /// broken binding, and the next thing they do is rebind a key that was working.
    private func presentRefusal(actionID: String, title: String, reason: String) {
        Log.capture.notice("Direct action \(actionID, privacy: .public) refused: \(reason, privacy: .public)")
        FloatingPanelController.shared.present(
            AnyView(FloatingResultView(title: title, result: .text(reason))), anchor: nil)
    }

    /// The registered action set, for UI that needs the catalog outside a capture session (Settings'
    /// toolbar list). Empty until `configure(registry:intelligence:)` has run.
    var registeredActions: [any CaptureAction] { registry?.actions ?? [] }

    private func startFullScreen(actionID: String) async {
        FloatingPanelController.shared.close()
        guard permissions.hasScreenRecording else {
            let alreadyAsked = permissions.hasRequestedOnce
            permissions.requestScreenRecording()
            if alreadyAsked { presentPermissionAlert() }
            return
        }
        let grabbed: [DisplayShot]
        do {
            grabbed = try await ScreenCaptureService.captureAllDisplays()
        } catch {
            Log.capture.error("Full-screen capture failed: \(error.localizedDescription, privacy: .public)")
            presentPermissionAlert()
            return
        }
        // The display under the pointer (fall back to the first), captured whole — no selection step.
        let mouse = NSEvent.mouseLocation
        guard let shot = grabbed.first(where: { $0.frame.contains(mouse) }) ?? grabbed.first else { return }

        shots = grabbed
        isActive = true
        activeDisplayID = shot.id
        let rectInPoints = CGRect(x: 0, y: 0,
                                  width: CGFloat(shot.image.width) / shot.scale,
                                  height: CGFloat(shot.image.height) / shot.scale)
        committedRect = rectInPoints
        let base = CaptureContext(image: shot.image, fullFrame: shot.image,
                                  selectionRect: rectInPoints, displayID: shot.id)
        context = base
        if let intelligence { Task { await intelligence.refreshVisionAvailability() } }
        if actionID == "identify" { intelligence?.prewarmVision() }
        pendingDirectActionID = actionID
        await runPrePass(crop: shot.image, base: base)
    }

    private func start() async {
        FloatingPanelController.shared.close()   // clear any prior result card
        // Every early return below leaves without `isActive`, so `teardown()` never runs and a
        // pre-bound direct action would survive into the *next* capture and hijack it (the bar would
        // be suppressed and the old action would run). Most likely on a first run, where the capture
        // fails on the permission prompt. Clear it on the way out, at the one place that can see all
        // three exits.
        var completedStart = false
        defer { if !completedStart { pendingDirectActionID = nil } }
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
        completedStart = true
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
        pendingDirectActionID = nil
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
        // Direct shortcut: keep the bar hidden — the pending action fires when the pre-pass finishes.
        actions = pendingDirectActionID == nil ? (registry?.relevantActions(for: base) ?? []) : []
        // Warm the local vision model now (while the user reads the toolbar) so Identify is snappy.
        if pendingDirectActionID == "identify" || actions.contains(where: { $0 is IdentifyAction }) {
            intelligence?.prewarmVision()
        }
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

        // Direct shortcut: the context is now complete — run the pre-bound action and skip the bar.
        // Leave `pendingDirectActionID` set until teardown so the overlay bar stays hidden for the
        // whole run; clearing it here would flash the bar in the gap before the action tears down.
        if let id = pendingDirectActionID {
            guard let action = registry?.actions.first(where: { $0.id == id }) else { teardown(); return }
            // `passesDirectGate` answered the questions that don't need a selection (privacy, a model
            // being configured). These two need the pre-pass, which has just finished: whether this
            // selection has anything for the action to work on. Without them a hotkey on a picture with
            // no QR code, or no readable text, tears down silently and reads as a dead binding.
            let vision = intelligence?.visionAvailable ?? false
            switch DirectActionGate.contentDecision(
                title: action.title, isRelevant: action.isRelevant(to: ctx),
                disabledReason: action.disabledReason(for: ctx, visionAvailable: vision)) {
            case .allow:
                run(action)
            case .refuse(let title, let reason):
                presentRefusal(actionID: id, title: title, reason: reason)
                teardown()
            }
            return
        }

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
        for shot in shots {
            let window = OverlayWindow(shot: shot, coordinator: self)
            overlayWindows.append(window)
            window.orderFront(nil)
        }
        // Make the primary display's overlay the key (and main) window so keyboard events (Esc) are
        // delivered, then activate: activating first brought an open Settings window forward.
        if let key = overlayWindows.first {
            AppActivation.bringForward(key)
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
        Enable it in System Settings ▸ Privacy & Security ▸ Screen Recording, then try again.
        """
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            permissions.openScreenRecordingSettings()
        }
    }
}
