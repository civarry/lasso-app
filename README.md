<p align="center"><img src="app-icon.png" width="120" alt="Lasso"></p>

# Lasso

<p align="center">
  <a href="../../releases/latest"><img src="https://img.shields.io/github/v/release/civarry/lasso-app?label=latest&color=blue" alt="Latest release"></a>
  <a href="../../releases"><img src="https://img.shields.io/github/downloads/civarry/lasso-app/total?label=downloads&color=brightgreen" alt="Total downloads"></a>
  <img src="https://img.shields.io/badge/macOS-26%2B-lightgrey" alt="Requires macOS 26 or later">
  <a href="../../actions/workflows/ci.yml"><img src="https://github.com/civarry/lasso-app/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
</p>

**Draw a box around anything on your screen, then copy it, translate it, or ask AI about it.**

- A menu-bar app for Apple Silicon Macs.
- **Local by default:** nothing leaves your Mac unless you turn it on.
- Open source ([Apache 2.0](LICENSE)). [Download it](../../releases/latest) or [build it yourself](BUILDING.md).

<p align="center"><img src="screenshots/hero.png" alt="Drag a box around anything on screen and translate it in place"></p>

**Jump to:** [What's new](#whats-new-in-027) · [What it does](#what-it-does) · [Chat](#chat) ·
[Agent](#agent) · [Packages](#packages) · [Privacy](#privacy) · [Install](#install) ·
[Updates](#updates) · [AI models](#ai-models) · [Build it](#build-it-yourself)

## What's new in 0.27

**Packages can fix more without waiting for a Lasso update.** A search package can now take over the
whole search: it gets your message as you typed it and the question before it, and Lasso keeps only the
safety rules (what reaches the model, what leaves your Mac).

- **My notes 1.5** (from Browse) uses it: it fixes typos ("frozendcit" finds frozendict, or offers
  **Did you mean frozendict?**), understands Taglish ("paano magluto ng adobo?"), follows up ("show me an
  example" stays on the same subject) and reads dates ("what did we decide last week?").
- **Steps say what reached the model:** "Looked in My notes · sent 2 passages".
- **Go back:** after a package update, its page offers the version you had before.
- For package authors: the `source/1` and `describe/1` hooks, and `lasso-pkg replay` to try a source on
  saved chat turns ([guide](docs/PACKAGES.md#hooks-a-package-takes-over-a-step)).

<p align="center"><img src="screenshots/app/source-hooks-chat.png" width="460" alt="A typo offer, the corrected search, and a follow-up that stays on the subject"></p>

<details>
<summary>New in 0.26</summary>

**Your notes and a folder of docs work together.** Tested on a 9B local model with the Python 3.15 docs
next to everyday notes.

- **"What's in my notes?"** lists your folders with how many notes each holds, so a big docs folder no
  longer hides your own notes.
- **When nothing matches, the model is told so,** and says it, instead of making up an answer.
- **Lasso looks in your notes by itself sooner:** if a source's "What's in it" is empty, it's filled in
  from the folder's names once the folder has notes.
- **Get My notes 1.3.0 from Browse** for better answers to questions that mix a note and the docs.
- **0.26.1:** Settings › Models › Language model › **Manage connections** opens again.

<p align="center"><img src="screenshots/app/notes-and-docs.png" width="460" alt="Chat listing a notes folder by folder, then answering from a project note and the Python docs"></p>

</details>

<details>
<summary>New in 0.25</summary>

**Packages can do more without waiting for a Lasso update.**

- **They can see what you lasso:** the image, and every piece of text with where it sits. A package can
  read receipts, forms or layouts itself.
- **They can run by themselves**, on every capture or every finished chat reply, but only after you turn
  on **Run automatically** on that package's page. It's off by default, and an update that changes what
  runs turns it off again.
- **Patches can change more:** the empty chat's greeting, the message box's hint, and the icons of
  Lasso's actions.

<p align="center"><img src="screenshots/app/events.png" width="460" alt="A package that can run by itself on every capture, once Run automatically is on"></p>

</details>

<details>
<summary>New in 0.24</summary>

- **Updates stay installed:** the copy in Applications owns updates and starting at login.
- **Packages can read tables:** get Table to CSV 1.1.0 from Browse, lasso a table and click it.

<p align="center"><img src="screenshots/app/table-to-csv.png" width="460" alt="Table to CSV's page"></p>

</details>

<details>
<summary>New in 0.23</summary>

- **Your notes in chat, apart from web search.** Lasso looks in a source on your Mac (like My notes) by
  itself when a message fits, or when you type **@** and its name. With a cloud model it asks before
  sending any passage.

<p align="center"><img src="screenshots/app/sources-chat.png" width="420" alt="A chat reply that looked in Meeting Notes, with the file it used and Answer without it"></p>

</details>

<details>
<summary>New in 0.22</summary>

- **A package catalog**: Settings › Packages › **Browse…**, checked before anything is listed, with
  updates at the top. **Developer mode** and `lasso-pkg` to make your own.

<p align="center"><img src="screenshots/app/browse.png" width="460" alt="Browse Packages: an update at the top, then packages with what each one needs"></p>

</details>

<details>
<summary>New in 0.21</summary>

- **Packages run your Shortcuts and their own scripts.** Scripts run in a sandbox: they can't read your
  files (except a folder you pick), change anything outside their own folder, or reach the internet
  unless they say so. **Full access** is yours alone to give.

<p align="center"><img src="screenshots/app/package-scripts.png" width="460" alt="A package's page: a notes folder, a Shortcut, what its sandboxed script can reach, and Full access"></p>

</details>

<details>
<summary>New in 0.20</summary>

- **Packages can change Lasso itself:** the Summarize and Proofread prompts, action names, the toolbar's
  defaults, chat suggestions and extra chat instructions. Turn the package off and Lasso is exactly as it
  was.

<p align="center"><img src="screenshots/app/package-patches.png" width="460" alt="A package's page listing what it changes in Lasso"></p>

</details>

<details>
<summary>New in 0.19</summary>

- **Packages give the chat model and the Agent new tools.** Tools that only look something up run
  straight away; tools that **do** something ask you first.
- **Stuck permission? One click.** Settings › Privacy › Permissions › **Reset**.

<p align="center"><img src="screenshots/app/chat-tools.png" width="420" alt="The chat model used a currency tool, then asks before adding a task"></p>

<p align="center"><img src="screenshots/app/packages.png" width="460" alt="Settings › Packages with search, commands and the Tools for models list"></p>

</details>

## What it does

Press **⌃⇧C**, drag a box, and pick what to do:

| Action | What happens |
|---|---|
| **Copy text** | Pulls the words out of the picture. |
| **Translate** | Draws the translation right over the original, in place. Mixed languages work. |
| **Summarize / Ask AI** | Summarizes it, or answers your question about it. Works on pictures too. |
| **Identify** | Tells you what an object, product or place is, with sources. |
| **Scan code** | Reads QR codes and barcodes. |
| **Pick color** | Grabs the color of any pixel. |
| **Search with Lens** | Sends it to Google Lens. Off until you turn it on. |

<p align="center"><img src="screenshots/actions.png" alt="The full set of things Lasso can do with a selection"></p>

**Make it yours:**

- The toolbar keeps **your** order. Turned-off actions move to the "…" menu.
- Give any action its own hotkey to skip the toolbar. Nothing is bound until you choose.
- Identify and Lens can also grab the whole screen.

<details>
<summary>More about Translate and Identify</summary>

- **Translate:** Apple's on-device translation shows first. An optional AI pass then retranslates the
  whole selection with context (Filipino included).
- **Identify:** a local vision model names the thing, then writes a short answer with sources and a
  confidence rating. Repeat lookups are instant.

<p align="center"><img src="screenshots/identify.png" alt="Identify names what you point at and writes a short, sourced answer"></p>

</details>

## Chat

A chat panel that stays open (**⌃⇧A**) and remembers the conversation.

- **Attach anything:** images, text, PDFs, code. Drop files in, or send a capture to chat.
- **Sources:** answers can be grounded in web results (the globe), and in your own notes: type **@**
  and a source's name, or just ask and Lasso looks when a message fits.
- **Talk instead of type:** click the mic. Lasso stops listening when you finish, tidies the
  "ums" on your Mac, and one Undo restores exactly what you said.

<p align="center"><img src="screenshots/chat.png" alt="A chat panel that remembers the thread and grounds answers with sources"></p>

## Agent

*Optional and experimental.* Turn on **Agent** in the chat box and the chat can **do things**:
search the web, read and write files, run commands. You see every step.

<p align="center"><img src="screenshots/app/agent.png" width="420" alt="The Agent shows its steps and waits before a risky command"></p>

- **Asks before risky commands.** You allow once, allow for this chat, or deny.
- **Can see your screen:** it can look at the screen, ask you to drag around a part, or read an image.
- **Works in `~/LassoWorkspace`.** Its files go there (Settings › Agent › Show in Finder).
- **Uses only the model you picked in Lasso.** Not available in local-only mode.
- Needs [Hermes Agent](https://github.com/NousResearch/hermes-agent): `brew install hermes-agent`.
  Lasso sets it up for you.

<details>
<summary>How the Agent is set up</summary>

- Lasso gives Hermes a fresh profile of its own. Your own Hermes settings, keys and gateway aren't
  touched or used.
- Lasso starts it when you use Agent and stops it when Lasso quits.
- It gets only the Hermes tools useful here (commands, files, the web, memory), which roughly halves
  what a local model reads before its first reply.
- An MLX model is served to it by Lasso on your Mac. The first reply is slow while the model reads the
  setup; later ones are quick.
- Apple Intelligence can't drive the Agent. With it selected, Agent says so instead of switching models.
- Settings › Agent can let Hermes approve risky commands itself (every reply then says it's on), or use
  a Hermes you run yourself, which must have `approvals.mode: manual`.

</details>

## Packages

**Add features to Lasso with a small file, no coding in Lasso needed.** In Settings › Packages,
click **Browse…** for the [catalog](https://github.com/civarry/lasso-packages), or **+** to add a file
or package folder.

<p align="center"><img src="screenshots/app/package-review.png" width="440" alt="The review Lasso shows before adding a package"></p>

A package can add, or change:

- **Web search sources** (Tavily and SerpApi are built in).
- **Toolbar buttons** on captures, shown only when they fit (a tracking number, a flight, long text…).
- **`/commands`** in chat.
- **"Send to" targets** on captures and chat replies.
- **Hotkeys** for text you highlight in any app, with the result pasted back.
- **Tools** for the chat model and the Agent.
- **Changes to Lasso itself:** the Summarize and Proofread prompts, action names, the toolbar's
  defaults, chat suggestions and extra chat instructions. Off undoes them.
- **Shortcuts and sandboxed scripts** (new in 0.21) behind any of the above.
- **Your own sources** like My notes, which can take over the whole search (new in 0.27): typos, other
  languages, follow-ups and dates are the package's job, so it improves without a Lasso update.

**You stay in control:**

- Before adding, Lasso shows what it does and where it sends data.
- Keys stay in your Keychain and only go to that package's servers.
- A command uses **your** chosen model, never another one.
- Local-only mode pauses packages that reach off your Mac, and cuts scripts off the internet.
- Scripts run in a sandbox unless you give that package Full access.
- After a package update, **Go back** on its page returns to the version you had.

Make your own: [`docs/CONTRIBUTING-PACKAGES.md`](docs/CONTRIBUTING-PACKAGES.md) has examples, the rules,
Developer mode and `lasso-pkg`. The full design is in [`docs/PACKAGES.md`](docs/PACKAGES.md), and what can be changed in
[`docs/patch-targets.md`](docs/patch-targets.md).

## Privacy

<p align="center"><img src="screenshots/privacy.png" alt="Runs on your Mac. Nothing leaves unless you say so"></p>

- **Runs on your Mac** out of the box: Apple Intelligence for text, a local Ollama model for images.
- **Leaves your Mac only if you turn it on:** Identify's web lookup, Google Lens, cloud models.
- **Update check:** asks GitHub for the latest version a few times a day. Sends only Lasso's version.
- **Package catalog:** read from GitHub only when you open Browse. Off in local-only mode.
- **Local-only mode** blocks every network call except your local model.
- **Keys** are encrypted in your Keychain, all in one item. After an update, macOS asks for your
  password once (choose **Always Allow**).

## Install

1. Download the **`.dmg`** from [Releases](../../releases/latest).
2. Drag **Lasso** to Applications.
3. Open Lasso. macOS says it can't verify the developer (expected: it isn't notarized).
   Click **Done**, then System Settings › Privacy & Security › **Open Anyway**. Only once.
4. Turn on **Screen Recording** for Lasso in System Settings › Privacy & Security, then reopen Lasso.

Capture with **⌃⇧C** (change it in Settings).

**Needs:** an Apple Silicon Mac on **macOS 26+**. For local AI, install [Ollama](https://ollama.com)
and pull a model or two (`ollama pull qwen3:4b`, `ollama pull qwen3-vl:2b`). Apple Intelligence needs
no setup.

## Updates

Lasso **updates itself**: it downloads in the background and installs when you're not using it.
Change this in Settings › General › Software Update, or use **Check for Updates…** in the menu bar.

<details>
<summary>Updates and permissions, in detail</summary>

- An update installs only if it's signed with Lasso's update key, so a tampered download is rejected.
- Since 0.16.0 every release uses the same certificate, so macOS keeps your Screen Recording and
  microphone permissions across updates. Coming from 0.15.x or earlier? Install 0.16.0 or later from
  the DMG once and allow them again.
- On in Screen Recording but Lasso still asks? Another copy of Lasso holds the permission.
  Settings › Privacy › Permissions › **Reset** clears it.

<p align="center"><img src="screenshots/app/permissions.png" width="460" alt="Settings › Privacy › Permissions with a Reset button"></p>
- Local-only mode stops update checks.

</details>

## AI models

Pick in **Settings › Models**:

- **Apple Intelligence:** on your Mac, no setup. The default.
- **Ollama or MLX:** local models, still on your Mac. MLX models download in Settings or load from a
  folder you have (`~/models`, LM Studio).
- **Cloud:** OpenAI-compatible services (OpenAI, Groq, OpenRouter, your own URL), Google Gemini,
  Anthropic. Opt-in.

**Free-model fallback** (off by default): if your cloud model is rate limited or down, Lasso retries
on a free model you allowed, then on Apple's on-device model. Never in local-only mode.
Details: [docs/APP_FLOW.md](docs/APP_FLOW.md).

<details>
<summary>Good to know</summary>

- If Apple Intelligence is off on your Mac, AI actions use a local model if you set one up. Copy,
  translate and the rest keep working.
- Protected windows (Netflix, some banking apps) capture as blank on purpose. Lasso doesn't get around
  that.
- Google Lens picks its results' language from your region.
- Reverse-image search in Identify is opt-in and uses your own Google Cloud Vision key.

</details>

## Build it yourself

You need an Apple Silicon Mac on macOS 26+, Xcode 26+ and XcodeGen. No Apple developer account.
Steps: [BUILDING.md](BUILDING.md).

<details>
<summary>How it's put together</summary>

- Each feature is a `CaptureAction` (`Lasso/Actions/`): one file plus a line in `ActionRegistry`.
- OCR, barcodes and data detection run as `actor`s; capture and UI stay on the main actor.
- AI providers sit behind one `IntelligenceProvider` protocol, so Apple, Ollama, MLX,
  OpenAI-compatible and Anthropic are interchangeable.
- Search sources and commands are packages, not code.
- The README's app screenshots are rendered from the real views by `ReadmeScreenshotTests`.
- Fuller writeups: [`Lasso-macOS-Spec.md`](Lasso-macOS-Spec.md) and [docs/APP_FLOW.md](docs/APP_FLOW.md).

</details>

## License

[Apache License 2.0](LICENSE). Copyright 2026 civarry. If you redistribute Lasso or a modified
version, keep the [NOTICE](NOTICE) file, which credits the original author, and note what you changed.
