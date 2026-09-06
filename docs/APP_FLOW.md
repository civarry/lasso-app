# Lasso — App Flow & Architecture (living document)

> **Keep this in sync with the code.** Every behavior/flow change updates the diagrams + notes here in
> the same pass. This is the canonical map of how the *whole* app works today — not a plan, the shipped
> reality. Product direction & rationale live in the planning notes; this file tracks *what is*.

Positioning: **"Screen search for your whole Mac, on-device by default."** Select anything on screen →
understand it or act on it. Zero-setup default path, privacy-preserving (local vision + keyless web),
with an opt-in Google Lens escalation for full reverse-image search.

---

## 1. Module map (layers)

```mermaid
flowchart TD
  Trigger["Trigger — hotkey + menu bar<br/>(Trigger/, KeyboardShortcuts)"] --> Capture
  Perms["Permissions — screen recording<br/>(Permissions/)"] -.gates.-> Capture

  subgraph Capture["Capture (Capture/)"]
    Freeze["Freeze display<br/>ScreenCaptureService"] --> Select["Overlay + drag select<br/>OverlayWindow · SelectionView"]
    Select --> PrePass["Pre-pass: OCR · barcodes · data detectors · prewarm vision"]
  end

  PrePass --> Ctx[CaptureContext]
  Ctx --> Registry["ActionRegistry.relevantActions"]
  Registry --> Bar["Action bar (UI/ActionBar)"]
  Bar --> Actions["CaptureAction.perform (Actions/)"]

  Actions --> Engines["Engines/: OCR · Translate · Barcode · DataDetector · LanguageDetect"]
  Actions --> Intel["Intelligence/: providers · connectors · caches"]
  Actions --> Result["Result surfaces:<br/>FloatingResultView · IdentifyView · LensResultView · InlineTranslation"]

  Chat["Chat panel (Chat/) — ⌥⌘A, parallel surface"] --> Intel
  Settings["Settings (App/Settings)"] -.configures.-> Intel
```

---

## 2. Capture pipeline (`Capture/CaptureCoordinator.swift`)

1. **Trigger** — global hotkey (`Trigger/TriggerService`, KeyboardShortcuts) or menu bar
   (`MenuBarController`) starts a session. Screen-recording permission is gated by `PermissionsService`.
2. **Freeze** — `ScreenCaptureService` grabs the display; `OverlayWindow` shows it frozen so the user
   can drag a selection (`SelectionView`); `SubjectLift` supports object/subject lift.
3. **Pre-pass** (`runPrePass`) on the crop: `OCREngine` (text + per-line boxes), `BarcodeEngine`
   (QR/barcode), `DataDetector` (URLs/phones/emails/dates), and `prewarmVision()`. Results populate a
   `CaptureContext` (`Actions/CaptureAction.swift`).
4. **Route** — `ActionRegistry.relevantActions(for:)` filters + sorts actions by `relevancePriority`;
   the **action bar** renders them. Direct-shortcut actions can skip the bar.
5. **Perform** — `CaptureAction.perform` returns an `ActionResult`: `.text` / `.stream` →
   `FloatingResultView`; `.custom(AnyView)`; `.inlineTranslate`; `.copiedToPasteboard`; `.openedURL`;
   `.none`. The freeze drops once a result floats (or on `.none`).

---

## 3. Feature / action catalog (`Actions/`, registered in `ActionRegistry.makeDefault`)

| Action | id | Prio | Backend / engine | Output surface |
|---|---|---|---|---|
| **Copy text** | `ocr.copy` | — | `OCREngine` (pre-pass) | pasteboard |
| **Translate** | `translate` | 20 | Apple Translation framework (`TranslateEngine`) | inline overlay (`InlineTranslationView`) or `TranslationResultView` |
| **Grammar fix** | `grammar.fix` | — | text provider (`GrammarFixService`) | floating card |
| **Summarize** | (summarize) | — | text provider | `FloatingResultView` stream |
| **Ask AI** | `ai.ask` | 40 | text provider (+ vision for imageless text) | `AskAIView` inline |
| **QR / barcode** | `qr` | — | `BarcodeEngine` (pre-pass) | open URL / show payload |
| **Color picker** | `color` | — | pixel sample | swatch view |
| **Identify** | `identify` | 12 | vision + keyless web + text synth | `IdentifyView` card |
| **Google Lens** | `lens.search` | 13 | WKWebView → lens.google.com (opt-in) | `LensResultView` panel |
| **Chat** (separate) | — | ⌥⌘A | text provider (+ tools/web) | `ChatView` panel |

