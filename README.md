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

A persistent chat panel lives in the top-right corner (**⌃⇧A** to toggle). It's multi-turn, you can
drop an image straight into it, and you can send a capture into it to keep asking questions. When you
turn on web connectors, it grounds its answers with real sources.

Answers are formatted to be read rather than decorated: prose by default, with tables reserved for
things that actually compare, and code in labelled blocks you can copy. Formulas are converted to
real symbols (`√`, `Σ`, `σ`, superscripts) instead of showing raw LaTeX, whichever model wrote them.

## Shortcuts

- **Capture** — **⌃⇧C** (changeable in Settings).
- **Chat** — **⌃⇧A**.
- **Proofread** — **⌃⇧G** (runs on a selection).
- **A hotkey for any action** — every toolbar action (Copy text, Translate, Proofread, Summarize, Ask
  AI, QR, Colour picker, Identify, Lens) can have its own shortcut that runs it straight away, skipping
  the toolbar. Assign them in Settings ▸ General ▸ Toolbar actions; none are set by default. Identify
  and Lens also have a *Full screen* variant that grabs the whole display, like Google Lens's "Search
  Specific Area" / "Full Screen Search". If an action can't run (Lens in local-only mode, an AI action
  with no model picked), the hotkey says so instead of doing nothing.
- **A toolbar you arrange** — reorder the actions in Settings ▸ General ▸ Toolbar actions so the ones
  you use sit where you expect, every time: your order wins even when a selection contains a QR code or
  a colour. Switch an action off and it moves into the toolbar's "…" menu rather than disappearing.

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

The capture shortcut defaults to **⌃⇧C** and is changeable in Settings.

## AI providers

Settings → Intelligence lets you pick where the thinking happens:

- **Apple Intelligence** — on-device, no setup. The default.
- **Ollama** — a local model server. `ollama pull qwen3:4b` (or whatever you like) and Lasso
  auto-detects it. Still 100% on your Mac.
- **MLX** — on-device models that run on Apple Silicon directly. Browse, download, and manage them
  inside Settings; nothing leaves your Mac.
- **OpenAI-compatible** — OpenAI, Groq, OpenRouter, Google, LM Studio, or any custom base URL. Add as
  many connections as you like (name + base URL + key); they're all live at once, and Lasso fetches
  what each one serves. The Model dropdown is the union of every connection's models, grouped by
  connection, so picking a model is what decides where the request goes. Connections are managed in
  one place, under "Manage connections".
- **Google Gemini** — Google's native Gemini API. Add it as a connection with just a name and an API
  key; the endpoint is built in. Its models join the same dropdown as everything else. (You can still
  reach Gemini through the OpenAI-compatible route instead, using Google's compatibility layer at
  `https://generativelanguage.googleapis.com/v1beta/openai/` — both work, side by side.)
- **Anthropic** — Claude, via your API key.

**Free-model fallback** (off by default). Turn on *Fallback ▸ Free models* under a cloud language
model, and a request that fails before it starts answering (rate limited, provider down, model not
found) is retried on up to three free models, then on Apple's on-device model. A model that is only
slow gets company instead: if it hasn't started answering after the time you pick under *Slow model*
(15 seconds by default, or never), the best free model starts too and whichever answers first wins.
Your model isn't cut off, so if it was about to answer, you still get it. If it fails twice in a row,
Lasso stops waiting on it: the next messages go straight to the model that answered, and Chat shows
"Using X · Y isn't responding" with **Switch** (make it your model) and **Try again**. If it was only
slow rather than broken, it keeps every message and the free model simply starts alongside it, with
**Stop racing** to go back to waiting. Your selection
doesn't change, and Lasso gives your model another go after a few minutes, so it comes back on its own.
A model that is slow rather than broken keeps its place: the free model simply starts at the same time as
it, rather than after the wait. Apple's on-device model is the last resort, and only for conversations
small enough for it to hold and turns that do not need a search; when it answers, it is told which model
it is standing in for so it continues the chat instead of starting over. Racing means two requests, so a
slow turn spends one free-model request even when your own model wins, and a model cut off after it had
started generating may still bill for what it produced. Only connections you
set to **Use as fallback** in Manage connections are used, a server on your Mac included. Lasso tries
your own model on another connection first, then the free model closest to it that can handle the
request: it must read your images, fit the conversation, call web search when you asked for one, and
not be far smaller than the model you chose. A turn where you asked for a search is never handed to the
on-device model, which can't search. Chat's Activity, Ask AI, and Proofread (its result card and its
in-place popup) say which model answered, and your selected model doesn't change. Free means: models OpenRouter prices at
zero, a server on your Mac, and, once you turn on **Free tier** for a Groq or Google connection, the
models that provider documents as included in its free plan (unless your selected model on that key is
a paid-only one, which means the key is billed). Lasso never guesses that a model is free, and free plans
may use your requests to improve their models. A fallback sends the request to a different provider
than the one you picked, so it never starts from a model on your Mac or your own network (a private
address, a one-word host name like `mac-studio`, or a `.local`, `.lan`, `.home.arpa`, `.internal`, or
Tailscale `.ts.net` name), never runs for Chat's background memory summary, and is off entirely in
local-only mode. Identify only ever retries on-device. Free models carry a *free* tag (*free tier* for
plan-based ones, dropped when your selected model on that key is paid-only) in the Settings model picker
and the chat switcher. It doesn't cover the image model yet.

Image and Embedding are their own sections with the same layout as Language. Image starts out
**linked** to your language model (useful when that model is multimodal); turn the link off to give
images their own provider, key, and model.

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
