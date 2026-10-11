# Lasso — macOS Screen Search Spec

> Working title: **Lasso** (placeholder — rename freely). A native, on-device screen-intelligence tool for Apple Silicon Macs. Trigger from a global hotkey or a status-bar icon, freeze the screen, select any region (rectangle or freeform), and act on it: OCR, translate, ask AI, identify, extract links/numbers, scan QR, pick colors, and more. Fast, light, fully local by default.

---

## 0. Target environment (hard constraints)

| Item | Requirement |
|---|---|
| Hardware | Apple Silicon (M1 or later) |
| OS | macOS 26 (Tahoe) or later |
| Toolchain | Xcode 26+, Swift 6 (strict concurrency) |
| AI | Apple Intelligence enabled (for Foundation Models). App must degrade gracefully when unavailable. |
| App type | Menu-bar **agent** app (`LSUIElement` / `.accessory` activation policy). No Dock icon by default. |
| Distribution | Developer ID signed + notarized for direct distribution; sandboxing is **optional** here because Screen Recording + global hotkeys are easier outside the App Store sandbox. Decide early (see §13). |

**Design north star:** capture-to-overlay in <100 ms, OCR on a typical region in <300 ms, zero network calls unless the user explicitly invokes a cloud feature.

---

## 1. Native frameworks (no third-party needed for core)

| Capability | Framework / API | Notes |
|---|---|---|
| Screenshot capture | **ScreenCaptureKit** — `SCShareableContent`, `SCScreenshotManager.captureImage(...)` | Modern, fast, sanctioned. One-shot full-display capture, then crop to selection. Requires Screen Recording (TCC) permission. |
| OCR | **Vision** — `RecognizeTextRequest` (Swift) / `VNRecognizeTextRequest` | On-device, `.accurate` level, automatic language detection. **Enable Traditional Chinese + English**. |
| Data detection (links, phones, addresses, dates) | **`NSDataDetector`** on OCR output | Lightweight, no extra deps. Powers the "action pills". VisionKit `ImageAnalysis` is an optional upgrade. |
| Subject lift / tap-an-object | **Vision** — `GenerateForegroundInstanceMaskRequest`; or VisionKit `ImageAnalysisInteraction.subjects` | Auto-crop a single object from the frozen frame ("point-and-tap selector"). |
| Barcode / QR | **Vision** — `DetectBarcodesRequest` / `VNDetectBarcodesRequest` | Returns payload + bounding box → tap-to-open pill. |
| Translation | **Translation** framework — `TranslationSession` | On-device, offline-capable. Overlay translated text in place. |
| On-device reasoning | **FoundationModels** — `SystemLanguageModel`, `LanguageModelSession`, `@Generable`, Tool calling | Summarize, rewrite, explain, extract structured data, classify. **Not** a world-knowledge engine. |
| Global hotkey | **Carbon** `RegisterEventHotKey` OR the `KeyboardShortcuts` SPM package | `KeyboardShortcuts` (Sindre Sorhus) gives a recorder UI for free; Carbon is the zero-dependency fallback. |
| Menu bar | SwiftUI **`MenuBarExtra`** (+ `NSStatusItem` if finer control needed) | |
| Color sampling | `NSColorSampler` (system eyedropper) or sample pixels from the frozen `CGImage` | For the dev-focused color-picker feature. |

**Only candidate third-party dependency:** `KeyboardShortcuts` (SPM). Everything else is first-party Apple. Keep the dependency graph near-zero for "light and fast".

---

## 2. Feature matrix — honest feasibility

✅ native & straightforward · 🟡 native but non-trivial · 🔶 needs hybrid/cloud or has a real limitation

