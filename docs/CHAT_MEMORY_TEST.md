# Chat Memory (Phase 1) — Test Script

Manual QA for the in-session semantic **retrieval memory** (`ChatMemoryIndex` + `ChatContextBuilder`
retrieval reserve). Companion to `CHAT_MEMORY_DESIGN.md`.

## Setup
1. Build & run in Xcode. Open the **Chat panel** (⌥⌘A).
2. Watch logs: Xcode debug console, or Console.app filtered `subsystem:com.cjcarito.Lasso category:chat`.
3. Key log lines:
   - `memory index embedder: …` — which backend resolved (`Apple NLEmbedding`, `Ollama nomic-embed-text`, or `none`).
   - `runTurn · retrieved N memory chunk(s)` — retrieval fired this turn.
   - `runTurn ·   retrieved[i]: …` — **what** was pulled in (a 140-char preview of each chunk).
   - `retrieve · sem=… kw=… · <preview>` — each surviving candidate's semantic score and keyword-overlap
     count. A candidate is kept only if it shares a keyword with the question (`kw ≥ 1`) or clears the
     high semantic bar; ranked by `sem + 0.1·kw`.
   These are `.debug` lines: in Xcode they show by default; in Console.app turn on "Include Debug
   Messages" (Action menu).
4. Send each message below in order; let each reply finish before the next.

> Recent verbatim window = 6 messages (3 exchanges). The two facts you plant at the start scroll out of
> it by the recall step, forcing the model to rely on **retrieval**, not what's still in the window.

## Main recall test

| # | Paste this | Expect — answer | Expect — log (`chat`) |
|---|---|---|---|
| 1 | `My staging server is 10.4.19.7 and it's throwing error code TX-8841.` | acknowledges | `memory index embedder: …` appears |
| 2 | `Also, my migration script is rollup_v3.py and it runs at 02:00 UTC.` | acknowledges | (indexing runs in background) |
| 3 | `What's 17 times 23?` | 391 | — |
| 4 | `Suggest a name for a coffee shop.` | some name | — |
| 5 | `How do I boil an egg?` | steps | — |
| 6 | `What's the capital of Australia?` | Canberra | — |
| 7 | `What was the error code on my staging server, and its IP?` | **TX-8841** on **10.4.19.7** | `runTurn · retrieved …` |
| 8 | `Remind me the migration script's filename and when it runs.` | **rollup_v3.py** at **02:00 UTC** | `runTurn · retrieved …` |
| 9 | `Give me a fun fact about octopuses.` | octopus fact | **no** `retrieved` line (relevance gate) |

## What each step proves
- **7 & 8 = the core win.** Those exact tokens (`TX-8841`, `10.4.19.7`, `rollup_v3.py`, `02:00 UTC`)
  were planted 5–6 turns earlier and are now outside the verbatim window. The lossy summary would blur
  arbitrary strings/numbers — so a **precise** recall proves the verbatim retrieval reserve did it.
- **7 vs 8 = precision.** The server question should surface the server exchange; the script question
  the script exchange.
- **9 = no over-retrieval.** An unrelated question should ideally not retrieve (see NLEmbedding note).

## Pass / fail
- ✅ **Pass:** steps 7 & 8 return the exact planted values, with a `retrieved` log line.
- ❌ **Model got context but ignored it** (`retrieved` fired, answer still vague): usually small-model
  quality — try a stronger text model. (This was previously an MLX/Anthropic bug: those providers
  dropped all `system` turns — now fixed. If it recurs, check provider system-turn handling.)
- ❌ **`memory index embedder: none`:** NLEmbedding asset unavailable → retrieval off, chat behaves as
  before (graceful skip), not a pipeline bug.
- ❌ **No `retrieved` at step 7:** the fact hasn't left the window yet — add 1–2 filler turns.

## Embedder ladder check
- **Default (any Mac):** Ollama off → expect `Apple NLEmbedding`.
- **Upgrade path:** `ollama pull nomic-embed-text`, keep Ollama running, `/clear`, chat again →
  expect `Ollama nomic-embed-text`.

## No-regression checks
- **Short chat** (2–3 messages): no `retrieved` line, normal replies, zero overhead.
- **`/clear`:** index resets — the planted fact can no longer be recalled afterward.

## Relevance gate (hybrid lexical + semantic)
NLEmbedding's cosines are too compressed to separate a genuine match from a topically-adjacent one (in
testing a real recall scored **0.341** while unrelated noise — "octopus" → "coffee shop" — scored
**0.362**). So the gate is **lexical**: a candidate must share a significant keyword with the question
(`kw ≥ 1`), or clear a high semantic bar (`highSemanticBar`, which only a stronger embedder like Ollama
`nomic-embed-text` reaches). Semantic similarity only *ranks* the survivors. Expected: **7 & 8 retrieve
the right exchange; 5, 6 & 9 retrieve nothing.**

Tuning knobs in `ChatMemoryIndex`: `stopwords` (filler words excluded from keywords), `highSemanticBar`
(pure-semantic escape hatch), `questionWeight`. Lexical gating also means retrieval **works with no
embedder at all** (pure keyword recall) — a bonus for the graceful-skip path.
