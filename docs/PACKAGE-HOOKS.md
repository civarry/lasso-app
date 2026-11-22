# Package hooks: Lasso as a host

Status: **built in Lasso 0.27.0** (2026-11-22). Designed by a four-person panel (product, product design,
UI, UX) over two rounds, from the 0.26 live test on a 9B local model. What changed while building it is
under "As built" at the end.

## Why

Every package improvement from 0.20 to 0.26 needed a Lasso release (9 of 11). Each one hit a fixed step
in Lasso: a package can only plug into slots Lasso defined in advance, and Lasso's own pipelines throw
away what a package would need. In the 0.26 live test, four fixes had to go into Lasso (nothing-found
note, stemming, What's in it, the file list), and four cases still fail (typos, Taglish, follow-ups,
"last week") because the source never sees the user's real words.

The owner's rule: **if Lasso lacks something, a package should be able to supply it.** Lasso keeps the
safety rules; packages own behavior.

## The rule (the general part)

Every step a package can take over has the same shape, called a **hook**:

1. **Lasso passes the turn in**, with nothing stripped, plus a contract version (`"hook": "source/1"`).
2. **The package returns a typed result**: a `status` and its data.
3. **Lasso enforces its limits afterwards**: sandbox, local-only, budgets, fencing, consent, deadline.