| Feature | Lasso implementation | Status |
|---|---|---|
| Hotkey / button trigger | Global hotkey + menu-bar click | ✅ |
| Freeze screen + select region | Frozen full-screen capture + overlay selection | ✅ |
| Rectangle select | Drag rectangle on overlay | ✅ |
| Freeform "circle"/scribble select | Lasso path → bounding mask → crop | 🟡 |
| Tap an object to auto-crop | `GenerateForegroundInstanceMaskRequest` subject lift | 🟡 |
| Text highlight / OCR | Vision text recognition over the crop | ✅ |
| Copy text from anywhere on screen | OCR of rendered pixels | ✅ (see note ⚠️) |
| Translate text / continuous translate | `TranslationSession`, re-run on new capture | ✅ |
| Action pills: links, phone, address | `NSDataDetector` → tappable pills (open URL, FaceTime/Maps) | ✅ |
| QR / barcode → open link | `DetectBarcodesRequest` | ✅ |
| Music / song ID | ShazamKit (`SHManagedSession`) from mic / system audio | 🟡 (separate audio path) |
| AI Overview / "ask about this" | Foundation Models for summarize/explain/rewrite/extract | ✅ (local-knowledge tasks) |
| World-knowledge Q ("what fish is this?") | Hybrid: tool-call to web search or cloud model | 🔶 |
| Multi-object identify in one image | Subject masks → per-subject pipeline; world ID still 🔶 | 🔶 |
| "Find the look" / shopping / virtual try-on | No native reverse-image/shopping API | 🔶 (hand off to web, or skip) |
| Reverse image search | No native API; open crop in a web reverse-image service | 🔶 |
| AI-generated image detection (SynthID/C2PA) | No public Apple API to read SynthID | 🔶 (out of scope) |

⚠️ **OCR vs. secured content:** Lasso reads *rendered pixels*, like the system screenshot tool. It does **not** bypass copy protection. Windows/displays that set capture-protection (DRM video, some banking apps via `NSWindowSharingNone`) will appear blank in the capture. This is correct, expected behavior — do not try to defeat it.

---

## 3. Architecture overview

Event-driven, single long-lived agent process. Heavy frameworks (Vision, FoundationModels, Translation) are **lazy-loaded** on first use to keep launch fast and idle memory low.

```
┌──────────────────────────────────────────────────────────┐
│ LassoApp (SwiftUI App, .accessory policy, LSUIElement)     │
│                                                            │
│  ┌────────────┐   ┌──────────────┐   ┌─────────────────┐   │
│  │ TriggerSvc │   │ MenuBarExtra │   │ PermissionsSvc  │   │
│  │ (hotkey)   │   │ (status item)│   │ (TCC checks)    │   │
│  └─────┬──────┘   └──────┬───────┘   └─────────────────┘   │
│        └──────────┬──────┘                                 │
│                   ▼                                         │
│           ┌───────────────┐                                │
│           │ CaptureCoord  │  orchestrates one session       │
│           └──────┬────────┘                                │
│      ┌───────────┼───────────────┬──────────────┐          │
│      ▼           ▼               ▼              ▼          │
│ ┌─────────┐ ┌──────────┐  ┌────────────┐  ┌────────────┐   │
│ │ScreenCap│ │ Overlay  │  │ ActionBar  │  │ ResultPane │   │
│ │(SCKit)  │ │Window(s) │  │ (pills)    │  │ (AI/trans) │   │
│ └─────────┘ └──────────┘  └─────┬──────┘  └─────┬──────┘   │
│                                  ▼               ▼          │
│                         ┌──────────────────────────────┐   │
│                         │      CaptureAction Registry   │   │
│                         │  (extensible plugin system)   │   │
│                         └───────────────┬──────────────┘   │
│        ┌───────────────────┬────────────┼──────────────┐   │
│        ▼                   ▼            ▼              ▼   │
│  ┌──────────┐      ┌─────────────┐ ┌───────────┐ ┌────────┐│
│  │ OCREngine│      │ Intelligence│ │ Translate │ │ Barcode││
│  │ (Vision) │      │ Provider(s) │ │ Engine    │ │ Engine ││
│  └──────────┘      └──────┬──────┘ └───────────┘ └────────┘│
│                    ┌──────┴────────────┐                   │
│                    ▼                   ▼                   │
│            ┌───────────────┐   ┌────────────────┐          │
│            │ OnDeviceLLM   │   │ CloudProvider  │ (optional)│
│            │ (FoundationM) │   │ (Claude API…)  │          │
│            └───────────────┘   └────────────────┘          │
└──────────────────────────────────────────────────────────┘
```

