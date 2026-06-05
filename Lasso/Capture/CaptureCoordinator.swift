import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Transient presentation state for the ResultPane.
struct ResultState {
    var visible = false
    var title = ""
    var text = ""
    var error: String?
    var isStreaming = false
    var custom: AnyView?
    var note: String?

    static var hidden: ResultState { ResultState() }
}

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
    var result = ResultState.hidden

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
        presentOverlays()
        installKeyMonitor()
    }

    func cancel() { teardown() }

    private func teardown() {
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
        result = .hidden
        isActive = false
    }

    // MARK: - Selection

    func commitSelection(rectInPoints rect: CGRect, displayID: CGDirectDisplayID) {
        guard let shot = shots.first(where: { $0.id == displayID }),
              rect.width >= 4, rect.height >= 4 else { return }
        activeDisplayID = displayID
        committedRect = rect
        result = .hidden

        let pixelRect = CGRect(x: rect.minX * shot.scale, y: rect.minY * shot.scale,
                               width: rect.width * shot.scale, height: rect.height * shot.scale)
        guard let crop = shot.image.cropping(toPixelRect: pixelRect) else { return }

        let base = CaptureContext(image: crop, fullFrame: shot.image,
                                  selectionRect: rect, displayID: displayID)
        context = base
        actions = registry?.relevantActions(for: base) ?? []   // show immediately
        Task { await runPrePass(crop: crop, base: base) }
    }

    private func runPrePass(crop: CGImage, base: CaptureContext) async {
        let ocrResult = (try? await ocr.recognize(crop)) ?? .empty
        let bars = (try? await barcode.detect(in: crop)) ?? []
        let detected = await dataDetector.detect(in: ocrResult.text)

        var ctx = base
        ctx.ocrText = ocrResult.isEmpty ? nil : ocrResult.text
        ctx.detectedData = detected + bars
        context = ctx
        actions = registry?.relevantActions(for: ctx) ?? []
        Log.capture.debug("Pre-pass: \(ocrResult.lines.count) OCR lines, \(ctx.detectedData.count) items")
    }

    // MARK: - Running actions

    func run(_ action: any CaptureAction) {
        guard let ctx = context else { return }
        runTask?.cancel()
        result = ResultState(visible: true, title: action.title, isStreaming: true)
        runTask = Task {
            do {
                let outcome = try await action.perform(ctx)
                switch outcome {
                case .text(let t):
                    result.text = t; result.isStreaming = false
                case .stream(let stream):
                    for try await delta in stream {
                        if Task.isCancelled { break }
                        result.text += delta
                    }
                    result.isStreaming = false
                case .copiedToPasteboard:
                    // Copy is "grab and go" — dismiss so the user can paste immediately.
                    teardown()
                case .openedURL:
                    // Opening a link navigates away; get out of the way.
                    teardown()
                case .custom(let view):
                    result.custom = view; result.isStreaming = false
                case .none:
                    result = .hidden
                }
            } catch {
                result.error = error.localizedDescription
                result.isStreaming = false
            }
        }
    }

    func open(_ item: DetectedItem) {
        guard let url = item.url else {
            Pasteboard.copy(item.value)
            result = ResultState(visible: true, title: "Copied", text: item.value, note: "Copied")
            return
        }
        NSWorkspace.shared.open(url)
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
