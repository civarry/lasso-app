# Lasso

On-device screen search for Apple Silicon Macs. Trigger a global hotkey, freeze the screen,
select any region, and act on it: OCR, translate, ask AI, scan QR, pick colors — fast, light, and
local by default.

See [`Lasso-macOS-Spec.md`](Lasso-macOS-Spec.md) for the full design.

## Requirements

- Apple Silicon Mac, **macOS 26 (Tahoe)** or later
- **Xcode 26+**, Swift 6
- [XcodeGen](https://github.com/yonyz/XcodeGen) (`brew install xcodegen`) — the project is generated
  from `project.yml`; `Lasso.xcodeproj` is not committed
- Optional: [Ollama](https://ollama.com) running locally with a model pulled
  (`ollama pull gpt-oss:20b`) for the "bigger model" AI path

## First-time setup

```sh
# 1. Accept the Xcode license (one-time, requires sudo)
sudo xcodebuild -license accept

# 2. Generate the Xcode project
xcodegen generate

# 3. Build & run
open Lasso.xcodeproj    # ⌘R in Xcode
# or
xcodebuild -scheme Lasso -configuration Debug build
```

On first launch, grant **Screen Recording** in System Settings → Privacy & Security. The default
capture shortcut is **⌥⌘Space** (configurable in Settings).

## Architecture

Every capability is a `CaptureAction` (see `Lasso/Actions/`). Add a feature = add one file
conforming to the protocol and register it in `ActionRegistry`. Engines (OCR, barcode, data
detection) are `actor`s; capture/UI stays on `@MainActor`. See spec §3–§4.

The intelligence layer is pluggable (`IntelligenceProvider`):

- **`OnDeviceProvider`** — Apple Foundation Models, 100% on-device (default).
- **`OllamaProvider`** — your local `gpt-oss:20b` via `http://localhost:11434`. Still on this
  machine; nothing leaves the Mac.

## Status

| Milestone | State |
|---|---|
| M0 — Agent app, menu bar, global hotkey, Settings, login item | ✅ implemented |
| M1 — ScreenCaptureKit freeze, multi-display overlay, rectangle select, crop → copy/save | ✅ implemented |
| M2 — Vision OCR, data-detector pills, QR/barcode, ActionBar + ResultPane | ✅ implemented |
| M3 — On-device intelligence (summarize / ask) | ✅ implemented |
| M4 — Translation (inline overlay, continuous) | 🟡 single-shot via `TranslationResultView`; inline/continuous pending |
| M5 — Freeform lasso + tap-to-lift subject | 🔶 stubbed (`SubjectLift`) |
| M6 — Hybrid cloud / web-search tool | 🔶 stubbed (`WebSearchTool`, disabled) |
| M7 — Delight features (color picker, table→CSV, history, math) | 🟡 color picker shipped; rest are registry additions |

## Known limitations (Spec §17)

- No reverse-image search / shopping / "find the look" — no native macOS API.
- No SynthID/C2PA AI-image detection — no public Apple API.
- Capture-protected windows (DRM video, hardened banking apps) capture as blank by design. Lasso
  does **not** circumvent this.
- The on-device LLM is a feature engine, not an encyclopedia — world-knowledge answers use the
  optional Ollama path.
- Foundation Models requires Apple Intelligence enabled; without it, AI actions fall back to Ollama
  (if running) while OCR / translate / pills still work.
