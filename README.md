# Lasso

Lasso is a little menu-bar app for Apple Silicon Macs. Hit a hotkey, the screen freezes, you drag a
box around anything on it, and a small toolbar pops up with things you can do — copy the text,
translate it, ask an AI about it, figure out what an object is, scan a QR code, grab a color.

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
  runs a local vision model, reverse-image search (TinEye), and a few web sources (Wikipedia,
  DuckDuckGo, Reddit), then writes a short, sourced answer with a confidence rating. Repeat lookups
  of the same thing are instant and free (cached).
- **Scan QR / barcodes** — codes get detected automatically; tap to open the link.
- **Pick a color** — sample any pixel and copy the value.

Press the hotkey again (or Esc) to dismiss. Results float in their own little window, so you can
alt-tab away, open a link, and come back to them.

## Privacy

This is the whole point. Out of the box, everything runs on your Mac:

- Text, summaries, and answers use **Apple Intelligence** (on-device) by default.
- The Identify vision model and search ranking run locally via **Ollama**.
- The only thing that ever leaves your Mac is the optional **web lookup** in Identify, and it's
  off until you turn it on.

If you *want* to use a cloud model, you can — but you have to opt in (see below). API keys are stored
in the macOS **Keychain**, not in a plist.

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
  auto-detects it. Still 100% on your Mac. Good if you want a bigger/different local model.
- **OpenAI-compatible** — OpenAI, Groq, OpenRouter, or any custom base URL. Paste a key, pick a model.
- **Anthropic** — Claude, via your API key.

For Identify's vision, a multimodal cloud model (e.g. `gpt-4o`) is used when you've selected a cloud
provider; otherwise it uses a local Ollama vision model like `qwen3-vl:2b`.

Everything in Settings is staged and applied with one **Save & Apply** button.

## Build it yourself

You'll need an Apple Silicon Mac on **macOS 26+**, **Xcode 26+**, and
[XcodeGen](https://github.com/yonyz/XcodeGen) (`brew install xcodegen`). The Xcode project is
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
actor. The AI side sits behind an `IntelligenceProvider` protocol so providers (Apple, Ollama,
OpenAI-compatible, Anthropic) are interchangeable. There's a fuller writeup in
[`Lasso-macOS-Spec.md`](Lasso-macOS-Spec.md).

## Good to know

- It's **not notarized**, so first-launch needs the right-click-Open dance. A notarized build would
  need a paid Apple Developer account.
- **Reverse-image search** uses TinEye in a hidden web view (the only way to do it without a paid
  API). It's opt-in and best-effort.
- **Apple Intelligence** has to be enabled on your Mac for the on-device path; if it's off, AI
  actions fall back to Ollama (if it's running) while OCR, translate, and the rest keep working.
- DRM/protected windows (Netflix, some banking apps) capture as blank by design — Lasso doesn't try
  to get around that.
