# Patch targets

Generated from `PatchTargets` in `Lasso/Packages/PackagePatches.swift` by `PatchTargetsDocTests`:
don't edit by hand. What a package's `patches` can change, and Lasso's own value for each. The
rules are in [PACKAGES.md](PACKAGES.md#patches-changing-lassos-own-content).

| Target | Operations | What it is | Lasso's own |
|---|---|---|---|
| `action.ai.summarize.prompt` | `set` | The instructions behind Summarize. Lasso adds the text after them. | Summarize the on-screen text in 2–3 sentences. Be faithful to the source. |
| `action.ai.grammar.prompt` | `set` | The instructions behind Proofread. Lasso adds the text after them. | 1,799 characters, below |
| `action.ocr.copy.title` | `set` | The name of Copy text in the toolbar, menus and Settings. | Copy text |
| `action.translate.title` | `set` | The name of Translate in the toolbar, menus and Settings. | Translate |
| `action.ai.grammar.title` | `set` | The name of Proofread in the toolbar, menus and Settings. | Proofread |
| `action.ai.summarize.title` | `set` | The name of Summarize in the toolbar, menus and Settings. | Summarize |
| `action.ai.ask.title` | `set` | The name of Ask AI in the toolbar, menus and Settings. | Ask AI |
| `action.qr.open.title` | `set` | The name of Open code in the toolbar, menus and Settings. | Open code |
| `action.color.pick.title` | `set` | The name of Pick color in the toolbar, menus and Settings. | Pick color |
| `action.identify.title` | `set` | The name of Identify in the toolbar, menus and Settings. | Identify |
| `action.lens.search.title` | `set` | The name of Lens in the toolbar, menus and Settings. | Lens |
| `toolbar.order` | `set` | The toolbar's default order. An order you set in Settings › Toolbar comes first. | Lasso's own order |
| `toolbar.hidden` | `set`, `add`, `remove` | Toolbar buttons moved to the … menu by default, until you choose in Settings › Toolbar. | None |
| `chat.suggestions` | `set`, `add`, `remove` | The suggestions on an empty chat (at most 6 show). | What can you do?; Ask about something on screen; Attach a file or image |
| `chat.instructions` | `add` | Text added after the chat model's own instructions, which always come first. | None |

Toolbar ids: `ocr.copy`, `translate`, `ai.grammar`, `ai.summarize`, `ai.ask`, `qr.open`, `color.pick`, `identify`, `lens.search`, `builtin.copyImage`, `builtin.saveImage`, `builtin.sendTo`, or `<package>/<command>` for a package's button.

## `action.ai.summarize.prompt`

```text
Summarize the on-screen text in 2–3 sentences. Be faithful to the source.
```

## `action.ai.grammar.prompt`

```text
You are an expert grammar correction engine.

Correct every grammar, spelling, punctuation, capitalization, verb-tense, subject-verb agreement, pronoun, word-form, article, preposition, and sentence-structure error. A sentence may contain several mistakes — fix all of them, not just the first.

Grammatical correctness comes before preserving exact wording: rewrite words, phrases, clauses, or whole sentences when needed to make the text correct and natural.

Preserve the author's meaning, tone, voice, level of formality, and slang whenever possible. Do NOT:
- rewrite for style or elegance, or make text more formal;
- replace casual phrasing or slang that is already correct;
- swap numbers for words or words for numbers;
- change vocabulary by preference, or add or remove meaning.

Use time expressions as tense cues ("yesterday", "last week" point to past; "tomorrow", "next week" point to future).

If there is nothing to correct — a URL, file path, email address, code, a number, a single token, or text that is already correct — return it EXACTLY as given. Never ask a question, never explain, never refuse.

Output ONLY the corrected text — no explanations, quotes, or labels.

Examples:

Input:
https://www.example.com/appointment-system/taipei
Output:
https://www.example.com/appointment-system/taipei

Input:
she don't like coffee
Output:
She doesn't like coffee.

Input:
I have went to the store yesterday.
Output:
I went to the store yesterday.

Input:
Me and my friend was going to the mall yesterday and we seen a great movie.
Output:
My friend and I were going to the mall yesterday, and we saw a great movie.

Input:
i been using this app for like 2 weeks and honestly its work really good
Output:
I've been using this app for like 2 weeks, and honestly, it works really well.
```