A hook grows by adding fields to its contract (packages ignore fields they don't know), not by adding
new slots. When a package next needs a Lasso change, the fix is a **new hook point of this shape**,
never a feature built into Lasso. Adding a hook point or a field still needs a Lasso release; the
metric below tells us whether that's rare.

**What Lasso keeps, and no package can change:** the sandbox and what a script can read and write; the
local-only gate; asking before anything goes to a cloud model; at most 3 passages and 1,200 characters
from sources per message; fencing, so content can't steer the model; the deadline (5 s); Lasso's own
"found nothing, say so" instruction; only a person installs or widens a package.

## Hook 1: `source/1`

A search command that declares `"hook": "source/1"` gets the turn instead of Lasso's stripped `query`.

**In (stdin, added to today's fields; `query` is still sent so old scripts keep working):**

| Field | What it is |
|---|---|
| `hook` | `"source/1"` |
| `message` | The user's message as typed (no stop words or date words removed) |
| `previous` | The previous user message and the first 600 characters of the reply, or null |
| `previousSearched` | Whether this source returned passages last turn |
| `intent` | `search`, or `about` ("what's in my notes", the message names only the source) |
| `today`, `timeZone`, `locale` | For "last week", and for the language of the message |

**Out (stdout):**

| Field | What it is | Lasso does |
|---|---|---|
| `status` | `found`, `nothing`, `inventory`, `irrelevant`, `cant` | Picks the step text; `irrelevant` costs zero context |
| `results` | As today (title, url, snippet), plus optional `date` | Budget: 3 passages, 1,200 characters, fenced |
| `searched` | The query it actually ran, if not the user's words ("frozendict") | Step says "Searched frozendict (you typed frozendcit)" |
| `ask` | A corrected query to offer, up to 80 characters | A clickable step for the **user** ("Did you mean frozendict? Search again"), never sent to the model |
| `note` | One fact about the search, up to 160 characters ("No notes dated last week") | Fenced inside the evidence, counted in the budget |

**Its own relevance.** A `source/1` command that declares `"ranks": true` replaces Lasso's 2-word lexical
gate with its own judgement (needed for typos and Taglish). The budget, fencing and consent still apply
to whatever it returns.

**Picking.** A source that returned `found` last turn is a candidate again on the next message (as tools
are today), so follow-ups reach it; it answers `irrelevant` if they don't concern it.

## Hook 2: `describe/1`

A command with `"hook": "describe/1"` runs when the folder is chosen or changes, and at most daily. It
returns the **What's in it** line (up to 120 characters) and up to 100 picking words. Lasso's picker
uses the words (no model call, never shown to the model, zero context). The user can still edit the line.
Replaces Lasso filling it in (0.26's `SourceAbout.fillIfEmpty` becomes the fallback).

## Next, not in the first release: `detect/1`

On capture, given `lines`, returns up to 3 `{kind, value}` items (a table, an address) within 300 ms,
local only; other packages declare `when.detects`. Evidence: table detection was built into Lasso first
(0.24). Built in 0.28 only after `source/1` proves out, with Tables as a package; a `builtin:` runner for
it only if the same package also runs as a plain script and a test shows identical output.

## Not building (each waits for a logged case that fails without it)

A hook that adds context to every message (bloat on a 9B model); panels and code mods (layer 3); scripts
calling Lasso's model; patching the system prompt or tool selection; per-hook switches; a new format
version (`lasso: 2`).

## What the user sees

- **Review (install and update):** new rows in the existing "What it can reach" card, in fixed words:
  "Reads your message and your previous question when it searches" and "Decides which notes are
  relevant, instead of Lasso". An update that adds either gets the **New** tag and goes back through
  review. Not off by default: the hard limits hold either way, and "Answer without it" is on every step.
- **Chat steps** count only what reached the model: "Looked in My notes · sent 2 passages". Never
  "3 matches" when none were sent. One step per contributing package.
- **Typos:** "Searched frozendict (you typed frozendcit)" with one-click undo, or "Did you mean
  frozendict? Search again" when the package isn't sure.
- **Package page:** **Go back to 1.3.0** (Lasso keeps the previous approved copy), because packages now
  carry fixes that used to ship in Lasso releases.
- **Too old a Lasso:** Browse shows "Needs Lasso 0.27"; a refused manifest names the part ("This Lasso
  can't run `ranks` yet").

## For authors

`Tools/replay`: runs a saved set of chat turns through Lasso's real source path against a package
folder and prints, per turn, what the package got, what passed, and what would reach the model. Offline,
no UI. Ships with two sets: the 0.26 live-test turns and a held-out folder that wasn't tuned against.

## Release plan

- **0.27:** `source/1`, `describe/1`, the step wording, Go back, the review rows, `Tools/replay`, and
  My notes 1.4 using all of it (its own file list, stemming and What's in it; Lasso's copies become
  fallbacks).
- **Proof:** My notes **1.5** fixes typos, Taglish, follow-ups and "last week" **with no Lasso change**.
  If 1.5 needs one, the contract was wrong and we fix the contract.
- **0.28:** `detect/1` and Tables as a package, then stop and measure.

## Measuring it

A running list of package improvements, each marked "needed a Lasso release" or not. Target: of the
next 10, at most 1 needs Lasso. Today: 9 of 11.

## Verification (each must be able to fail)

| # | Requirement | Check |
|---|---|---|
| V1 | A `source/1` script gets the raw message | Replay: "what did we decide last week?" reaches the package with "last week" intact |
| V2 | Old search packages keep working | Every catalog package's test runs unchanged on 0.27 (`check.py`) |
| V3 | `ranks: true` can't exceed the budget | A source returning 50 junk hits: at most 3 fenced passages and 1,200 characters reach the model |
| V4 | `ask` never reaches the model | The built prompt for a typo turn contains no suggested word |
| V5 | Steps count only what was sent | The open() encoding turn from the live test doesn't say "matches" when nothing passed |
| V6 | Follow-ups reach the source | Replay: "show me an example" after a lazy-imports turn produces a search step |
| V7 | `irrelevant` costs nothing | A turn where the source answers `irrelevant` sends no source text to the model |
| V8 | Review shows new powers, updates re-review | Installing a package that adds `ranks` shows the row; an update adding it shows New |
| V9 | Go back restores the previous version | Update 1.3.0 to 1.4.0, Go back: the files hash to 1.3.0's |
| V10 | The proof | My notes 1.5 passes the typo, Taglish, follow-up and "last week" turns on the live model with no Lasso diff |
| V11 | Context stays small | 20 installed packages, one `source/1`: the prompt grows by at most its passages plus one 160-character note |

## As built (0.27.0)

- **Wording, after a UX review:** steps say "· sent 2 passages" (the earlier "gave the model 2 passages"
  was cut off in the panel); the typo offer is the link itself, "Did you mean “frozendict”?", under a step
  that says "nothing matched"; the review line is "Picks its own best results instead of Lasso's word
  match". Updates that add a power use the existing **New** tag rather than a new "Wider" one.
- **`irrelevant`** shows no step when Lasso picked the source, and "nothing related" when the user
  @-mentioned it; in that case the model is still told nothing was found.
- **The proof (V10), honestly:** building My notes 1.5 against the contract found two gaps, both fixed
  in Lasso before 0.27.0 shipped: a follow-up with no words to search ("thanks") must not reach the
  source (it would have listed the files), and an @-mentioned source that answers `irrelevant` must still
  count as "found nothing" for the model. Everything else in 1.5 (typo correction, other languages,
  follow-ups, date filters) is package code only. The count starts from 0.27.0.
- **V8** is checked by the rendered README screenshot (`source-hooks-page.png`), not by a unit test.
- **Results:** My notes 1.5 on the live-test turns: 11 of 11 (`lasso-pkg replay`); on held-out notes and
  questions not used for tuning: 17 of 17, against 11 of 17 for 1.3.0.

