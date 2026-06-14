# Lasso

Lasso is a little menu-bar app for Apple Silicon Macs. Hit a hotkey, the screen freezes, you drag a
box around anything on it, and a small toolbar pops up with things you can do — copy the text,
translate it, ask an AI about it, figure out what an object is, search it on Google Lens, scan a QR
code, grab a color. There's also a persistent chat panel for follow-up questions.

Think screen search, but native to the Mac and **local by default** — nothing leaves your
machine unless you decide it should.

## What you can do with a selection

- **Copy text** — OCR pulls the words straight out of the image.
- **Translate in place** — foreign text gets overlaid with the translation right where it sits. It
  handles mixed selections too (e.g. Chinese with some English) without garbling the parts that are
  already in your language.
- **Summarize / Ask AI** — get a quick summary, or ask anything about what you selected. If the
  selection is an image with no text, it'll actually *look* at the image to answer.
- **Identify** — point it at an object, product, place, or screenshot and it tells you what it is. It
  runs a local vision model, then writes a short, sourced answer with a confidence rating. You can
  optionally connect web sources (Wikipedia, DuckDuckGo, Reddit) and reverse-image lookup to sharpen
  it. Repeat lookups of the same thing are instant and free (cached).
- **Google Lens** *(optional, opt-in)* — send the selection to Google Lens and see the real visual
  matches (products, landmarks, screenshots, the lot) in a panel right next to it. Off by default
  because it uploads the selection to Google.
- **Scan QR / barcodes** — codes get detected automatically; tap to open the link.
- **Pick a color** — sample any pixel and copy the value.

Press the hotkey again (or Esc) to dismiss. Results float in their own little window, so you can
alt-tab away, open a link, and come back to them.

## Chat

A persistent chat panel lives in the top-right corner (**⌥⌘A** to toggle). It's multi-turn, you can
drop an image straight into it, and you can send a capture into it to keep asking questions. When you
turn on web connectors, it grounds its answers with real sources.

## Shortcuts

- **Capture** — **⌥⌘Space** (changeable in Settings).
- **Chat** — **⌥⌘A**.
- **Direct shortcuts** — assign your own hotkeys to run **Identify** or **Google Lens** instantly,
  skipping the toolbar. Each has a *Selection* variant (drag a box first) and a *Full screen* variant
  (grabs the whole display) — like Google Lens's "Search Specific Area" / "Full Screen Search".

## Privacy

This is the whole point. Out of the box, everything runs on your Mac:

- Text, summaries, and answers use **Apple Intelligence** (on-device) by default.
- The Identify vision model runs locally too (Apple Intelligence, **Ollama**, or **MLX**).
- The only things that ever leave your Mac are the optional **web lookup** in Identify/Chat and the
  optional **Google Lens** action — both off until you turn them on.

There's a **Local-only mode** that blocks every network call except your chosen model — good for
privacy-sensitive setups. If you *want* to use a cloud model, you can, but you have to opt in (see below).
API keys are stored in the macOS **Keychain**, not in a plist.

## Install

1. Grab `Lasso.dmg` from the [Releases](../../releases) page.
2. Open it and drag **Lasso** to Applications.
3. First launch: **right-click the app → Open**. macOS will warn that it can't verify the developer —
   that's expected, the build isn't notarized. After you open it once, it just works.
4. Lasso asks for **Screen Recording** permission (it needs to see the screen to capture it). Grant it
   in System Settings → Privacy & Security, then relaunch.

The capture shortcut defaults to **⌥⌘Space** and is changeable in Settings.

## AI providers

Settings → Intelligence lets you pick where the thinking happens:

- **Apple Intelligence** — on-device, no setup. The default.
- **Ollama** — a local model server. `ollama pull qwen3:4b` (or whatever you like) and Lasso
  auto-detects it. Still 100% on your Mac.
- **MLX** — on-device models that run on Apple Silicon directly. Browse, download, and manage them
  inside Settings; nothing leaves your Mac.
- **OpenAI-compatible** — OpenAI, Groq, OpenRouter, or any custom base URL. Paste a key, pick a model.
- **Anthropic** — Claude, via your API key.

For Identify's vision, you can use the same model as your text engine (if it's multimodal), a local
Ollama/MLX vision model, or a multimodal cloud model when you've selected a cloud provider.

Everything in Settings is staged and applied with one **Save & Apply** button.

## Build it yourself

You'll need an Apple Silicon Mac on **macOS 26+**, **Xcode 26+**, and
[XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`). The Xcode project is
generated from `project.yml` and isn't committed.

```sh
sudo xcodebuild -license accept   # one-time
xcodegen generate
open Lasso.xcodeproj              # then ⌘R
```

To package a DMG:

```sh
xcodebuild -scheme Lasso -configuration Release -derivedDataPath .build build
# then drop Lasso.app + an /Applications symlink into a folder and `hdiutil create`
```

## How it's put together

Each feature is a `CaptureAction` (see `Lasso/Actions/`) — adding one is a single file plus a line in
`ActionRegistry`. OCR, barcode, and data detection run as `actor`s; capture and UI stay on the main
actor. The AI side sits behind an `IntelligenceProvider` protocol so providers (Apple, Ollama, MLX,
OpenAI-compatible, Anthropic) are interchangeable, and optional web/reverse-image **connectors** are a
declarative catalog you can extend with one entry. There's a fuller writeup in
[`Lasso-macOS-Spec.md`](Lasso-macOS-Spec.md).

## Good to know

- It's **not notarized**, so first-launch needs the right-click-Open dance. A notarized build would
  need a paid Apple Developer account.
- **Reverse-image search** in Identify is opt-in and brings your own key (Google Cloud Vision). The
  **Google Lens** action is a separate, keyless way to get real visual matches — also opt-in, since it
  uploads to Google. (Google Lens shows results in whatever language it infers from your region.)
- **Apple Intelligence** has to be enabled on your Mac for the on-device path; if it's off, AI actions
  fall back to a local model (if one's set up) while OCR, translate, and the rest keep working.
- DRM/protected windows (Netflix, some banking apps) capture as blank by design — Lasso doesn't try
  to get around that.