**Concurrency model:** Swift 6 strict concurrency. Engines are `actor`s (OCR, Intelligence, Translate) so capture/UI stays on `@MainActor` and heavy work is isolated. Pass `CGImage`/`Data` across boundaries, never retain large buffers longer than a session.

---

## 4. The extensibility contract (this is what makes "room for new features" cheap)

Every capability is a `CaptureAction`. Adding a feature = add one file conforming to the protocol and register it. The ActionBar renders whatever is registered and relevant to the current selection.

```swift
struct CaptureContext {
    let image: CGImage          // cropped selection
    let fullFrame: CGImage      // whole frozen screen (for re-selection)
    let selectionRect: CGRect   // in screen coords
    let ocrText: String?        // populated by OCREngine if already run
    let detectedData: [DetectedItem]  // links, phones, etc.
    let displayID: CGDirectDisplayID
}

protocol CaptureAction: Identifiable, Sendable {
    var id: String { get }
    var title: String { get }
    var systemImage: String { get }            // SF Symbol
    /// Is this action useful for the current selection? (e.g. QR only if a code is present)
    func isRelevant(to ctx: CaptureContext) -> Bool
    /// Run it. Returns a view to show in ResultPane, or performs a side effect.
    func perform(_ ctx: CaptureContext) async throws -> ActionResult
}

enum ActionResult {
    case text(String)                 // show in ResultPane
    case stream(AsyncThrowingStream<String, Error>)  // streamed AI output
    case copiedToPasteboard
    case openedURL(URL)
    case custom(AnyView)
}
```

`ActionRegistry` holds an ordered `[CaptureAction]`. The ActionBar shows `isRelevant` actions as pills, scored/ordered by relevance. New feature → new `CaptureAction` → `registry.register(...)`. Done.

---

## 5. Trigger + menu bar

- **Hotkey:** default `⌥⌘Space` (configurable). Register on launch; expose a recorder in Settings.
- **Menu bar:** `MenuBarExtra` with: *Capture now*, *Capture last region*, *Continuous translate*, *Settings…*, *Quit*. Left-click = capture; the menu is the right-click/secondary surface.
- App launches as `.accessory` (no Dock icon, no menu bar app menu). Provide a setting to show a Dock icon if the user wants.
- **Launch at login:** `SMAppService.mainApp.register()`.

```swift
// KeyboardShortcuts approach
import KeyboardShortcuts
extension KeyboardShortcuts.Name { static let capture = Self("capture", default: .init(.space, modifiers: [.option, .command])) }
KeyboardShortcuts.onKeyUp(for: .capture) { CaptureCoordinator.shared.begin() }
```

---

## 6. Capture + overlay (the core UX)

**Flow ("freeze the screen"):**
1. Hotkey fires → `CaptureCoordinator.begin()`.
2. Immediately capture **all displays** via `SCScreenshotManager` into `CGImage`s (one per display). This is the freeze.
3. For each display, show a borderless transparent `NSWindow` at `.screenSaver` level, full-screen, presenting its frozen image as the backdrop, dimmed slightly.
4. User selects:
   - **Rectangle:** click-drag (default, like ⇧⌘4).
   - **Freeform lasso:** hold a modifier (e.g. ⌥) and draw a path → close path → mask → bounding crop.
   - **Tap object:** single click on a subject → run subject-lift mask → crop to that subject.
5. On commit, crop the frozen `CGImage` to the selection → build `CaptureContext`.
6. Run a fast **pre-pass**: OCR + `NSDataDetector` + barcode detect (these are cheap and let the ActionBar pick relevant pills instantly).
7. Show the **ActionBar** anchored near the selection; **ResultPane** appears when an action produces output.
8. `Esc` dismisses everything; nothing persists unless the user saves/copies.

