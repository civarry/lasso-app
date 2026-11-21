# Lasso packages

Status: **draft, format version 1.** Nothing here is built yet. This document is the contract the
engine, the Settings screens, the developer tools and the catalog are built and tested against; when
code and this document disagree, one of them is a bug, and the fix is decided here first.

The direction: people can change almost anything about Lasso without changing Lasso's code, the way
Stardew Valley players mod almost anything about the game. Anyone can make a package, and each person
decides what they install and how much each package may do: Lasso's job is to make that choice clear
and keep it the user's, not to make it for them.

A package adds things to Lasso (a capture-toolbar button, a "Send to" target, a chat command, a tool
for the model and the Agent, a search source), changes Lasso's own content (the prompts behind its
actions, its suggestions, sounds, colours, wording), or, later, runs a mod program alongside Lasso.
Packages are installed and removed by the user, like packages on Linux, from a public catalog or from
a file.

The words MUST, MUST NOT, SHOULD and MAY are used as in RFC 2119. Every MUST has a check listed in
[Verification](#verification) that fails when the rule is broken.

## Contents

- [Principles](#principles)
- [Three layers](#three-layers)
- [The model: commands](#the-model-commands)
- [The package](#the-package)
- [Commands](#commands): where they appear, what they take, what they give back, when they show
- [Runners](#runners): http, prompt, shortcut, script
- [Templates and responses](#templates-and-responses)
- [Patches: changing Lasso's own content](#patches-changing-lassos-own-content)
- [Settings and keys](#settings-and-keys)
- [Permissions](#permissions)
- [Model and Agent tools](#model-and-agent-tools)
- [Installing, updating, removing](#installing-updating-removing)
- [Code mods (layer 3, planned)](#code-mods-layer-3-planned)
- [Building a package](#building-a-package)
- [The catalog](#the-catalog)
- [Tavily and SerpApi](#tavily-and-serpapi)
- [Examples](#examples)
- [Build order](#build-order)
- [Out of scope for version 1](#out-of-scope-for-version-1)
- [Verification](#verification)

## Principles

1. **The user decides.** Anyone can make a package and anyone can install one, from the catalog or
   from a file. Lasso never blocks an install the user chooses; it shows what the package can do,
   and the user decides how much power it gets.
2. **The user sees what a package can do before it does it.** Every host it reaches, what it reads,
   whether it runs code, and every key it needs is shown at install, and again when an update asks
   for more.
3. **Least power by default, more by choice.** Most packages are data (a web request, a prompt, a
   patch); Lasso does the work and the package can't do anything else. Code runs sandboxed to what
   it declared, unless the user gives that package full access.
4. **Only a person installs.** Packages are installed, updated and given more access only by the user's
   own action: never by a model, the Agent, a web page or the package itself.
5. **Local-only means local-only.** In local-only mode nothing a package does leaves the Mac. One gate
   in the engine enforces it, for every runner, at the moment a command runs.
6. **Small for the model.** A command offered to a model as a tool costs context on every request.
   Tool descriptions are short, only enabled ones are offered, and their total is capped.
7. **Lasso's protections aren't moddable.** Local-only mode, approvals for the Agent, fencing of
   screen text and the review of what a package can do can be turned off by the user in Settings,
   never by a package.
8. **Built-in stays small.** Lasso keeps what makes it work with zero setup (keyless web search, the
   core capture actions). Everything optional is a package, Tavily and SerpApi included.

## Three layers

Like Stardew Valley's content packs and code mods, from least to most power:

| Layer | What it is | Can | Status |
|---|---|---|---|
| **1. Commands** | Data: web requests, prompts, Shortcuts, scripts | Add buttons, Send to targets, chat commands, model tools, search sources | Format version 1 |
| **2. Patches** | Data: edits to Lasso's own content | Change the prompts behind Lasso's actions, its suggestions, toolbar, sounds, colours and wording | Format version 1 |
| **3. Code mods** | A program running beside Lasso, talking to it through an API | React to what happens in Lasso, add panels Lasso draws for it, keep state, anything layers 1 and 2 can't | Planned: [direction](#code-mods-layer-3-planned) |

One package can use any of the layers; the review screen shows what each part does.

## The model: commands

A package provides **commands**. A command is one thing the user or a model can run. It has:

- a **runner**: how it runs (`http`, `prompt`, `shortcut` or `script`);
- **surfaces**: where it appears (toolbar button, Send to, chat command, model tool, search source,
  hotkey);
- an **input**: what it's given (selected text, the image, the app it came from, a search query, tool
  arguments);
- an **output**: what happens with the result (shown, copied, pasted back, opened, saved, used as
  search results);
- optionally **when**: the situations it's offered in (text matching a pattern, a detected address,
  a particular app).

Any runner works on any surface. A script can be a search source (searching your notes folder); a
Shortcut can be a toolbar button or a tool the Agent uses; a prompt can be a chat command.

## The package

A package is either:

- a single file, `<id>.lasso.json`, when it has no other files (`http`, `prompt` and `shortcut`
  commands); or
- a folder, `<id>.lassopkg/`, containing `lasso.json`, `README.md` and any `scripts/`, distributed
  zipped (`<id>.lassopkg.zip`). Required when a command uses `script`.

The manifest is UTF-8 JSON, at most 64 KB; a folder package is at most 5 MB in all.

```json
{
  "lasso": 1,
  "id": "brave-search",
  "version": "1.0.0",
  "name": "Brave Search",
  "summary": "Independent web search results.",
  "author": "Jane Doe",
  "homepage": "https://brave.com/search/api/",
  "icon": { "symbol": "magnifyingglass", "domain": "brave.com" },
  "hosts": ["api.search.brave.com"],
  "settings": [ { "id": "key", "label": "API key", "kind": "secret", "help": "https://api-dashboard.search.brave.com/app/keys" } ],
  "commands": [ { "...": "see Commands" } ]
}
```

| Field | Required | Rules |
|---|---|---|
| `lasso` | yes | Format version, an integer. Lasso MUST refuse a package whose `lasso` is higher than the newest version it reads, with the message "Needs a newer Lasso". |
| `id` | yes | 3 to 40 characters, lowercase `a-z`, `0-9` and `-`, starting with a letter. Unique in the catalog. Never changes once published. |
| `version` | yes | Semantic version `MAJOR.MINOR.PATCH`. |
| `name` | yes | 1 to 40 characters. |
| `summary` | yes | 1 to 120 characters, one sentence saying what it does. |
| `author` | yes | A name or handle. |
| `homepage` | no | An `https` URL. |
| `icon` | no | `symbol`: an SF Symbol name; `domain`: a domain whose logo is shown when online. Folder packages MAY include `icon.png` (at most 256×256). |
| `category` | no | One of `search`, `knowledge`, `productivity`, `writing`, `developer`, `media`, `fun`. Used by Browse. |
| `hosts` | when a command reaches the network | Every host it may contact: exact names, no wildcards, ports or paths. See [Permissions](#permissions). |
| `settings` | no | See [Settings and keys](#settings-and-keys). |
| `requires` | no | Mac apps or command-line tools the package needs. See [script](#script). |
| `limits` | no | `{"daily": n, "monthly": n}`: Lasso stops running the package's network commands once either is reached. |
| `minLasso` | no | The oldest Lasso version that runs it. |
| `commands` | one of `commands` or `patches` | 1 to 12 commands. |
| `patches` | one of `commands` or `patches` | Up to 50 patches. See [Patches](#patches-changing-lassos-own-content). |

Unknown fields, anywhere in the manifest, MUST be rejected by name, so a typo is an error rather than a
package that silently does nothing.

## Commands

```json
{
  "id": "explain",
  "title": "Explain simply",
  "symbol": "lightbulb",
  "surfaces": ["toolbar", "slash"],
  "input": ["text"],
  "when": { "minLength": 40 },
  "run": { "prompt": "Explain this so a 10-year-old understands it, in at most 5 sentences:\n\n{{text}}" },
  "output": "markdown"
}
```

| Field | Rules |
|---|---|
| `id` | `a-z`, `0-9`, `-`, unique in the package. |
| `title` | Shown on buttons and menus, at most 24 characters. |
| `symbol` | An SF Symbol for buttons. Defaults to the package's icon. |
| `surfaces` | One or more, below. |
| `input` | What the command takes, below. |
| `when` | Optional, below. |
| `run` | Exactly one runner, see [Runners](#runners). |
| `output` | What happens with the result, below. |
| `tool` | Required when `surfaces` has `tool`. See [Model and Agent tools](#model-and-agent-tools). |
| `test` | Sample input for Test buttons and CI: `text`, `query`, `args` or `image` (a file in a folder package). Required for `search` commands. |

### Surfaces

| Surface | Where it appears | Notes |
|---|---|---|
| `toolbar` | A button in the capture toolbar, after Lasso's own | The user can hide or reorder it like any action. |
| `send` | The "Send to" menu on a capture and on chat replies | For commands that deliver something somewhere. Output MUST be `notify`, `copy` or `open`. |
| `slash` | A chat command, `/<command-id>` | Runs on what's typed after it, or the last reply. Lasso's own names (`new`, `clear`, `copy`, `about`, `web`, `help`) are reserved; when two packages use the same id, both become `/<package-id>-<id>`. |
| `tool` | A tool for the chat model and Lasso's Agent | See [Model and Agent tools](#model-and-agent-tools). |
| `search` | A source for Lasso's web search (chat, Identify, Agent) | `input` MUST be `query`, `output` MUST be `results`. |
| `hotkey` | Listed in Settings › Shortcuts under Highlighted text; the user can assign a key that runs it on the text highlighted in the frontmost app | The package never assigns a key itself. Hotkeys are stored as `pkg.<package-id>.<command-id>`, cleared on Remove, and checked for conflicts with Lasso's own. `source.url` is empty for hotkeys. |

### Input

| Input | Is |
|---|---|
| `text` | The selected or recognized text of a capture, the text after a `/command`, or a reply's text. |
| `image` | The captured image (a PNG file for `shortcut` and `script`). A `prompt` command with `image` is offered only when the chosen model sees images. |
| `source` | Where it came from, when Lasso knows: the app's name and bundle id, and the page URL in a browser. |
| `query` | A search query (the `search` surface). |
| `args` | The model's tool arguments (the `tool` surface). |

### Output

| Output | What happens |
|---|---|
| `markdown` | Shown in the result card, or as a chat reply. |
| `copy` | Copied to the clipboard; "Copied" is shown. |
| `replace` | Pasted over the highlighted text (like Lasso's Proofread highlighted text). Only on the `hotkey` surface: a capture's text was read from pixels and has nothing to paste over. One Undo restores the original. |
| `open` | The result is a URL, opened in the default app. Only from the `http` runner, whose address is a template on a declared host: a model's answer can't choose what opens (text captured from a page could steer it to any site). |
| `image` | Shown as an image. |
| `file` | A file saved to `~/LassoWorkspace/<package-id>/`, shown with Open and Show in Finder. |
| `notify` | A short confirmation is shown, for "Send to" commands: the `answer` value when it's 60 characters or less, otherwise "Done". |
| `results` | Search results (the `search` surface). |

### When

Narrows where a command is offered, so the toolbar shows "Track package" only when there's a tracking
number. All conditions given must hold. In the capture toolbar a command whose `match`, `detects`, `apps`
or `hasImage` fails is hidden, and one whose only failure is length is greyed ("Select more text"). In
chat, `apps` and `hasImage: true` never hold (there's no source app or image), and the other conditions
are tested against the typed text or the reply.

| Condition | Holds when |
|---|---|
| `match` | The text matches this regular expression (ICU syntax, at most 200 characters, tested against at most 10,000 characters of text, given up after 50 ms). |
| `detects` | Lasso's data detector found one of: `link`, `email`, `phone`, `address`, `date`, `flight`, `tracking`, `money`. (The first five come from Foundation's data detector, which Lasso uses today; `flight`, `tracking` and `money` need Apple's DataDetection framework added to it.) |
| `apps` | The capture came from one of these bundle ids. |
| `minLength`, `maxLength` | The text's length in characters. |
| `hasImage` | `true`: only image captures; `false`: only text. |

## Runners

### http

Calls a web service. Lasso makes the request; the package only describes it.

```json
"run": {
  "http": {
    "method": "POST",
    "url": "https://api.todoist.com/rest/v2/tasks",
    "headers": { "Authorization": "Bearer {{settings.key}}" },
    "json": { "content": "{{text}}" }
  },
  "answer": "url"
}
```

| Field | Rules |
|---|---|
| `http.method` | `GET` (default) or `POST`. |
| `http.url` | An absolute `https` URL whose host is in `hosts` (or a `server` setting's base URL). Templates only in the path and query, never the scheme or host. |
| `http.query`, `http.headers` | Maps whose values are templates. `Host`, `Content-Length`, `Cookie` and `Connection` can't be set. |
| `http.json` / `http.form` | A body; string values inside are templates. At most one. |
| `http.timeout` | Seconds, 1 to 20, default 8. |
| `results` | For `output: "results"`: `list` is the path to the array; `title` (required), `url`, `snippet` are paths in each item; `limit` 1 to 10, default 10. Results are labelled with the package's name. |
| `answer` | For other outputs: the path to the value to use. Without it, the response body as text, up to 4,000 characters. |
| `role` | For `search`: `primary` (asked on every search, its results first) or `reserve` (asked only when the other sources returned fewer than 5 results). Default `primary`. |

With `output: "open"`, Lasso builds the URL and opens it in the browser without fetching it itself.
Lasso adds `User-Agent: Lasso/<version>` and nothing else: no cookies, no shared state between packages.

### prompt

Runs a prompt on the model chosen in Lasso's Settings. No network of its own: it works in local-only
mode whenever that model is local.

```json
"run": { "prompt": "Make up to 8 flashcards from this text, as **Q:** and **A:** pairs.\n\n{{text}}", "system": "Be concise." }
```

`prompt` at most 4,000 characters; optional `system` at most 1,000. Available values: `text`,
`source.app`, `source.url`, `language` (the Mac's language), `args.<name>`, `settings.<id>`. Captured
text is fenced as content, the way Lasso fences screen text today, so instructions inside it aren't
followed. With the `image` input the image is attached for a model that sees.

### shortcut

Runs one of the user's Shortcuts with `/usr/bin/shortcuts`. Nothing new runs on the Mac: it's Apple's
app running a Shortcut the user has, which reaches Reminders, Notes, Calendar, Files, HomeKit and most
apps without an API.

```json
"run": {
  "shortcut": {
    "name": "Add to Reminders from Lasso",
    "get": "https://www.icloud.com/shortcuts/0123456789abcdef",
    "offline": true
  }
}
```

| Field | Rules |
|---|---|
| `name` | The Shortcut's exact name. |
| `get` | An `https://www.icloud.com/shortcuts/` link to the Shortcut, shown as "Get the Shortcut" while the user doesn't have one by that name. |
| `offline` | `true` when the Shortcut works without the internet. Default `false`. |
| `timeout` | Seconds, 1 to 120, default 30. |

The input is written to a file (`.txt` for text, `.png` for an image) and passed with `--input-path`;
the output is read from `--output-path`. Lasso checks the Shortcut exists (`shortcuts list`) before
offering the command as runnable. Shortcuts runs with the user's own permissions and can reach the
internet, so a `shortcut` command is labelled "Runs your Shortcut" at install, and is paused in
local-only mode unless marked `offline` (the review screen says that's the author's word, not
something Lasso can check).

### script

Runs a program from the package's folder on the Mac, in a sandbox. For anything the other runners
can't do: converting files with pandoc, ImageMagick or ffmpeg, a local Python model, parsing with `jq`,
searching a folder of notes.

```json
"run": { "script": { "path": "scripts/to-csv.py", "timeout": 30 } }
```

| Field | Rules |
|---|---|
| `path` | A file inside the package's `scripts/` folder, executable, starting with a `#!` line. |
| `network` | `true` if the script needs the internet. Default `false`. |
| `timeout` | Seconds, 1 to 300, default 30. The script and everything it started are stopped at the limit. |

**Protocol.** Lasso starts the script in its data folder (the working directory has to be inside the
sandbox, or shells fail to start cleanly), with an environment of only: `PATH` (`/opt/homebrew/bin`,
`/usr/local/bin` and the system folders), `HOME` set to the package's data folder, `TMPDIR` set to a
fresh folder, `LANG`, and one `LASSO_SECRET_<SETTING>` variable per `secret` setting. On standard
input it writes one JSON object, with only the inputs the command declares and the non-secret
settings:

```json
{ "command": "to-csv", "text": "…", "image": "/path/to/input.png",
  "source": { "app": "Safari", "url": "https://…" }, "query": "…", "args": {}, "settings": { "style": "Short" } }
```

The script writes its result to standard output, either plain text (used as is) or one JSON object:

| For output | Write |
|---|---|
| `markdown`, `copy`, `replace`, `notify` | `{ "text": "…" }` |
| `open` | `{ "url": "https://…" }` |
| `image`, `file` | `{ "path": "…" }`, a file in its data folder or `TMPDIR` |
| `results` | `{ "results": [ { "title": "…", "url": "…", "snippet": "…" } ] }` |

A non-zero exit is a failure, and the last line of standard error is shown. Output over 4 MB is cut
off. Lines on standard error starting with `progress:` are shown while it runs.

**Sandbox.** The script runs under macOS's `sandbox-exec` with a profile Lasso generates from the
package's permissions:

- it writes only to its data folder (`~/Library/Application Support/Lasso/PackageData/<id>/`), its
  `TMPDIR`, and `~/LassoWorkspace/<id>/` for `file` output;
- it reads the system, its own package folder, the input files and folders the user granted, but not
  the rest of the home folder;
- it has no network unless `network` is `true` (labelled "Can reach the internet": the sandbox can't
  limit it to `hosts`, and the review screen says so), and never in local-only mode;
- it can't reach Lasso's preferences, Keychain items or other packages' data.

**Folders.** A command that needs a folder (a notes folder to search) declares a `folder` setting;
the user picks it at install in the standard Open panel, and only that folder becomes readable.

**Requirements.** `requires` lists what must be installed, for example
`[{ "command": "pandoc", "install": "brew install pandoc" }]` or `[{ "app": "com.apple.Notes" }]`.
Lasso checks them; a command whose requirement is missing shows "Needs pandoc" with the install line to
copy, and doesn't run. Lasso never installs anything itself.

**Labelled clearly.** A package with a `script` command shows "Runs code on your Mac" at install, with
its script files viewable. An update that changes any script file always shows the review again.

**Full access, the user's choice.** In a package's Settings page the user MAY switch its scripts to
**Full access**, after a warning that says what it means: "This package's scripts can do anything your
account can: read your files, reach the internet, run other programs." With full access a script
runs without the sandbox, still with Lasso's environment (no Lasso keys beyond its own secrets) and
its time limit. It is per package, off by default, never set by a package or an update, shown on the
package's row, and can be switched off at any time. Packages loaded in Developer mode from the user's
own folder MAY start with full access, since the user wrote them; local-only mode still applies to
them through Lasso's own gates, but a full-access script's network can't be cut off by Lasso, which the
warning says.

## Templates and responses

`{{name}}` is replaced by a value: the inputs (`text`, `query`, `source.app`, `source.url`),
`args.<name>`, `settings.<id>`, and `language`. Values are escaped for where they land: percent-encoded
in a URL, JSON-escaped in a JSON body, form-encoded in a form body. A header value containing a line
break is refused. A template naming something the command doesn't have MUST make the package invalid
at install time. There are no expressions, conditions or loops.

`http` responses must be JSON, at most 2 MB. Text taken from them has HTML tags removed and common
entities decoded (services mark matches with tags), since it's shown and used as plain text. A path is dot-separated keys and array indexes
(`web.results`, `data.0.text`); a missing path yields nothing. Everything a package returns, from any
runner, is untrusted: Lasso trims it (titles 200 characters, snippets 500, tool answers 4,000) and
gives it to models fenced as content, never as instructions.

A failure (non-2xx, a timeout, a non-zero exit) shows "<name> didn't work: <reason>" where the user
asked for it, and is skipped silently in a background search.

## Patches: changing Lasso's own content

Lasso's built-in content becomes data that packages can change, the way Content Patcher changes
Stardew Valley's. A package's `patches` list edits named entries; Lasso applies every enabled package's
patches over its defaults when packages change.

```json
"patches": [
  { "target": "action.ai.summarize.prompt", "set": "Summarize this as at most 5 bullet points:\n\n{{text}}" },
  { "target": "chat.suggestions", "add": { "title": "What's on my calendar today?" } },
  { "target": "toolbar.order", "set": ["translate", "ocr.copy", "study-tools/explain", "ai.summarize"] },
  { "target": "sound.reply.done", "set": "sounds/chime.caf" },
  { "target": "theme.accent", "set": "teal" },
  { "target": "string.chat.placeholder", "set": "Ask me anything…" }
]
```

**What can be patched (version 1):**

| Target | Is | Operations |
|---|---|---|
| `action.<id>.prompt`, `action.<id>.title` | The prompt and label of a built-in action (`ai.ask`, `ai.summarize`, `ai.grammar`, `translate`, `identify`) | `set` |
| `toolbar.order`, `toolbar.hidden` | The capture toolbar's order and hidden buttons, built-in and package ones | `set`, `add`, `remove` |
| `chat.suggestions` | The suggestions on the empty chat | `set`, `add`, `remove` |
| `chat.instructions` | Extra instructions added to the chat model's own (never replacing them) | `add` |
| `sound.<event>` | The sound for `capture`, `send`, `reply.done`, `error` (a `.caf`, `.aiff` or `.wav` file in the package, at most 1 MB) | `set` |
| `theme.<token>` | Colours from Lasso's palette (`accent`, `bubble`, `panel`), by name, so every theme stays readable | `set` |
| `string.<key>` | Lasso's interface wording, by key; a set of them is a translation of Lasso | `set` |

Lasso lists the patchable keys and their defaults in `docs/patch-targets.md`, generated from the code so
it can't go stale. Built-in content moves into data files (`Lasso/Content/`) to make this possible.

**Rules:**

- A target not in the list, or an operation it doesn't allow, makes the package invalid.
- Patches can't reach Lasso's protections: the fencing of screen text, the local-only gate, approvals
  and the review screen aren't patch targets, and `chat.instructions` only adds text after Lasso's own,
  which keeps its safety instructions first.
- **Order:** patches apply in the order the user sets in Settings › Packages (newest install last by
  default); for the same target a later `set` wins and `add`s accumulate. Settings shows, for each
  target changed by more than one package, which one is in effect.
- **Undo:** turning a package off or removing it restores what its patches changed, with no trace.
- A patched prompt keeps the template values of the original (`{{text}}` and so on) and is validated
  like a command's.
- Review: the install screen lists every patch ("Changes the Summarize prompt"), with a Before/After view
  for prompts.

## Settings and keys

```json
"settings": [
  { "id": "key", "label": "API key", "kind": "secret", "help": "https://example.com/keys" },
  { "id": "notes", "label": "Notes folder", "kind": "folder" },
  { "id": "style", "label": "Style", "kind": "choice", "options": ["Short", "Detailed"], "default": "Short" }
]
```

| Kind | Stored | Notes |
|---|---|---|
| `secret` | Keychain, `package.<id>.<setting>` | Never shown again in full; sent only to the package's own hosts or its script; replaced by `•••` wherever a request or run is logged or shown (a key in a URL, like SerpApi's, included). |
| `text` | Preferences | Plain values, such as a database id. |
| `choice` | Preferences | One of `options`. |
| `toggle` | Preferences | `true` or `false`. |
| `server` | Preferences | The base URL of a server the user runs (SearXNG). Its host is allowed and shown at install. `http` only for this Mac (`localhost`, `127.0.0.1`, `::1`). |
| `folder` | A security-scoped bookmark | Picked in the Open panel; the only folder a script can read beyond its own. |

At most 8 settings. `help` is an `https` link shown as "Get a key".

## Permissions

What the review screen shows, and what enforces it:

| Permission | Comes from | Enforced by |
|---|---|---|
| Reaches these hosts | `hosts`, `server` settings | The http engine refuses any other host, including after a redirect. |
| Can reach the internet (any host) | a script's `network: true` | The sandbox; local-only mode removes it. |
| Runs your Shortcut | a `shortcut` command | Only the named Shortcut is run. |
| Runs code on your Mac | a `script` command | The sandbox profile. |
| Reads what you lasso | `input` of `text`, `image`, `source` | Only those values are passed. |
| Reads this folder | a `folder` setting | The sandbox profile and the bookmark. |
| Changes text in your apps | `output: "replace"` | Only from the user's own hotkey, never from a model. |
| Needs a key | `secret` settings | The Keychain, per package. |
| Changes Lasso's content | `patches` | Only the listed targets; undone when the package is off. |
| Full access | the user, per package | Nothing: that's what it means. Shown on the package's row, revocable. |

**Local-only mode:** `http` to hosts off the Mac, Shortcuts not marked `offline`, and scripts' network
are paused and shown as paused. `prompt` commands (on a local model), scripts without network, and
`http` to a `server` on this Mac keep working. The check runs in the engine at the moment a command
runs, not only in the interface.

A package reads only its own settings: never another package's, never Lasso's own keys.

## Model and Agent tools

Commands with the `tool` surface are offered to the chat model (when it supports tools) and to Lasso's
Agent (through Lasso's tool server).

```json
"tool": { "name": "convert_currency", "description": "Convert an amount between currencies at today's rate.",
          "args": { "amount": "number", "from": "string", "to": "string" } }
```

- `name`: starts with `a-z`, then `a-z`, `0-9`, `_`, at most 40 characters. When two packages use the
  same name, or a name Lasso or the Agent already has (`web_search`, `look_at_screen`, `terminal`,
  `read_file`…), it's offered as `<package_id>_<name>` (`-` becomes `_`).
- `description`: at most 200 characters.
- `args`: up to 6, each `string`, `number` or `boolean`, all required. The model's values fill
  `{{args.<name>}}`. A command with the `args` input has `tool` as its only surface (nowhere else
  fills them in). A command with the `text` input needs a `text` argument, which fills `{{text}}`, so
  one command can be Send to and a tool (the Reminders example). In a `prompt`, arguments are fenced
  like `{{text}}`: a model may put what it read on a page into them.
- `output`: `markdown`, `copy`, `notify` or `open`. What a tool returns to the model is the answer, or
  for `copy`, `notify` and `open` what was done ("Opened https://…"), trimmed to 4,000 characters and
  fenced as content.
- **Who's offered them:** the chat model when it can call tools (Ollama models that support tools,
  cloud models), with or without web search on; and Lasso's Agent. Apple Intelligence and MLX don't
  call tools in chat, so there they're offered only to the Agent. A tool whose package is missing a key
  or paused in local-only mode isn't offered at all.
- **Budget:** the descriptions of all offered tools together are capped at 1,500 characters (about
  400 tokens). Tools are counted in Settings order; one that doesn't fit isn't offered, and Settings ›
  Packages › Tools for models shows it as over the limit, with a switch per tool to choose which are
  offered. Turning a tool off there leaves the command's other surfaces alone. `search` commands aren't
  tools: they feed Lasso's one web search, so ten search packages cost the model nothing extra.
- **Asking first:** when a model runs a command whose output isn't `markdown` (it copies, notifies or
  opens), an `http` command whose method isn't `GET` (it can create or send something), or any
  `shortcut` or `script` command, Lasso MUST show what will run with what input and wait for Allow.
  `GET` and `prompt` commands with `markdown` output run without asking. A model can never run a
  `replace` command. The card is Lasso's own, in the reply: for the chat model and for the Agent,
  whose tool call is held open until the user answers (Hermes's approvals only cover its own
  commands). Deny, stopping the reply, or no answer within 280 seconds returns "The user didn't allow
  this" to the model, and nothing runs. Lasso checks local-only mode again after the answer.
- **The Agent's list stays current:** Lasso's Hermes reads the tool list when it starts, so turning a
  `tool` command on or off, or installing or removing a package with one, MUST restart Lasso's Agent
  before its next turn.

## Installing, updating, removing

**Sources:** Browse (the catalog); **+** with a file or folder dropped or chosen, or JSON pasted; a
`lasso://install?id=<id>` link, which opens Browse at that package and never installs by itself.

**Review before install.** Lasso validates everything above and shows: name, author, where it comes
from (Catalog, or "From a file: not reviewed"), each command with where it appears, the permissions
table filled in, and the keys it asks for. An invalid package lists every problem with the field it's
in.

**Installed packages** live in `~/Library/Application Support/Lasso/Packages/<id>/`, are listed in
Settings › Packages with an on/off switch per package and per command, and are re-validated at every
launch.

**Updates** come from the catalog, are never automatic, and are listed like system updates. If an
update widens permissions (new hosts, network, a new runner, new inputs, new settings) or changes a
script, the review is shown again with what's new highlighted. Settings carry over when their ids are
unchanged.

**Removing** deletes the package, its preferences, Keychain items, folder bookmarks and data folder.
Files it saved to `~/LassoWorkspace/<id>/` are the user's and are left, and so are its usage counts, so
removing and adding it again can't spend a free tier twice in one month.

**Same id:** a higher version updates; the same or a lower one is refused ("Already installed").

**Only a person installs.** Install, update and full access happen only from the user's own clicks in
Lasso. A model, the Agent, a `lasso://` link or a package can open the review screen at most; none can
complete it. Package files in the Packages folder changed by anything but Lasso are noticed at the next
launch, and the package is turned off until the user reviews it again. Its switch can't turn it back on:
only the review's **Turn On** can, after showing what changed against the approved copy, which Lasso
keeps in its own preferences (a copy kept beside the package's files could be edited with them).

## Code mods (layer 3, planned)

Not part of format version 1. Recorded here so layers 1 and 2 are built to lead into it, and decided in
full in a later version of this document before any of it is built.

- **A program beside Lasso, never inside it.** A mod runs as its own process, started and stopped by
  Lasso, talking to it over a documented, versioned API (JSON messages on standard input and output).
  Lasso has no stable way to load plugin code into itself (Swift has no stable plugin interface the way
  C# does for Stardew's SMAPI), and a mod that crashes or hangs mustn't take Lasso with it.
- **Events in:** a capture was taken, a message was sent, a reply is streaming or finished, the Agent
  ran a tool, the panel opened or closed, a timer the mod set fired.
- **Calls out:** add a message or card to the chat, show a notification, run a command, register and
  remove commands while running, read and write the mod's own saved data, and show panels.
- **Panels Lasso draws.** A mod describes a panel (stacks, text, images, buttons, lists, grids, progress,
  text fields) and Lasso draws it with its own components; clicks and typing go back to the mod. No
  web views and no drawing code inside Lasso, so a mod can't read the rest of the screen or imitate
  Lasso's own prompts.
- **Access:** the same model as scripts: sandboxed to what it declared by default, full access by the
  user's choice. Reading the selection or the screen, the network and folders each need the user's OK.

## Building a package

**Developer mode** (Settings › Packages › Developer):

- **Load a folder** to run a package from disk; it reloads when a file changes.
- **Run** any command with sample text, an image or tool arguments, and see the request and response,
  or the script's input, output, standard error and exit code, with secrets shown as `•••`.
- **Validate** shows every problem, the same checks as install and CI.
- **New package** creates a starter folder from a template: web search, Send to a service, prompt
  button, Shortcut, script.

**`lasso-pkg`**, a command-line build of the same validator and runner, for editors and CI:

```
lasso-pkg new script my-package      # a starter from a template
lasso-pkg validate ./my-package      # every rule in this document
lasso-pkg run ./my-package to-csv --text "a,b\n1,2"
lasso-pkg pack ./my-package          # the .lassopkg.zip to share
```

`schema/v1.json` (JSON Schema) gives editors completion and errors as you type.

## The catalog

A public GitHub repository, `civarry/lasso-packages`:

```
packages/<id>/lasso.json, README.md, scripts/…   a package
index.json                                         generated by CI, never edited by hand
schema/v1.json                                     JSON Schema
templates/                                         what "New package" starts from
CONTRIBUTING.md                                    how to write, test and submit a package
```

`index.json` lists for each package: `id`, `version`, `name`, `summary`, `author`, `category`, its
commands' titles and surfaces, its permissions, `minLasso`, the download URL and SHA-256. Lasso fetches
it only when the user opens Browse or checks for package updates (never in local-only mode), and
refuses a download whose SHA-256 doesn't match.

**Every pull request:** CI runs `lasso-pkg validate` on each changed package, checks `id` matches the
folder, the version went up and the README states what it sends where and what it needs, and runs
each command's `test` where it needs no key or tool CI lacks. A maintainer reads every script line by
line before merging. Merging regenerates `index.json`; merging is publishing.

## Tavily and SerpApi

Their Swift code is removed; they become catalog packages (`tavily`, `serpapi`, in
[Examples](#examples)). For people upgrading:

- If a Tavily or SerpApi key is saved, Lasso installs the package once, from a copy bundled with that
  release (no download), moves the key to the package's Keychain item, and turns it on only if that
  connector was on (a saved key is never thrown away). Search behaves as before: Tavily `primary`,
  SerpApi `reserve`, the same limits.
- Without a saved key nothing is installed; they're in Browse like any package.
- This month's and today's use carries over to the package's `limits`, so the update can't spend a
  free tier twice in one month.
- The migration runs once and is recorded, so removing the package afterwards is final.

## Examples

### Tavily: search, http

```json
{
  "lasso": 1, "id": "tavily", "version": "1.0.0", "name": "Tavily",
  "summary": "Web search tuned for AI: clean, ranked results.", "author": "Lasso",
  "homepage": "https://tavily.com", "category": "search",
  "icon": { "symbol": "magnifyingglass.circle", "domain": "tavily.com" },
  "hosts": ["api.tavily.com"],
  "settings": [ { "id": "key", "label": "API key", "kind": "secret", "help": "https://app.tavily.com/" } ],
  "limits": { "daily": 40, "monthly": 960 },
  "commands": [ {
    "id": "search", "title": "Tavily", "surfaces": ["search"], "input": ["query"], "output": "results",
    "run": {
      "http": { "method": "POST", "url": "https://api.tavily.com/search",
                "headers": { "Authorization": "Bearer {{settings.key}}" },
                "json": { "api_key": "{{settings.key}}", "query": "{{query}}", "max_results": 6, "search_depth": "basic" } },
      "role": "primary",
      "results": { "list": "results", "title": "title", "url": "url", "snippet": "content", "limit": 6 }
    },
    "test": { "query": "lasso app" }
  } ]
}
```

### SerpApi: search, http, reserve

```json
{
  "lasso": 1, "id": "serpapi", "version": "1.0.0", "name": "SerpApi",
  "summary": "Google results, used when other sources come back thin.", "author": "Lasso",
  "homepage": "https://serpapi.com", "category": "search",
  "icon": { "symbol": "magnifyingglass.circle.fill", "domain": "serpapi.com" },
  "hosts": ["serpapi.com"],
  "settings": [ { "id": "key", "label": "API key", "kind": "secret", "help": "https://serpapi.com/manage-api-key" } ],
  "limits": { "daily": 10, "monthly": 240 },
  "commands": [ {
    "id": "search", "title": "SerpApi", "surfaces": ["search"], "input": ["query"], "output": "results",
    "run": {
      "http": { "url": "https://serpapi.com/search.json",
                "query": { "engine": "google", "num": "8", "q": "{{query}}", "api_key": "{{settings.key}}" } },
      "role": "reserve",
      "results": { "list": "organic_results", "title": "title", "url": "link", "snippet": "snippet", "limit": 6 }
    },
    "test": { "query": "lasso app" }
  } ]
}
```

### Study tools: prompt buttons and a chat command, works offline

```json
{
  "lasso": 1, "id": "study-tools", "version": "1.0.0", "name": "Study tools",
  "summary": "Explain and flashcards for anything you lasso.", "author": "Lasso", "category": "writing",
  "commands": [
    { "id": "explain", "title": "Explain simply", "symbol": "lightbulb", "surfaces": ["toolbar", "slash"],
      "input": ["text"], "when": { "minLength": 40 }, "output": "markdown",
      "run": { "prompt": "Explain this so a 10-year-old understands it, in at most 5 sentences:\n\n{{text}}" } },
    { "id": "flashcards", "title": "Flashcards", "symbol": "rectangle.on.rectangle", "surfaces": ["toolbar"],
      "input": ["text"], "when": { "minLength": 200 }, "output": "markdown",
      "run": { "prompt": "Make up to 8 flashcards from this text, each as **Q:** question then **A:** answer.\n\n{{text}}" } }
  ]
}
```

### Track package: a contextual button that opens a page

```json
{
  "lasso": 1, "id": "track-package", "version": "1.0.0", "name": "Track package",
  "summary": "Opens tracking for a parcel number you lasso.", "author": "Lasso", "category": "productivity",
  "hosts": ["parcelsapp.com"],
  "commands": [ {
    "id": "track", "title": "Track package", "symbol": "shippingbox", "surfaces": ["toolbar"],
    "input": ["text"], "when": { "detects": ["tracking"] }, "output": "open",
    "run": { "http": { "url": "https://parcelsapp.com/en/tracking/{{text}}" } }
  } ]
}
```

### Reminders: a Shortcut as Send to and as a tool

```json
{
  "lasso": 1, "id": "reminders", "version": "1.0.0", "name": "Reminders",
  "summary": "Add what you lasso, or what the Agent finds, to Reminders.", "author": "Lasso", "category": "productivity",
  "commands": [ {
    "id": "add", "title": "Add to Reminders", "symbol": "checklist", "surfaces": ["send", "tool"],
    "input": ["text"], "output": "notify",
    "run": { "shortcut": { "name": "Add to Reminders from Lasso",
                           "get": "https://www.icloud.com/shortcuts/0123456789abcdef", "offline": true } },
    "tool": { "name": "add_reminder", "description": "Add a reminder to the user's Reminders.", "args": { "text": "string" } }
  } ]
}
```

### Table to CSV: a script with file output

`table-to-csv.lassopkg/lasso.json`:

```json
{
  "lasso": 1, "id": "table-to-csv", "version": "1.0.0", "name": "Table to CSV",
  "summary": "Turns a table you lasso into a CSV file.", "author": "Lasso", "category": "developer",
  "commands": [ {
    "id": "to-csv", "title": "Table to CSV", "symbol": "tablecells", "surfaces": ["toolbar"],
    "input": ["text"], "when": { "match": "\\t|\\S\\s{2,}\\S" }, "output": "file",
    "run": { "script": { "path": "scripts/to-csv.py", "timeout": 10 } },
    "test": { "text": "Name  Age\nAda  36\nAlan  41" }
  } ]
}
```

`table-to-csv.lassopkg/scripts/to-csv.py`:

```python
#!/usr/bin/env python3
import csv, json, os, re, sys
data = json.load(sys.stdin)
rows = [re.split(r"\t|\s{2,}", line.strip()) for line in data["text"].splitlines() if line.strip()]
path = os.path.join(os.environ["TMPDIR"], "table.csv")
with open(path, "w", newline="") as f:
    csv.writer(f).writerows(rows)
print(json.dumps({"path": path}))
```

### My notes: a script as a search source, offline

```json
{
  "lasso": 1, "id": "notes-search", "version": "1.0.0", "name": "My notes",
  "summary": "Adds a folder of Markdown notes to Lasso's search.", "author": "Lasso", "category": "knowledge",
  "settings": [ { "id": "notes", "label": "Notes folder", "kind": "folder" } ],
  "requires": [ { "command": "rg", "install": "brew install ripgrep" } ],
  "commands": [ {
    "id": "search", "title": "My notes", "surfaces": ["search"], "input": ["query"], "output": "results",
    "run": { "script": { "path": "scripts/search.sh", "timeout": 5 } },
    "test": { "query": "meeting" }
  } ]
}
```

## Build order

Each step ships on its own, with its checks from [Verification](#verification), the README and
`docs/APP_FLOW.md` updated, and is usable without the steps after it.

1. **Search packages** (built: Lasso 0.17.0). The format, validator and templates; the `http` runner with the `search` surface;
   installing from **+** (a file, a folder or pasted JSON) with the review; Settings › Packages with
   per-package settings, keys and Test; Tavily and SerpApi moved to packages;
   `docs/CONTRIBUTING-PACKAGES.md` and `docs/packages/schema-v1.json` (they move to the catalog in
   step 6). This replaces today's Search API Keys page. Until the catalog exists, **+** also offers
   the packages bundled with Lasso (Tavily, SerpApi).
2. **Buttons and commands** (built: Lasso 0.18.0). The `prompt` runner; `toolbar`, `slash`, `send` and `hotkey` surfaces;
   `when`; the `markdown`, `copy`, `replace`, `open` and `notify` outputs.
3. **Tools** (built: Lasso 0.19.0). The `tool` surface for the chat model and the Agent, the `args`
   input, the tool budget, and asking first.
4. **Shortcuts and scripts.** Both runners, the sandbox, `requires`, folders, full access, `file` and
   `image` outputs.
5. **Patches.** Built-in content moved to data files, `docs/patch-targets.md`, patch order and undo.
6. **Catalog and tools for authors.** `civarry/lasso-packages`, Browse and updates, Developer mode,
   `lasso-pkg`.

Step 2 leaves out "drag then run" hotkeys for package toolbar buttons (built-in actions have them);
the `hotkey` surface covers keyboard use for now.

Until the step that builds a part ships, a package using it (a `prompt` command, a `toolbar` surface,
a `folder` setting, `patches`…) is refused at install with "This version of Lasso can't run <part>
yet", never installed half-working.

## Out of scope for version 1

Each needs a format addition, decided here before it's built:

- **Code loaded into Lasso's own process**, in any version: mods run beside Lasso (layer 3).
- **Code mods** (layer 3): planned, see [the direction](#code-mods-layer-3-planned).
- **Sign-in flows** (OAuth). They need a browser window; keys and tokens cover most services.
- **Request signing** (AWS-style), multi-step http calls, pagination.
- **Sending images over http** and multipart uploads (a script with `network` can).
- **Non-JSON http responses** (XML, HTML).
- **Local MCP servers** as a runner.
- **Agent skills** (instructions for the Agent) as a package part.
- **The user changing a package's `limits`** (someone on a paid plan held to the free tier's numbers).
  Until then the author's limits apply.
- **Dependencies between packages**, and installing `requires` automatically.
- **Commands that run on a schedule** or in the background. Every command runs because the user or a
  model asked, while Lasso is open.

## Verification

Each MUST, with the check that fails when it's broken. App tests live in `LassoTests/Packages/`;
`lasso-pkg` runs the same validator in the catalog's CI.

| Rule | Check |
|---|---|
| Newer `lasso` format refused | Validator: `"lasso": 2` → "Needs a newer Lasso". |
| Unknown fields refused, by name | Validator: a misspelled field at the top, in a command and in a runner are each reported with their path. |
| Unknown template names refused at install | Validator: `{{settings.nope}}`, `{{qurey}}`, and `{{text}}` in a command without the `text` input are each reported. |
| `search` shape | Validator: a `search` command without `query` input, `results` output or a `test` is refused. |
| Template escaping | Engine against a local server: a value with `&`, `#`, a space, a quote and a newline arrives intact in a URL, a JSON body and a form body; a line break in a header is refused. |
| Hosts enforced, including redirects | Engine: an undeclared host is refused before connecting; a 302 to one isn't followed. |
| `http` only for a local `server` | Validator: `http://example.com` refused, `http://localhost:8888` accepted. |
| Local-only gate in the engine, per runner | Engine with local-only on: an off-Mac `http` makes no connection (the local server records zero hits); a Shortcut not marked `offline` isn't started; a script with `network` is denied the network by the sandbox (its `curl` fails); a `prompt` command and a script without network still run. |
| Script sandbox | Runner: a test script trying to read `~/Documents`, write to the home folder, read Lasso's preferences, and reach the network without `network` fails at each; writing to its data folder and `TMPDIR` succeeds. |
| Script environment | Runner: the script sees only the documented variables; a secret appears only as its `LASSO_SECRET_` variable, never in the standard-input JSON. |
| Script timeout | Runner: a script that sleeps past `timeout` is stopped with what it started (a child's marker file never appears). |
| Requirements | Runner: a command needing a missing tool doesn't run and reports the install line. |
| Shortcut existence | Runner: a command naming a Shortcut the user lacks isn't runnable and shows "Get the Shortcut". |
| Settings isolation | Engine: package B's `{{settings.key}}` resolves to B's key, never A's; no template reaches Lasso's own keys. |
| Secrets never logged | Engine: after a request with a secret in the query, a header and the body, and a script run with a secret, the captured log and the Run panel show `•••`, not the secret. |
| Response limits | Engine: a 3 MB response is refused; long titles, snippets and answers are trimmed. |
| `when` regex limits | Engine: a catastrophic pattern on long text gives up within 50 ms and the command isn't offered. |
| `replace` never from a model | Validator: a `tool` command with `replace` output is refused, so no model is ever offered one; the runner refuses it too. |
| Model runs of acting commands need the user | Chat: a model's call to a `notify` command over `POST` shows the card and the local server records nothing until Allow; Deny, and stopping the reply, record nothing and return "The user didn't allow this". A `GET` with `markdown` output runs without the card. (Shortcuts and scripts: step 4.) |
| Tool budget | Registry: with nine 200-character tools, seven are offered and the model gets only those; the eighth is shown as over the limit; turning one off in Tools for models offers the next and keeps the command's other surfaces. The review says when a package's tools won't all fit. |
| Limits honoured | Engine: after `daily` calls, the next search skips the package. |
| Review on wider access | Install: an update adding a host, network, a runner or an input shows the review with it highlighted; one changing only a prompt doesn't; one changing a script always does. |
| Remove deletes everything | Install: the package folder, preferences, Keychain items, bookmarks and data folder are gone; `~/LassoWorkspace/<id>/` and the usage counts are kept. |
| A changed package needs the review | Install: after its file is edited on disk the package is off, its switch can't turn it on, the review shows the approved and the new version, and only Turn On enables it. |
| Full access is the user's alone | Install: no manifest field, update or `lasso://` link turns on full access; after the user turns it on, an update leaves it on only if no script changed, and the script runs unsandboxed (it can read `~/Documents`); turned off, the sandbox applies again. |
| Only a person installs | Chat and Agent: a model's attempt to install or update a package (a tool call, a link in a reply) at most opens the review; nothing is installed without the user's click. A package file edited on disk is turned off at the next launch until reviewed. |
| Protections can't be patched | Validator: patches targeting anything outside the list (the fencing, local-only, approvals) are refused; `chat.instructions` only appends after Lasso's own. |
| Patch order and undo | Patches: two packages setting the same prompt apply in the user's order and Settings names the winner; turning the winner off restores the other's, removing both restores Lasso's default exactly. |
| Patch targets documented | Build: `docs/patch-targets.md` is regenerated from the code and CI fails if it's out of date. |
| Catalog hash checked | Install: a download whose SHA-256 differs from `index.json` is refused. |
| Tavily and SerpApi migration | Migration: a saved Tavily key with Tavily on → package installed, key moved, the same request as before (the local server compares); no key → nothing installed; a second launch repeats nothing. |
| Usage carries over | Migration: with 950 of Tavily's 960 monthly searches used, the package makes at most 10 more this month. |
| The Agent's list stays current | Agent: the tool server's `tools/list` includes an installed package's tools; the launch Lasso compares before each Agent turn includes the offered tools, so installing, removing or switching one makes it differ and the Agent restarts. |
| The Agent asks first | Agent: an Agent call to a `notify` command shows Lasso's approval card and runs nothing until Allow; Deny gives the Agent "The user didn't allow this". |
| Same search after removing the Swift code | Search: with both packages installed, `WebSourcesProvider` sends the same requests as the old code and returns the same titles and URLs in the same order for recorded responses. Accepted differences: SerpApi results are labelled "SerpApi" instead of "Google" and carry its snippets. |
