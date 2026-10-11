<p align="center"><img src="app-icon.png" width="120" alt="Lasso"></p>

# Lasso

<p align="center">
  <a href="../../releases/latest"><img src="https://img.shields.io/github/v/release/civarry/lasso-app?label=latest&color=blue" alt="Latest release"></a>
  <a href="../../releases"><img src="https://img.shields.io/github/downloads/civarry/lasso-app/total?label=downloads&color=brightgreen" alt="Total downloads"></a>
  <img src="https://img.shields.io/badge/macOS-26%2B-lightgrey" alt="Requires macOS 26 or later">
</p>

> [!NOTE]
> **Lasso is now open source.** The full source code lives right here under the [Apache 2.0 license](LICENSE). Download the app from [Releases](../../releases) as before, or [build it yourself](BUILDING.md) on your own Mac, no Apple developer account needed.

Lasso is a little menu-bar app for Apple Silicon Macs. Hit a hotkey, the screen
freezes, you drag a box around anything on it, and a small toolbar pops up with
things you can do — copy the text, translate it, ask an AI about it, figure out
what an object is, scan a QR code, grab a color.

Think screen search, but native to the Mac and **local by default** —
nothing leaves your machine unless you decide it should.

<p align="center"><img src="screenshots/hero.png" alt="Drag a box around anything on screen and translate it in place"></p>

## What you can do with a selection

- **Copy text** — OCR pulls the words straight out of the image.
- **Translate in place** — each paragraph, label and list item gets its
  translation drawn right over it, coloured to match the page. A view mixing
  languages (English and Japanese, say) translates both. Apple's on-device
  translation appears first; an optional AI pass then retranslates the whole
  selection with context, Filipino included.
- **Summarize / Ask AI** — summarize the selection or ask anything about it; if
  it's a textless image, the AI actually looks at the picture.
- **Identify** — point it at an object, product, place, or screenshot and it
  tells you what it is, with sources and a confidence rating.
- **Scan QR / barcodes**, and **pick a color** from any pixel.
- **Search with Lens** — send the selection to Google Lens for a reverse image
  search. Opt-in, and hidden entirely in Local-only mode.

<p align="center"><img src="screenshots/actions.png" alt="The full set of things Lasso can do with a selection"></p>

## Your toolbar, your keys

The toolbar follows the order you set, not what Lasso guesses is relevant, so the
two things you actually use stay where you expect them even when the selection
happens to contain a QR code or a color. Switch an action off and it moves into
the toolbar's "…" menu rather than disappearing.

Every action can also have its own hotkey that starts a capture and runs just
that action, skipping the toolbar entirely. Identify and Google Lens additionally
have a full-screen variant that grabs the whole display. Nothing is bound by
default; you pick the keys in Settings.

## Identify

<p align="center"><img src="screenshots/identify.png" alt="Identify names what you point at and writes a short, sourced answer"></p>

A local vision model names it, then writes a short, sourced answer with a
confidence rating. Repeat lookups are instant.

## Chat

<p align="center"><img src="screenshots/chat.png" alt="A persistent chat panel that remembers the thread and grounds answers with sources"></p>

A persistent chat panel that remembers the thread, takes a dropped image, and
grounds its answers with real sources when you want. Click the mic to talk
instead of typing: English speech recognition on your Mac, with words appearing
as you speak.

## Privacy

Out of the box everything runs on your Mac — text via **Apple Intelligence**,
vision and ranking via a local **Ollama** model. The only things that leave your
Mac are the optional web lookup in Identify and the optional Google Lens search,
and both stay off until you turn them on.
There's a **Local-only mode** that forces a local model and blocks every
incidental network call. Cloud models (OpenAI, Groq, Anthropic, custom) are
supported too, but strictly opt-in; API keys live in the macOS Keychain.

<p align="center"><img src="screenshots/privacy.png" alt="Runs on your Mac — nothing leaves unless you say so"></p>

## Install

1. Download the **`.dmg`** from the [Releases](../../releases) page.
2. Open it and drag **Lasso** to Applications.
3. First launch: open Lasso. macOS says it can't verify the developer, which is
   expected because the build isn't notarized. Click **Done**, then go to System
   Settings → Privacy & Security, click **Open Anyway** next to Lasso, and confirm.
   You only do this once.
4. Grant **Screen Recording** in System Settings → Privacy & Security, then
   relaunch. The capture shortcut defaults to **⌃⇧C** (changeable in Settings).

## Requirements

Apple Silicon Mac on **macOS 26+**. For the local AI paths, install
[Ollama](https://ollama.com) and pull a model or two
(`ollama pull qwen3:4b`, `ollama pull qwen3-vl:2b`). Apple Intelligence works
with no setup.

## AI providers

Pick where the thinking happens in **Settings → Intelligence**:

- **Apple Intelligence**: on your Mac, no setup. The default.
- **Ollama** or **MLX**: local models, still entirely on your Mac. MLX models can be downloaded in
  Settings, or used straight from a folder you already have (`~/models`, LM Studio).
- **Cloud**: any OpenAI-compatible service (OpenAI, Groq, OpenRouter, a custom URL), Google Gemini, or
  Anthropic. Add as many connections as you like; their models all appear in one picker.

**Free-model fallback** (off by default): if your cloud model is rate limited or down, Lasso retries on
a free model from the connections you allow, then on Apple's on-device model. It never runs in
local-only mode. The full rules are in [docs/APP_FLOW.md](docs/APP_FLOW.md).

## Build it yourself

Lasso is open source. Building your own copy needs an Apple Silicon Mac on macOS
26+, Xcode 26+ and XcodeGen, but no Apple developer account, and a copy you build
yourself skips the "can't verify the developer" step entirely. See
[BUILDING.md](BUILDING.md) for the steps.

## How it's put together

Each feature is a `CaptureAction` (see `Lasso/Actions/`) — adding one is a single file plus a line in
`ActionRegistry`. OCR, barcode, and data detection run as `actor`s; capture and UI stay on the main
actor. The AI side sits behind an `IntelligenceProvider` protocol so providers (Apple, Ollama, MLX,
OpenAI-compatible, Anthropic) are interchangeable, and optional web/reverse-image **connectors** are a
declarative catalog you can extend with one entry. There's a fuller writeup in
[`Lasso-macOS-Spec.md`](Lasso-macOS-Spec.md).

## Good to know

- **Reverse-image search** in Identify is opt-in and brings your own key (Google Cloud Vision). The
  **Google Lens** action is a separate, keyless way to get real visual matches — also opt-in, since it
  uploads to Google. (Google Lens shows results in whatever language it infers from your region.)
- **Apple Intelligence** has to be enabled on your Mac for the on-device path; if it's off, AI actions
  fall back to a local model (if one's set up) while OCR, translate, and the rest keep working.
- DRM/protected windows (Netflix, some banking apps) capture as blank by design — Lasso doesn't try
  to get around that.

## License

[Apache License 2.0](LICENSE). Copyright 2026 civarry. If you redistribute Lasso or a modified
version, keep the [NOTICE](NOTICE) file, which credits the original author, and note what you changed.