```swift
// ScreenCaptureKit one-shot
let content = try await SCShareableContent.current
guard let display = content.displays.first(where: { $0.displayID == targetID }) else { return }
let filter = SCContentFilter(display: display, excludingWindows: [])
let cfg = SCStreamConfiguration()
cfg.width = display.width * scaleFactor   // capture at native retina resolution
cfg.height = display.height * scaleFactor
let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
```

**Multi-monitor:** create one overlay window per `NSScreen`; selection can start on any display. Map points using each display's frame + backing scale factor.

**Performance:** capture happens before the overlay is shown, off the main actor; the overlay just blits an already-decoded image. Target <100 ms from keypress to visible frozen overlay.

---

## 7. OCR engine

```swift
actor OCREngine {
    func recognize(_ image: CGImage,
                   languages: [String] = ["zh-Hant", "en-US"]) async throws -> OCRResult {
        var request = RecognizeTextRequest()           // Vision Swift API (macOS 15+)
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = languages.map { Locale.Language(identifier: $0) }
        let observations = try await request.perform(on: image)
        // Join lines preserving reading order; keep per-line bounding boxes for highlight UI
        return OCRResult(text: ..., lines: ...)
    }
}
```

- Auto-detect script; default to `zh-Hant` + `en`, user-configurable list in Settings.
- Keep bounding boxes so the UI can highlight matched text and let users select sub-ranges.
- Expose `copyText`, `copyAsMarkdown` (preserve line breaks), and feed `text` into AI/translate actions.

---

## 8. Intelligence layer (hybrid by design)

A protocol so on-device is default and cloud is an opt-in plugin. This is where your "always room for new features" lives, and it covers the world-knowledge gap.

```swift
protocol IntelligenceProvider: Sendable {
    var name: String { get }
    var isLocal: Bool { get }
    var isAvailable: Bool { get async }
    func respond(prompt: String, context: String?) -> AsyncThrowingStream<String, Error>
    func generate<T: Generable>(_ type: T.Type, prompt: String, context: String?) async throws -> T
}
```

**Default — `OnDeviceProvider` (FoundationModels):**

```swift
import FoundationModels
let model = SystemLanguageModel.default
guard case .available = model.availability else { /* show "Apple Intelligence off" */ return }
let session = LanguageModelSession(instructions: "You summarize and transform on-screen text. Be concise.")
for try await chunk in session.streamResponse(to: prompt) { /* stream into ResultPane */ }
```

Use cases that run **100% local**: summarize selection, explain code, rewrite/fix grammar, extract structured data (`@Generable`), classify, list action items, simplify, change tone. These are the model's strengths.

**Optional — `CloudProvider`:** for world knowledge, reverse-image, "what is this", multi-object identification. Pluggable backend (Anthropic API, etc.). Off by default; gated behind an explicit toggle + per-call confirmation so the "no network unless asked" promise holds. Surface a clear "↗ sent to cloud" indicator when used.

**Tool calling:** register a `webSearch` tool with the on-device session so it can decide when a query needs external facts and route to the cloud/web provider — best of both worlds without sending everything off-device.

**Guided generation example** (structured action pills from a selection):

```swift
@Generable struct ScreenInsight {
    @Guide(description: "One-sentence summary of the selection") let summary: String
    @Guide(description: "Suggested next actions, max 3") let actions: [String]
    @Guide(.anyOf(["text","code","table","ui","photo","chart","mixed"])) let kind: String
}
```

---

## 9. Translation

- `TranslationSession` for on-device translation of the OCR'd text.
- **Inline overlay mode:** draw translated strings over the original line bounding boxes ("translate in place").
- **Continuous translate:** re-capture + re-OCR + re-translate on an interval or on scroll; reuse the warm session.
- Source language auto-detected; target defaults to system locale, configurable.

---

## 10. Action pills (from `NSDataDetector` + barcode)