---

## 4. Intelligence system (`Intelligence/IntelligenceProvider.swift`)

**Three independent roles** (Settings ▸ Intelligence: **Language model**, **Image model**, **Embedding
model** — each a `Provider` picker + per-provider config), staged in a `Draft` and committed on Apply:

- **Language / Text** (`ProviderKind`): `apple` on-device Foundation Models (default, text-only), `ollama`
  (local server), `mlx` (local Apple-Silicon), `openAICompatible` (cloud/local endpoint, e.g. Groq/LM
  Studio), `anthropic`. Streams deltas via `respond(prompt:context:)` / `respond(messages:)`; tool-capable
  providers also expose `respond(messages:tools:execute:)`.
- **Image / Vision** (`VisionEngine`): `matchText` (route through the text provider if it's multimodal),
  `ollama`, `mlx`, `openAICompatible`, `anthropic`. **Apple on-device is text-only** → returns nil for
  vision (no silent fallback). Used to *describe* an image (Identify, Ask-AI-on-image, Chat attachments).
- **Embedding** (`EmbeddingProviderKind`, §7): `automatic` (Ollama embed model if reachable → Apple
  `NLEmbedding` → none), `apple`, `ollama`, `openAICompatible`. Powers Chat semantic memory only.
  Resolved by `makeEmbedder()` (probe → **always falls back to Apple**, so retrieval never breaks).
- **OpenAI-compatible services**: each cloud role picks a **Service** (OpenAI/Groq/OpenRouter/Custom) with
  its own Base URL + model; the **API key is shared per service** across roles (`openAIKeyByService`).
  Embedding has its own independent service (can differ from Language — e.g. embed on OpenAI while chatting
  on Groq).
- **`isLocal` / local-only**: `isLocal` drives the privacy badge; **local-only mode**
  (`PrivacyMode.localOnly`) forces every cloud choice back to local via the `effective*` getters
  (`effectivePreferred` / `effectiveVisionEngine` / `effectiveEmbeddingProvider`) — cloud options are also
  hidden in the pickers — so nothing leaves the Mac regardless of what's stored (see §8).
- **Tools** (`Intelligence/Tools/`): a model-decided `web_search` tool for Chat on tool-capable
  backends; others fall back to heuristic grounding. Which tools a turn actually *sees* is chosen by
  `Harness/Toolbelt` — registration and exposure are separate, and the menu is capped at
  `maxExposed` (3), because tool-choice accuracy falls off as the menu grows.
- **Harness** (`Intelligence/Harness/`) — the app's own reasoning, kept off the answer model:
  - **`UtilityModel`** (`utilityModel()`): the model the *harness* thinks with. Apple on-device when
    available, else the user's active provider (never a third-party endpoint they didn't choose).
    Utility calls bypass `streamWithFailover`, so they never touch the attribution footer or the
    privacy badge; a non-local fallback flags `noteOffDeviceUse()`.
  - **`StructuredOutput` + `StructuredRunner`**: one typed request, four rungs, tried in order —
    **guided** (Apple `@Generable`, constrained decoding, malformed output impossible) → **jsonSchema**
    (`respondJSON`: Ollama `format`, OpenAI `response_format` with a `json_object` downgrade,
    Anthropic forced tool use) → **lineFormat** (labeled lines, parsed leniently; MLX's only rung) →
    **none** (caller applies its own deterministic fallback). The runner never throws.
  - **`ModelText`**: shared lenient reading of model output (`<think>` stripping, first balanced JSON
    object, "NONE"-aware field reads).

**Settings → resolution** (how a stored choice becomes the backend that actually runs):
```mermaid
flowchart TD
  subgraph S["Settings ▸ Intelligence (staged Draft, committed on Apply)"]
    LP["Language · ProviderKind"]
    IP["Image · VisionEngine"]
    EP["Embedding · EmbeddingProviderKind"]
  end
  LP --> LO{{"PrivacyMode.localOnly?"}}
  IP --> LO
  EP --> LO
  LO -->|"yes → force cloud to local"| EFF["effectivePreferred /<br/>effectiveVisionEngine /<br/>effectiveEmbeddingProvider"]
  LO -->|"no → as chosen"| EFF
  EFF --> RT["activeProvider()<br/>→ streamWithFailover ↓"]
  EFF --> RV["activeVisionProvider()<br/>(nil if unusable — no silent Apple)"]
  EFF --> RE["makeEmbedder()<br/>probe → Apple fallback"]
```
- **Transient-error failover** (`streamWithFailover`): every `respond(…)` streams through one wrapper.
  If the active provider throws a *transient* error (`isTransient`: 429/timeout/5xx/network) **before the
  first token**, it retries **once on the on-device Apple model** and prefixes a short honest note. Never
  swaps mid-answer (would splice two models); never falls back to a *cloud* provider — the only target is
  the always-local on-device model, so it can't leak (and local-only mode never reaches the network). Bad
  keys / oversized prompts / cancellation are not transient → surface as-is. `setLastProvider` updates the
  attribution + privacy badge to the model that actually answered.

```mermaid
flowchart LR
  R["respond(…)"] --> P["active provider streams"]
  P -->|first token then done| OK([answer])
  P -->|error before any token| C{transient?<br/>429·timeout·5xx·net}
  C -->|no| E([surface error])
  C -->|yes| F{on-device available<br/>& primary ≠ on-device?}
  F -->|no| E
  F -->|yes| N["note + retry on-device (local)"] --> OK
```

---

## 5. Identify pipeline (`UI/IdentifyView.swift`)

OCR-first routing decides text mode vs. the visual identify path; **neither is a dead-end**.

```mermaid
flowchart TD
  Start[Identify on selection] --> Cache{IdentifyCache hit?}
  Cache -->|yes| Replay[Replay cached summary + related]
  Cache -->|no| Route{"OCR text >= 40 letters<br/>&& not forceVisual?"}

  Route -->|"text-heavy (default)"| TextMode["TextActionsView:<br/>Detected text · N words<br/>Copy · Translate · Ask AI · Chat"]
  Route -->|visual| Vision[On-device vision model describes]

  Vision --> Web["Keyless web grounding (WebSearchSource):<br/>Wikipedia · DuckDuckGo · Reddit"]
  Web --> Synth[Synthesize summary + confidence + rank RELATED]
  Synth --> Card[Answer + confidence chip + RELATED links]
  Card --> LensBtn[["Search with Google Lens - one tap"]]

  TextMode -->|"Actually a photo? · Identify anyway"| Vision
  TextMode -->|"Actually a photo? · Google Lens"| LensBtn
  LensBtn -.opt-in.-> LensWeb[Lens panel - WKWebView -> lens.google.com]

  style TextMode fill:#1e4a2e,stroke:#4b8
  style Card fill:#1e4a2e,stroke:#4b8
  style LensBtn fill:#1e3a5a,stroke:#48b
```

- **Routing signal:** `hasStrongText` = `ocrText` letters ≥ 40. Escape hatch "Identify anyway" sets
  `forceVisual` (`textHeavy = hasStrongText && !forceVisual`) so a photo-that-carries-text still gets
  the visual path (on-device / local-only).
- **Text mode** (`TextActionsView`): Copy · Translate (`TranslationResultView`) · Ask AI (`AskAIView`)
  · Chat, plus opt-in "Clean up misreads with AI" → single Cleaned column, changed lines highlighted
  (`OCRDiff.changedLines` + `OCRCleanedView`); verbatim source is never silently rewritten.
- **Models:** vision role describes on-device; the text provider synthesizes the final answer +
  `Confidence: High/Medium/Low`. Ranking/caching: `rankHits` (word overlap), `IdentifyCache`.

---

## 6. OCR & Translate

- **OCR** (`Engines/OCREngine.swift`) — Apple Vision `RecognizeTextRequest`, accurate, zh-Hant+en.
  `readingOrdered(_:)` reconstructs reading order geometrically (column-aware; verbatim, never
  rewrites/drops), fixing multi-column interleaving app-wide.
- **Translate** (`Engines/TranslateEngine`, Apple Translation framework) — on-device. Two surfaces:
  inline overlay translation over each OCR line (`InlineTranslationView`, needs line geometry) and the
  single-pane `TranslationResultView` (source/swap/target capsule). `LanguageDetect` picks the source.

---

## 7. Chat (`Chat/`)

Persistent top-right panel (⌥⌘A), independent of the capture overlay. Multi-turn, **multi-image**
attach (button / ⌘V / drag / capture seed; up to `maxAttachments`), two-track memory
(`ConversationMemory`, `ChatContextBuilder`). Images: `Attachment` (structured, stable id) → native
models get an image array per turn; text-only models get per-image "Image N:" captions + OCR. Grounds via the same keyless web search; reverse-image is the one-tap Lens
escalation, not a silent per-turn API call.

**Search planning:** on the heuristic route (Apple / MLX / tool-less Ollama), `planSearch` rewrites
the turn into one self-contained query with references resolved. It runs on the **utility model**, not
the chat model, through the structured ladder — so the plan is a typed `SearchPlan` on every backend,
and an MLX chat model no longer serializes a planning pass ahead of the answer it is about to stream.
`SearchPlan` (`Chat/Harness/SearchPlan.swift`) owns its own parsing for all rungs; `ChatController`
keeps `repair` / `fallbackSearchPlan` (the deterministic floor) and the entity guardrails.

**Context memory (three speeds):** recent 6 turns verbatim → two-track running summary (durable facts
+ topic trace) → **semantic retrieval** (`ChatMemoryIndex`, Phase 1). The index embeds completed
*exchanges* (user + assistant) in the background; at send it retrieves the top-K most relevant *older*
exchanges verbatim (query = current text + last 1–2 turns), deduped against the recent window, into a
bounded reserve in `ChatContextBuilder`. **Embedding backend is a user choice** (Settings ▸ Intelligence
▸ **Embedding model**, peer to Language/Image): `automatic` (Ollama `nomic-embed-text` if installed →
Apple `NLEmbedding` on-device → none), `apple`, `ollama` (any local embed model), or `openAICompatible`
(cloud, e.g. `text-embedding-3-small/-large`, with its **own** independent OpenAI-compatible service —
OpenAI/Groq/OpenRouter/Custom + Base URL + key, like the Image model; key shared per-service). Resolved by
`IntelligenceCoordinator.makeEmbedder()`; **local-only forces cloud→local** (`effectiveEmbeddingProvider`).
The **default (Automatic → Apple) needs no download** — works on any Mac immediately. Vectors from
different backends are incomparable, so changing the backend resets every session's index
(`ChatController.embeddingConfigChanged`) and it re-embeds lazily. See `docs/CHAT_MEMORY_DESIGN.md`.

**Persistence (`ConversationStore`):** conversations are saved to `~/Library/Application Support/Lasso/`
— **one JSON per conversation** + a lightweight `index.json`, so history survives app updates /
uninstall→reinstall (the data lives outside the `.app`, like `UserDefaults`/Keychain). **Source-of-truth
only:** messages, two-track memory, title, and the *textual* image representation (`promptText` already
folds in the vision description) + a small **thumbnail** per attachment (`images/<id>.jpg`). The semantic
index (embeddings) is **derived** — never stored; it rebuilds lazily on load/switch (`reindexActive`).
Every file carries `schemaVersion` for future migration. Saved on turn-finish / memory-update / session
lifecycle (disk I/O off the main actor); **Clear chat history** in Settings ▸ General wipes it. Restore
drops streaming/derived state and image-anchor pixels (selection anchors persist).

```mermaid
flowchart LR
  subgraph Disk["~/Library/Application Support/Lasso/"]
    IDX["index.json (schemaVersion + [title,kind,count])"]
    C1["conversations/&lt;id&gt;.json (messages, memory, title)"]
    T1["images/&lt;attachmentId&gt;.jpg (thumbnail)"]
  end
  Turn["turn finishes / memory updates"] -->|snapshot· off-main| C1
  C1 --> IDX
  Launch["app launch"] -->|loadAll → rebuild| Mem["in-RAM Conversations"]
  Mem -->|reindexActive· lazy| Emb["semantic index (rebuilt, never stored)"]
```

---

## 8. Connectors, web grounding & privacy

Reverse-image via a keyed API was **removed** — Google Lens (zero-setup, opt-in) is the only
reverse-image path now.

```mermaid
flowchart LR
  subgraph Default[Default - zero setup]
    WebSearch["Web search (ON by default)<br/>Wikipedia · DuckDuckGo · Reddit<br/>keyless URLSession"]
  end
  subgraph Adv["Settings ▸ Connectors ▸ Advanced (collapsed, off)"]
    Tavily[Tavily key]
    SerpApi[SerpApi key]
  end
  Identify[Identify] --> WebSearch
  ChatP[Chat] --> WebSearch
  WebSearch -. optional stronger results .-> Adv
```

Files: `Intelligence/Connectors.swift`, `WebSourcesProvider.swift` (`WebSearchSource`,
`IdentifySources`), `SearchCache`, `SearchQuota`, `DomainNoise`, `Keychain`.

**Privacy invariant:** `privacy.localOnly` (PrivacyMode) gates **every** off-device path at the source
— web connectors pause, the Lens button/action hides, favicons don't load. Local-only = zero
off-device network. See memory `lasso-localonly-egress-invariant`.

---

## 9. Design system (Liquid Glass / Tahoe)

Primitives in `UI/Theme.swift`:
- `.liquidGlassPanel()` — frosted `.ultraThinMaterial` fill, continuous 26pt squircle, hard-clipped +
  hairline border. **No SwiftUI shadow** — the panel *window* uses the native macOS shadow
  (`hasShadow = true`) so it's cast outside the card's silhouette, never *through* the translucent
  corners (a SwiftUI `.shadow` did → dark "double edge"). `.regularMaterial` under Reduce Transparency.
- `.glassWell()` — recessed content blocks (dark `black 0.18` tint, continuous 16pt); not glass.
- Action pills — compact inline (icon + label, ~34pt), equal-width flex; inactive translucent white,
  active tool solid accent. Language bar — one material capsule (plain-text names + accent-glass swap).
- Requires the panel window non-opaque + clear (`FloatingPanel`, chat panel).
- Applied to: Identify card, `FloatingResultView`, `ChatView`, `LensResultView`. Action bar / Grammar
  chip / inline-translate already used material.

---

## Future improvements (deferred — not yet built)

Framed by the three "engineerings" — prompt / context / loop. **Prompt and context are mature**
(an external review scored the memory/context work ~9.7 and advised *freezing* it); **loop engineering is
the next frontier.**

**Loop engineering — highest leverage next** (what the app *can do*, beyond a single pass + one tool call).
**Full design + phasing now lives in [`docs/HARNESS.md`](HARNESS.md)** (utility model, structured-output
ladder, toolbelt exposure policy, plan→act→check, verification, skills):
- A lightweight **plan → act → check** loop for multi-step chat requests (builds on the `web_search` tool loop).
- **Self-verification** on grounded answers — does the answer actually follow from the retrieved evidence?
- Beyond the single `streamWithFailover` hop: retry-with-correction, a small planner / task queue, agentic workflows.

**Context — frozen (resist tuning):**
- Cross-session / **global memory** (search across all saved chats) → *then* a persisted vector store earns
  its keep; the per-conversation index stays in-RAM/derived. Pairs with a "forget me" privacy surface.
- Cross-turn image gallery + full-res image persistence (today: thumbnails + `promptText` descriptions).
- Reviewer nice-to-haves left deliberately unbuilt until real usage demands them: adaptive-K retrieval,
  IDF-weighted keyword gate, Fact-vs-Conversation memory split.
- **Calibration-independent retrieval** (would let *any* embedder in, incl. BGE-base): replace the fixed
  `highSemanticBar` cosine gate with **Top-K + margin** (admit only candidates within a delta of the top
  score) or a **reranker**. Fixed cosine thresholds assume calibrated scores across models, which doesn't
  hold (BGE-base/GTE cluster ~0.9 for everything though their *ranking* is still correct). Pair with a
  **ranking benchmark** ("is the right memory ranked #1 in the top-20?") instead of the current
  above-threshold pass/fail — that measures the embedder, not the threshold fit.

**Polish / infra:**
- In-app `ollama pull` for the embedding model (today: guided caption with the command).
- Skip the `huggingface.co` update check when an MLX model is already cached (offline-when-cached).
- A cloud-embedding connection **Test** button in Settings (today: the live `probeEmbedding` status row covers most of it).

## Change log
- **Hybrid retrieval for web sources**: BM25 (`Intelligence/Harness/HybridRanking.swift`) runs over the
  turn's candidate pool alongside the existing vector ranking, and the two are combined with
  Reciprocal Rank Fusion (`RankFusion`, k = 60) to decide the **order** evidence reaches the model,
  which matters because `evidenceLimits.hits` truncates. Raw BM25 and cosine are never summed, only
  their ranks. Storage-free by design: no SQLite/FTS5 exists in Lasso and a pool is 10-15 short
  documents. BM25 needs no model, so it is independent of the selected embedding provider; the vector
  side reads the same resolved `ChatEmbedder` as before (Apple / Ollama / MLX / OpenAI-compatible).
  **Admission stays a vector decision** and RRF is not a substitute for it: measured, BM25 over a pool
  retrieved *for* the query has compressed IDF, and its strongest signal on "who is the CEO of
  Anthropic" excluded the document that answers it. **Zero evidence is now a valid outcome**
  (`minKeep: 0` at the call site): two irrelevant results are worse than none.
- **Web evidence is ephemeral context, not conversation history.** It used to be folded into
  `userText`, which becomes `promptText`, which is replayed as the user's own message by
  `historyTurns`, summarised into durable memory, read by the search planner, embedded for semantic
  recall, and written to disk. One grounded turn contaminated all five (observed: context growing
  3566 → 15041 chars over six turns). It now travels through `ChatContextBuilder.build(evidence:)`
  as its own **system** turn placed immediately before the question, so it is the most recent thing
  the model reads, stays distinguishable from the user's words, and is gone next turn. The
  "no results right now" note is ephemeral for the same reason. Trade-off: a follow-up turn no longer
  sees the previous turn's sources, only the assistant's answer.
- **Weak relevance is reported, not acted on.** `minKeep: 2` does guarantee two survivors even when
  nothing clears the bar, but the score cannot separate a real question from a false premise: measured
  live, "who is the CEO of Anthropic" is rescued by the floor (top 0.389, one hit clearing) while
  "first human to walk on Mars in 1987" clears it with three (top 0.357, led by an unrelated Le Guin
  story). Deleting evidence on that signal starves the real question and keeps the fake one. So
  `relevanceIsWeak` now marks the block instead: the model is told nothing scored as clearly relevant
  and that reporting no reliable information is the right answer. Logged as `WEAK, nothing cleared
  the bar`.
- **Web-evidence trust model** (hallucination hardening). Retrieved content is now framed as untrusted
  data rather than a reference: the Wikipedia abstract carries the article title it summarises and is
  dropped when that article shares no significant term with the query (`abstractIsOnTopic`); the
  "Reference summary:" label and the "prefer it over your own memory" framing are gone; both grounding
  paths share one `fencedEvidence` wrapper that marks the block as data, never instructions, permits
  saying no reliable evidence was found, and states that the user's own context outranks it. The
  system prompt keeps "best interpretation rather than declining" for ambiguity but now allows
  rejecting a false premise without inventing a replacement.
- **Plan grounding**: `repair` drops a `resolvedEntity` that appears nowhere in the user's message or
  the recent transcript. An invented entity was being prepended to the query and then enforced by the
  source gate, so the search returned material corroborating the invention (observed: `entity=Neil
  Armstrong` for a question that never mentioned him).
- **Declarative statements skip search** (`isDeclarativeContext`): a message with no question, no
  interrogative, and either a memory lead-in or a `key = value` assignment routes `.skip`. Previously
  "Remember: Project = Phoenix, Version = 7" was rewritten into a web query and answered instead of
  stored. Deliberately narrow (`=` only, never `:`) so real queries like "Swift error: cannot find
  type in scope" still ground.
- **Search cache is v2**: v1 entries predate abstract provenance and would bypass the abstract gate.
- **Plan normalization**: `repair` now drops a *non-constraining* resolved entity (a single lowercase
  token the query already contains, e.g. `entity=telescope` for query `telescope`). Gating on one
  matched every hit while reading like a working gate, and on a partial match it dropped hits for no
  reason. The source-entity log line now says `NO-OP, matched everything` when the gate constrains
  nothing, so the two cases are distinguishable in a trace.
- **Connector latency**: Tavily now starts *alongside* the free fan-out instead of after it (it reads
  none of the free results). Measured before the change: free block 1136ms, then Tavily 2605ms serial,
  on every uncached grounded turn. SerpApi stays serial because it only tops up a thin deduped set.
  `lookup ·` and `web source ·` log lines make the split visible.
- **Harness P0** (`Intelligence/Harness/`, `Chat/Harness/`): a `UtilityModel` for the app's own
  reasoning, a four-rung `StructuredOutput` ladder with `respondJSON` on Ollama / OpenAI-compatible /
  Anthropic and `OnDeviceProvider.generate` for Apple guided generation, `SearchPlan` migrated onto
  both, and a `Toolbelt` registry/exposure split around the existing `web_search`. Verified live on
  the guided rung; the query hygiene it exposed (`tidyModelQuery`: question framing and command words
  survive constrained decoding) is now part of `repair`, and `prewarmUtility()` warms the on-device
  model when the chat panel opens. Design + phasing: [`docs/HARNESS.md`](HARNESS.md).
- **MLX embedding backend**: a fourth Chat-memory embedder (`EmbeddingProviderKind.mlx`) via the
  `MLXEmbedders` library (same package as the Language/Image MLX models). `MLXEmbeddings` +
  `MLXEmbedderCache` (load-coalescing, memory-pressure eviction) load BERT-style encoders (bge / e5 /
  nomic / MiniLM) and pool → normalized `[Double]`. Downloaded **in-app** via the reused `MLXModelManager`
  (an injected `ensureDownloaded` closure routes to the embedder loader, since embedders aren't causal
  LMs). Default `multilingual-e5-small` — a strong multilingual on-device option with no Ollama. Local
  (safe in local-only, but download itself is gated like other MLX models). Symmetric embedding (no
  query/passage prefixes yet — a future refinement). Status row + honest Apple fallback until downloaded.
- **Slash-command palette**: typing `/` in the chat composer shows a filterable list of session commands
  (`/new`, `/clear`, `/copy`, `/web` when connectors exist). Arrow keys navigate, Enter/Tab runs, Esc
  dismisses, click/hover works too (`.onKeyPress` on the input; hidden once a space/non-slash text
  appears). Commands are session actions, not model prompts. `/reset` still works via the legacy path.
- **Per-message actions** (hover `⋯` menu on each bubble): Copy (folds the old standalone Copy button
  in), plus **Regenerate/Delete** (assistant) and **Edit/Resend/Delete** (user). Delete confirms; the
  rest are instant. `ChatController.deleteMessage/resendMessage/editMessage/regenerate` mutate history,
  then `historyDidChange` resets + rebuilds the semantic index and re-persists. No context-window meter
  (deliberately tokenizer-free; token counts aren't reliable across Apple/MLX/Ollama).
- **Chat UI polish pass** (`ChatView`, `MessageBubble`): assistant turns get a subtle contained card
  (was flush-left plain text); both roles get a bubble **tail** (`UnevenRoundedRectangle` — squared
  corner nearest the speaker). Header shows a **friendly** provider name (`friendlyModel`); the full
  model id moved into the model dropdown. Copy button is now **icon-only, on hover**. Attachments render
  as a **compact card** (thumbnail + dimensions) instead of a shrunken full-screenshot. Tighter
  inter-message spacing; send button is a **filled accent circle** when ready (dim when empty). Message
  text is drag-selectable + **Copy conversation** (whole transcript) in the menu.
- **§4 now tracks all three Intelligence roles** (Language / Image / Embedding) with a **Settings →
  resolution** mermaid (chosen `Provider` → `effective*` local-only enforcement → `activeProvider` /
  `activeVisionProvider` / `makeEmbedder`). Documents the per-service OpenAI-compatible key sharing and
  embedding's independent service. (Was "two roles", no resolution diagram.)
- **Embedding availability + graceful "no embedder"**: `AppleSentenceEmbedder` now falls back from
  sentence embeddings to **word-vector averaging** (bundled for ~50 languages) so Apple on-device
  resolves on nearly any Mac (no download). Settings shows a **live status row** (`probeEmbedding`) —
  Active / fell-back-to-Apple / off — so a missing embedder is visible, not silent. When truly no
  embedder exists, retrieval is a safe no-op (nothing indexed → chat falls back to the running summary).
- **Selectable embedding model** (Settings ▸ Intelligence ▸ Embedding model): `EmbeddingProviderKind`
  (automatic/apple/ollama/openAICompatible), peer to Language/Image. Cloud reuses the Language model's
  OpenAI endpoint+key (`OpenAIEmbedder`, `/embeddings`), **blocked in local-only** (forced to local via
  `effectiveEmbeddingProvider`). `IntelligenceCoordinator.makeEmbedder` owns resolution (probe →
  Apple fallback so retrieval never breaks). Default `automatic` needs no download (Apple on-device).
  Changing the backend resets all chat indexes (`embeddingConfigChanged`) — vectors are incomparable.
- **Chat persistence** (`ConversationStore`): conversations now survive app updates / reinstall — saved
  as one JSON per conversation + `index.json` in Application Support (outside the bundle). Source-of-truth
  only (messages, two-track memory, title, image thumbnails + `promptText` descriptions); the semantic
  index is derived and rebuilt lazily on load. `schemaVersion` on every file. Stable ids restored on
  `Conversation`/`Attachment`. `Kind` is now `String`-backed. Save hooks on turn-finish / memory-update /
  session lifecycle; **Clear chat history** in Settings ▸ General. See §7. (Deferred: full-res images,
  image-anchor pixels, cross-session shared memory.)
- **Provider reliability trio**: (1) transient-error **failover** — one `streamWithFailover` wrapper
  around all three coordinator `respond(…)` paths retries once on the on-device model when the active
  provider throws a transient error (429/timeout/5xx/network) before the first token; never mid-answer,
  never cloud (§4). (2) **Embedder-reason logging** + reachability-gated Ollama probe in
  `ChatMemoryIndex.pickEmbedder` — no more `api/embed` connection-refused spam when Ollama is down; logs
  why it picked Ollama/Apple/none. (3) `OllamaModels.installed` now short-circuits on cached
  reachability. (Grounding-route logging in `ChatController.runTurn` was already present.)
- Chat **multiple conversations**: `Conversation` holds one chat's state (messages, two-track memory,
  semantic index, attachments); `ChatController` is now a manager (`sessions: [Conversation]` + `active`,
  forwarding facade). "Continue in chat" / Ask AI / capture seed **spawn a new conversation instead of
  wiping** the current one; header conversations menu switches between them (in-session, cap 12).
  Background summary/index tasks capture their conversation so switching never crosses streams.
  Each `Conversation` has a `kind` (general/selection/image/askAI → menu icon), an `anchor` (the
  image/selection it's about, for future "open source" actions), and an `autoTitle` generated by the
  background summary pass (via a `TITLE:` line in the same call — no extra model call), so long chats
  read as "Trip Planning" instead of their first message.
- Chat **multi-image per turn** (Phase 2): `Attachment` model, `ChatTurn.imageBase64s` + array encoders
  in all providers, `runTurn` OCRs/encodes/describes each image (labeled), composer thumbnail row +
  multi-image bubble. Cap `maxAttachments=5`.
- Chat semantic retrieval memory (`ChatMemoryIndex`) — Phase 1: exchange-chunk index, embedder ladder
  (Ollama→NLEmbedding→none), retrieval reserve in `ChatContextBuilder`. In-session only.
- Retrieval **relevance gate** — **hybrid lexical + semantic**: a candidate must share a keyword with
  the question (or clear a high semantic bar only strong embedders reach); semantic just ranks. Fixes
  the case where NLEmbedding scored genuine recall (0.34) below topically-adjacent noise (0.36). Also
  makes retrieval work with no embedder (pure lexical). k=2. (Superseded the relative-outlier attempt.)
- Retrieval ranking/logging polish: normalized keyword signal + a single legible `final` score, and a
  glanceable log (`🧠 retrieve · kept N/M` + per-candidate `✓/•` with reason) so "why did it remember
  this?" is answerable at a glance. (Recency/importance-in-ranking deferred to persistent memory.)
- **Provider system-turn fix (latent bug):** MLX dropped ALL `.system` turns (used its own hardcoded
  prompt) and Anthropic used only the *first* — silently discarding the injected conversation-memory
  AND semantic-retrieval blocks AND the app's chat system prompt. Both now merge every system turn.
  (Ollama / OpenAI-compatible / on-device already propagated them.)
- Removed Google Vision (keyed reverse-image) connector + source; Lens is the reverse-image path.
- Web search defaults ON; Tavily/SerpApi demoted to collapsed "Advanced".
- Identify text-heavy captures show `TextActionsView` instead of a refusal; escape hatch "Google Lens"
  + "Identify anyway" (`forceVisual`).
- OCR reading-order reconstruction (`OCREngine.readingOrdered`) — geometric, verbatim.
- Opt-in AI "Clean up misreads" → single Cleaned column with changed lines highlighted.
- Translate: full width; source/swap/target as one material capsule; "already in target" hint instead
  of the framework error; shared with the standalone Translate action.
- Compact inline action pills (translucent white / solid-accent active).
- App-wide Liquid Glass rollout (`FloatingResultView`, `ChatView`, `LensResultView`).
- Corner-artifact fix: native window shadow (`hasShadow=true`) replaces SwiftUI panel shadows; material
  hard-clipped to the rounded shape.
- Expanded this doc from Identify-only to whole-app architecture (module map, capture pipeline, action
  catalog, intelligence system).
