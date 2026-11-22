# Sources: `@` to look in your notes (and other places), apart from web search

**Status: built (Lasso 0.23.0).** Settled by a design panel (product manager, product designer, UI
designer, UX designer, Claude as moderator) over five rounds. The owner's `@` proposal replaced the first
signed version (round 4); the owner then asked for Lasso to decide by itself without MCP-style context
bloat on local models (round 5, after research on Cloudflare's Code Mode and Anthropic's progressive tool
disclosure). All four signed each version. [`PACKAGES.md`](PACKAGES.md) and [`APP_FLOW.md`](APP_FLOW.md) describe the format and flow; this
records the design and why.

**Where the build differs from the plan below** (simpler, checked by the same tests):

- **No planning call for sources.** Lasso's own ranking keeps at most 2 sources that share words with
  What's in it; running them takes milliseconds on this Mac, and the lexical gate decides whether
  anything reaches the model. So choosing a source costs no model call at all.
- **Tools:** with 3 or fewer installed, all are offered, as before (a currency tool must still hear "$5
  in euros", which shares no words with its description); with more, the 3 that fit the message best
  plus any used last turn. The Agent keeps the 1,500-character budget: it reads its tools once, when it
  starts.

## The problem

Today a package with the `search` surface is an extra source inside **web search**: when the globe is on
and the model decides to search, every enabled search package runs with the query Lasso rewrote for the
web, and all hits are ranked in one list. Right for Tavily and SerpApi; wrong for **My notes** (a
sandboxed script that searches a folder of the user's notes):

1. Notes sit behind the globe, which means "use the internet".
2. Turning the globe on to reach notes also sends the question to Wikipedia, DuckDuckGo, Reddit, Tavily.
3. Local-only mode skips all search, so a source that never leaves the Mac can't run there (its page
   said "Works in local-only mode").
4. Notes compete with web hits in one ranking, under a web-rewritten query.
5. The Agent can't use search packages at all.
6. It doesn't scale: every enabled source runs on every web search.

A user installed My notes, asked "can you access my notes?" with the globe off, and the model invented
"click the Notes icon in your menu bar".

## The design

### `@` looks in a source; `/` runs a command; the globe is the web

- **`@My notes what did we decide on pricing?`** searches My notes for that question. Nothing searches a
  source unless the user mentions it, so ten installed sources cost nothing until one is asked for.
- **`/explain`** still runs a command (*do* something). **`@`** is only for sources (*look in*
  something). Tools stay the model's choice, never `@`.
- **The globe** still means the web in general: the free web sources plus Web packages. A Web package can
  also be `@`-mentioned (`@Tavily`) to search only it, skipping the free sources.

### Lasso decides by itself, without tool bloat

`@` is the override, not the only way. By default Lasso works out which of your sources (and which
package tools) a message needs, and keeps what the model reads small and constant however many packages
are installed.

**Where this comes from.** MCP-style integrations put every tool's definition in every request: five
servers can cost ~134k tokens before a word is said, and a local model reads all of it first.
Cloudflare's **Code Mode** ([blog](https://blog.cloudflare.com/code-mode-mcp/)) gives a model two fixed
tools, `search` and `execute`, so its 2,500-endpoint API fits in ~1,000 tokens; Anthropic's **progressive
disclosure** ([post](https://www.anthropic.com/engineering/code-execution-with-mcp)) loads only the few
relevant tool definitions and filters results before the model sees them. Both ask the model to search
and write code, which a 3 to 9B local model (or Apple's on-device one) does unreliably. Lasso takes the
principles and moves the work into the harness:

1. **Lasso finds the candidates, not the model.** Each source has a one-line **What's in it**; each tool
   has its description. Before a message, Lasso ranks them against the message (and the last exchange)
   with the word matching and embeddings it already runs: no model call, no context. A candidate needs
   word overlap with the message, and only the top 2 to 3 within a margin of the best score survive (a
   relative margin, never a fixed cosine cutoff).
2. **The model sees only those few.** Models that call tools get just the surviving tools' definitions
   (at most 3 per message; this replaces today's 1,500-character total; the 200-character cap per
   description stays). A tool used last turn stays offered next turn, so "and in yen?" works. For
   sources, Lasso's existing planning step (`SearchPlan`, a tiny structured answer that works on every
   backend including Apple's on-device model, no tool calling) gets the surviving sources as a short
   choice list and answers which to look in. With the globe on, it's the same single call that already
   plans the web search.
3. **Nothing survives, nothing runs.** No planning call, no script, no added time.
4. **Results are filtered before the model** (already true): the lexical gate, 3 passages in total,
   4,000 characters per tool result.

Code Mode itself isn't used in chat. It may suit the Agent later, on capable models.

**Defaults.** Sources on this Mac: **automatically**. Web packages (Tavily, SerpApi) have no automatic
mode: they run only inside web search (the globe) or with `@Tavily`, since they spend quota and send the
question off the Mac. Automatic use never skips the cloud Allow card.

**Seeing it, fixing it in one click.**

- Every automatic look is a step: "Looked in My notes · 3 matches · **Answer without it**". The link
  regenerates the reply without that source. The step's menu has "**Only when I @ it**" (then: "My notes
  now waits for @. Undo"). One wrong pick doesn't switch a source off by itself.
- While the planning step runs: "Checking My notes…".
- A miss is fixed with `@`. Lasso adds an offer only when the message clearly points at your own things
  (a source's name, or "I wrote", "my notes"): "Look in My notes for this?", which works like `@`. No
  generic "didn't look" steps: they'd be noise.
- A source that can't answer what was asked says so: "My notes can't search by date yet."

**What's in it.** On each source's page, one editable line (up to 120 characters), generated when the
folder is chosen from its folder and file names, then its headings and most frequent words, e.g. "Flet animations, architecture blueprint,
prompt guides". If it's still empty when the folder has notes (it was empty when chosen), Lasso fills it in
then. Footer: "Lasso reads this to decide when to look. Use the words you'd ask with." Empty:
automatic is off, with "Add a line to What's in it first." Next to it, **Use it: Automatically / Only
when I @ it**.

**The Test card shows Lasso's decision too**: besides "3 files in 12 ms", either "Lasso would look here
for this message" or, in orange, "Lasso wouldn't look here. Add these words to What's in it?" with the
missing words as chips that add them.

### Two kinds of source, derived, never declared

- **On this Mac**: a search package that can't reach the internet: a `script` without `network`, an
  `http` command whose hosts are all loopback, a `shortcut` marked `offline`, or a `prompt`.
- **Web**: every other search package (Tavily, SerpApi, a company wiki API).

Lasso works this out from what the package reaches; there's no new manifest field and nothing to migrate.
The review's "Works in local-only mode" line is computed from it, and the validator fails a package whose
wording would claim otherwise.

### Typing `@`: the picker

The same component and place as the `/` command palette.

- Two groups, **On this Mac** and **Web search**; each row has the package's symbol, its name, and its
  folder or host in secondary text. Typing filters; Return or Tab turns it into a chip.
- Local-only mode: Web rows are dimmed with a lock and can't be picked.
- A source whose folder is missing: an orange row, "Can't find ~/Development/_docs", not pickable.
- Nothing installed: "Nothing to search yet. **Add from Packages**" (opens Settings › Packages).

### The chip stays for follow-ups

- A picked source becomes a chip in the message box's chip row (beside the capture-context chip): the
  same capsule, the package's symbol, its name, ×.
- It stays until × or a new chat, so "and in Q3?" still searches. Several chips can be on at once.
- Each sent message shows a small "@My notes" label, and each reply names what it searched, so a topic
  change is never silent: an unrelated question just gets "Searched My notes · nothing matched".
- When the Agent is on, chips apply to its turn too: Lasso searches first and passes the passages in.

### Discoverability, without trusting the model

- **Placeholder** while the box is empty and a source is installed: "Message… or @ for My notes" (one
  source), "Message… or @ to search" (two or more).
- **Lasso, not the model, spots a source's name.** A message that names an installed source without `@`
  ("can you access my notes?") gets a step: "My notes searches when you type @My notes. **Search it for
  this message**". The link sends it again with the chip on. No search runs on its own. This works the
  same on every model; Apple's on-device and small models can't be relied on to follow a system-prompt
  hint.
- The system prompt also lists installed sources, so a capable model answers truthfully either way.

### Searching

- With the user's own words, never the web rewrite, on every model alike (no tool calling involved).
- **Lexical gate, no cosine floor**: a file matches when it contains at least 2 of the message's content
  words (stop-words removed; the only one, for one-word messages). Embeddings only order what passed.
- **At most 3 passages in total** across all mentioned sources (about 1,200 characters), at least one from
  each source that matched; when one is cut, the step says so. Fenced as content, like screen text.
- A source slower than 5 seconds is skipped for that message: "My notes didn't answer in 5 seconds".

### Consent before notes go to a cloud model

Searching is local; sending what was found to a cloud model isn't. The first time matches from a source
would go to a cloud model, the reply shows Lasso's inline Allow card **before the model is called**:

> Send 3 passages from My notes to Claude?
> standup.md, roadmap.md, pricing.md
> **Allow for My notes** · **This time** · **Don't send**

- **Don't send** answers without them; the step says so.
- Remembered per source and per provider (switching models within a provider doesn't ask; another
  provider does). A custom endpoint on loopback counts as local. Local models never ask.
- Revocable: the package page lists "Allowed to send to: Anthropic" with **Reset**.

### In the reply

- One step per source: "Searched My notes · 3 matches", "Searched My notes · nothing matched".
- When nothing matched, the model is told so for that turn: say it plainly, present nothing as coming
  from the source, describe no buttons or menus, and call an unfamiliar word unknown instead of guessing.
- Sources in separate groups: **From My notes** (`doc.text`, file name, its folder; click opens, ⌥-click
  shows it in Finder) and **From the web** (`link`, title, host).

### "How to use it", on every package

A card, first on each package page, with one row per surface, generated from the manifest **and the
current state**, with the trigger in bold:

| Surface | Line (examples) |
|---|---|
| Source (`at`) | "In chat, type **@My notes** and your question. It searches only the folder you chose." |
| Command (`slash.circle`) | "Type **/explain** in chat." |
| Toolbar (`cursorarrow.click`) | "Lasso some text, then click **Explain simply**." (an author's optional `howTo` line where `when` can't be said in words; otherwise "Appears on some captures") |
| Send to (`square.and.arrow.up`) | "After a capture or a chat reply, choose **Send to › Add to Reminders**." |
| Hotkey (`keyboard`) | "Highlight text in any app and press **⌥⌘E**." / with none set: "Set a shortcut below first." |
| Tool (`bubble.left`) | "Ask in chat; the model uses **Convert currency** when it helps." (its `test.args` example if it has one; never an invented one) |
| Patches | "Changes Lasso's Summarize prompt and toolbar. Nothing to do." |

- Missing setup leads: "Add your API key first", "Choose a notes folder first".
- At most 4 lines. The same lines close the install review. One line atop Settings › Packages: "Type **@**
  in chat to search, **/** to run a command."

### Settings › Packages and the package page

- The Search card splits into **Web search** (built-in web search, Tavily, SerpApi) and **On this Mac**
  (My notes).
- A source's page: "Works in local-only mode" (now true); "Sends the matching passages to your chat
  model. With a cloud model they leave this Mac, after you allow it."; the allowed-providers row.
- **Test card**: a field ("A word from your notes"); "3 files in 12 ms" with the top 3 file names, or "No
  file mentions “meeting”. Checked 214 Markdown files." Error states worded the same everywhere: no folder,
  folder missing, no Markdown files, script failed.

### Naming

The source's own name ("My notes") everywhere; groups "On this Mac" and "Web search"; reply groups "From
My notes" and "From the web". Never the bare word "Sources", and never "tool" next to a source.

## First release

Everything above. Later:

- An index for very large folders (until then, the 5-second step says when a folder is too slow), and
  date filters for "what I wrote last week".
- The Agent's own `search_sources` tool (chips already reach it).
- Categories in Browse once the catalog grows.
- Checking that a loopback `http` source doesn't forward to the internet.

## Checks that must fail if it's wrong

1. No `@`, "can you access my notes?": the step offers @My notes; no script runs; the local test servers
   standing in for Wikipedia, DuckDuckGo, Reddit and Tavily record zero requests.
2. `@My notes`, then a follow-up without `@`: the chip stays and the second search runs; after ×, the next
   message runs no search.
3. `@My notes` with the globe on: My notes receives the user's own text, not the web rewrite; reply
   groups are separate.
4. Two sources mentioned: at most 3 passages in total reach the model.
5. Cloud model: the Allow card appears only for mentioned sources, before the model call; Don't send means
   zero passages at the provider's test server. Allow for Claude, switch to Groq: it asks again. Reset:
   it asks again.
6. Local-only mode: `@My notes` returns results with zero connections off the Mac; `@Tavily` can't be
   picked.
7. A message that misses the gate: zero passages sent, step "nothing matched".
8. A package whose review would claim local-only while it reaches the internet fails the validator.
9. A snapshot test of the generated "How to use it" lines for every bundled and catalog package.
10. **Picks**: 80 labelled messages (with traps: "release notes", "note that…", general questions) on
    Apple's on-device model and a 4B MLX model: wrong looks ≤ 5%, misses ≤ 20%, wrong tool offered or
    called ≤ 5%.
11. **No bloat**: going from 1 to 20 installed packages raises prompt tokens per request by at most 300.
12. **Nothing runs when nothing ranks**: 20 unrelated messages launch zero scripts and make zero
    planning calls; added latency 0 ms. When it does run on MLX, median added time ≤ 0.5 s.
13. Tavily never runs without the globe or `@Tavily` (the test server records zero requests).
14. "Answer without it" sends a request with no passages from that source.

## Decisions and why

| Question | Decided | Why |
|---|---|---|
| What triggers a source? | `@` (the owner's proposal) | Nothing runs unless asked, so it scales; the mention is the user's consent; same on every model. Replaced the signed per-source button that searched every message. |
| Sticky chip or `@` per message? | Sticky, visible, × to remove | Follow-ups ("and in Q3?") would fail silently otherwise; the chip, the message label and the step make it visible. |
| `@` for Web packages? | Yes, to search only that one | `@` means "look only here"; the grouped picker keeps it apart from the globe. |
| `@` for tools? | No | Tools are the model's choice and need arguments; `/` already means "do". |
| Discoverability | Placeholder + Lasso's own name-match step + guide | Small models ignore system-prompt hints (that's how the invented answer happened). |
| Declared `scope` or derived? | Derived | A field that must equal what Lasso derives only adds a way to be wrong. |
| Cloud consent | Ask at sending, per source and provider, revocable | Asks exactly where data leaves the Mac; rare now, since only mentioned sources run. |
| Relevance | Lexical gate, embeddings only order, 3 passages total | Cosine cutoffs are unreliable across embedders here (`APP_FLOW.md`). |
| Guide copy | Generated from the manifest and current state; author's `howTo` where it can't be said | Generated sentences about what a model "will" do, or a key that isn't set, would mislead. |
| Agent | Chips reach its turn now; its own tool later | Cheap, no tool-server change. |
| Who decides without `@`? | Lasso ranks candidates itself; the model picks among at most 3 via the existing structured planning step | Constant context however many packages; works without tool calling; no model call when nothing is relevant. |
| Code Mode? | Its principles, not its mechanism, in chat | Small local models write code unreliably; maybe for the Agent on capable models. |
| Automatic defaults | Sources on this Mac yes; Web packages never | Web packages spend quota and send the question off the Mac; the globe is that consent. |
| Tools | Same ranking, top 3 per message | Replaces a budget that silently drops tools as you install more. |
| Correction | "Answer without it" on the step; "Only when I @ it" in its menu, with Undo | Fixes the answer in one click without turning a source off over one wrong pick. |
| "Didn't look" steps | Only when the message points at your own things | Otherwise noise. |