| Detected | Pill | Action |
|---|---|---|
| URL | "Open link" | `NSWorkspace.open` |
| Phone | "Call / Copy" | `tel:` / FaceTime / copy |
| Email | "Email" | `mailto:` |
| Address | "Maps" | open in Maps |
| Date/event | "Add to Calendar" | EventKit draft |
| QR / barcode | "Open / Copy payload" | parse payload type |
| Color (eyedropper mode) | "Copy hex/RGB" | pasteboard |

Pills only appear when relevant (`isRelevant`), so the bar stays clean.

---

## 11. Proposed *new* features (dev-focused, low effort, high delight)

These build on the fact that the user base skews technical and that you have a frozen high-res image + OCR + local LLM already in hand:

1. **Color picker / eyedropper** — sample any pixel, copy hex/RGB/HSL/SwiftUI `Color(...)`. Trivial given the frozen `CGImage`.
2. **Explain code** — OCR a code region → on-device LLM explains / adds comments / spots bugs. Fully local.
3. **Math/equation solve** — OCR an equation → solve + show steps.
4. **"Explain this screen"** — summarize an entire error dialog, log, or dense UI in one keypress.
5. **Extract table → CSV/Markdown** — OCR a table region → guided generation into structured rows → copy as CSV/MD.
6. **Capture history** — last N captures held in memory (and optionally a session log), re-actionable. Cleared on quit by default (privacy).
7. **Pixel ruler / measure** — measure distances/sizes on the frozen frame (handy for UI work).
8. **Send-to** — save crop as PNG, drop into Notes/Reminders, or copy to clipboard with one pill.
9. **Mixed-script OCR cleanup** — auto-detect zh-Hant/en mix and let the local LLM normalize spacing/punctuation .
10. **Privacy indicator** — a persistent badge showing "all local" vs "cloud used this session".

Each is a `CaptureAction` file. Ship 1–3 in MVP, leave the rest as registry additions.

---

## 12. Suggested project structure

```
Lasso/
├─ Lasso.xcodeproj
├─ Lasso/
│  ├─ App/
│  │  ├─ LassoApp.swift            // @main, .accessory policy, MenuBarExtra
│  │  ├─ AppDelegate.swift         // login item, lifecycle
│  │  └─ Settings/SettingsView.swift
│  ├─ Trigger/
│  │  ├─ TriggerService.swift      // hotkey registration
│  │  └─ MenuBarController.swift
│  ├─ Capture/
│  │  ├─ CaptureCoordinator.swift  // session orchestration (@MainActor)
│  │  ├─ ScreenCaptureService.swift// ScreenCaptureKit
│  │  ├─ OverlayWindow.swift       // borderless transparent NSWindow
│  │  ├─ SelectionView.swift       // rect + lasso + tap-object
│  │  └─ SubjectLift.swift         // Vision foreground mask
│  ├─ Engines/
│  │  ├─ OCREngine.swift           // actor, Vision
│  │  ├─ TranslateEngine.swift     // actor, Translation
│  │  ├─ BarcodeEngine.swift       // Vision barcodes
│  │  └─ DataDetector.swift        // NSDataDetector wrapper
│  ├─ Intelligence/
│  │  ├─ IntelligenceProvider.swift
│  │  ├─ OnDeviceProvider.swift    // FoundationModels
│  │  ├─ CloudProvider.swift       // optional, pluggable
│  │  └─ Tools/WebSearchTool.swift
│  ├─ Actions/
│  │  ├─ CaptureAction.swift       // protocol + ActionResult
│  │  ├─ ActionRegistry.swift
│  │  ├─ OCRCopyAction.swift
│  │  ├─ TranslateAction.swift
│  │  ├─ AskAIAction.swift
│  │  ├─ SummarizeAction.swift
│  │  ├─ QRAction.swift
│  │  ├─ ColorPickerAction.swift
│  │  └─ ... (one file per feature)
│  ├─ UI/
│  │  ├─ ActionBar.swift           // floating pill bar
│  │  ├─ ResultPane.swift          // streamed results
│  │  └─ Theme.swift
│  ├─ Permissions/PermissionsService.swift  // Screen Recording, Accessibility
│  └─ Support/{Logging, Pasteboard, Extensions}.swift
└─ LassoTests/
```

---

## 13. Permissions & entitlements

- **Screen Recording** (TCC) — required for ScreenCaptureKit. On first run, detect denial and deep-link to System Settings → Privacy & Security → Screen Recording. Re-check on each capture.
- **Accessibility** — only if you later add window-targeting beyond plain capture; not needed for MVP.
- **Microphone** — only if Shazam/song-ID is built.
- **Sandbox decision:** global hotkeys (Carbon) + Screen Recording work most smoothly **outside** the App Store sandbox, distributed via Developer ID + notarization. If App Store is a goal later, expect extra entitlement work. **Recommend: Developer ID, non-sandboxed, for v1.**
- `Info.plist`: `LSUIElement = YES`. Usage strings for any permission requested.

---

## 14. Performance budget

| Stage | Target |
|---|---|
| Keypress → frozen overlay visible | < 100 ms |
| Region commit → action bar shown | < 50 ms |
| OCR (typical paragraph) | < 300 ms |
| On-device LLM first token | < 700 ms |
| Idle memory (agent, engines unloaded) | < 60 MB |
| Peak memory during capture+OCR | keep crops downscaled; release `CGImage`s at session end |

Rules: lazy-init every engine; never block `@MainActor` on Vision/FM; downscale crops before OCR if larger than needed; one warm `LanguageModelSession` reused across actions; tear down the session/images on `Esc`.

---

## 15. Build roadmap (phased milestones)

**M0 — Skeleton:** Agent app, `MenuBarExtra`, global hotkey, Settings shell, login item. Hotkey just logs.

**M1 — Capture + select:** ScreenCaptureKit freeze (multi-display), overlay window, rectangle selection, crop → save PNG / copy to clipboard. Permissions flow. *Usable screenshot tool at this point.*

**M2 — OCR + pills:** Vision OCR, copy text, `NSDataDetector` action pills (link/phone/address), barcode/QR. ActionBar + ResultPane + the `CaptureAction` registry.

**M3 — On-device intelligence:** FoundationModels provider; Summarize, Explain, Ask (local) actions with streaming. Availability handling for non-Apple-Intelligence machines.

**M4 — Translation:** `TranslationSession`, inline overlay translation, continuous mode.

**M5 — Advanced selection:** freeform lasso + tap-to-lift-subject (Vision foreground mask).

**M6 — Hybrid cloud (optional):** `CloudProvider` + `webSearch` tool for world-knowledge / reverse-image; explicit opt-in + "cloud used" indicator.

**M7 — Delight features:** color picker, table→CSV, capture history, math solve, etc. (pure registry additions).

---

## 16. Decisions to lock before coding

1. **Sandbox/distribution:** Developer ID non-sandboxed (recommended) vs App Store?
2. **Hotkey dependency:** allow the `KeyboardShortcuts` SPM package, or pure Carbon (zero deps)?
3. **Default hotkey** combo.
4. **Cloud provider:** include the optional `CloudProvider` in v1, or stub the protocol and defer? If included, which backend (Anthropic API)?
5. **OCR languages** default set (proposed: zh-Hant + en).
6. **MVP feature cut** — which of §11 ship in v1 vs later.

---

## 17. Known limitations (state these in the README so expectations are set)

- No reverse-image search, shopping, "find the look", or virtual try-on — no native macOS API; only achievable by handing the crop to a web service.
- No SynthID/C2PA AI-image detection — no public Apple API to read those signals.
- Capture-protected windows (DRM video, hardened banking apps) will capture as blank. Lasso does not and should not circumvent this.
- On-device LLM is a feature engine, not an encyclopedia — world-knowledge answers require the optional hybrid path.
- Foundation Models requires Apple Intelligence enabled; on machines without it, AI actions are hidden/disabled while OCR/translate/pills still work.
