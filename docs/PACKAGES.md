# Lasso packages

Status: **draft, format version 1.** Nothing here is built yet. This document is the contract the
engine, the Settings screens, the developer tools and the catalog are built and tested against; when
code and this document disagree, one of them is a bug, and the fix is decided here first.

A package adds things to Lasso without changing Lasso's code: a capture-toolbar button, a "Send to"
target, a chat command, a tool for the model and the Agent, a search source. What a package does can
come from a web service, a prompt to your own model, one of your Shortcuts, or a script that runs on
your Mac. Packages are installed and removed by the user, like packages on Linux, from a public catalog
or from a file.

The words MUST, MUST NOT, SHOULD and MAY are used as in RFC 2119. Every MUST has a check listed in
[Verification](#verification) that fails when the rule is broken.

## Contents

- [Principles](#principles)
- [The model: commands](#the-model-commands)
- [The package](#the-package)
- [Commands](#commands): where they appear, what they take, what they give back, when they show
- [Runners](#runners): http, prompt, shortcut, script
- [Templates and responses](#templates-and-responses)
- [Settings and keys](#settings-and-keys)
- [Permissions](#permissions)
- [Model and Agent tools](#model-and-agent-tools)
- [Installing, updating, removing](#installing-updating-removing)
- [Building a package](#building-a-package)
- [The catalog](#the-catalog)
- [Tavily and SerpApi](#tavily-and-serpapi)
- [Examples](#examples)
- [Out of scope for version 1](#out-of-scope-for-version-1)
- [Verification](#verification)

## Principles

1. **The user sees what a package can do before it does it.** Every host it reaches, what it reads,
   whether it runs code, and every key it needs is shown at install, and again when an update asks
   for more.
2. **Least power that does the job.** Most packages are data (a web request, a prompt); Lasso does the
   work and the package can't do anything else. Running code is a separate, clearly labelled kind,
   and it runs in a sandbox that enforces what the package declared.
3. **Local-only means local-only.** In local-only mode nothing a package does leaves the Mac. One gate
   in the engine enforces it, for every runner, at the moment a command runs.
4. **Small for the model.** A command offered to a model as a tool costs context on every request.
   Tool descriptions are short, only enabled ones are offered, and their total is capped.
5. **Built-in stays small.** Lasso keeps what makes it work with zero setup (keyless web search, the
   core capture actions). Everything optional is a package, Tavily and SerpApi included.

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
| `commands` | yes | 1 to 12 commands. |

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
| `send` | The "Send to" menu on a capture and on chat replies | For commands that deliver something somewhere. |
| `slash` | A chat command, `/<command-id>` | Runs on what's typed after it, or the last reply. |
| `tool` | A tool for the chat model and Lasso's Agent | See [Model and Agent tools](#model-and-agent-tools). |
| `search` | A source for Lasso's web search (chat, Identify, Agent) | `input` MUST be `query`, `output` MUST be `results`. |
| `hotkey` | Listed in Settings › Shortcuts; the user can assign a key that runs it on the current selection | The package never assigns a key itself. |

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
| `replace` | Pasted over the selection in the app it came from (like Lasso's grammar fix). Only with the `text` input from a capture; one Undo restores the original. |
| `open` | The result is a URL, opened in the default app. Only `https`, `http` and `mailto`. |
| `image` | Shown as an image. |
| `file` | A file saved to `~/LassoWorkspace/<package-id>/`, shown with Open and Show in Finder. |
| `notify` | A short confirmation is shown, for "Send to" commands. |
| `results` | Search results (the `search` surface). |

### When

Narrows where a command is offered, so the toolbar shows "Track package" only when there's a tracking
number. All conditions given must hold.

| Condition | Holds when |
|---|---|
| `match` | The text matches this regular expression (ICU syntax, at most 200 characters, tested against at most 10,000 characters of text, given up after 50 ms). |
| `detects` | Lasso's data detector found one of: `link`, `email`, `phone`, `address`, `date`, `flight`, `tracking`, `money`. |
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

## Templates and responses

`{{name}}` is replaced by a value: the inputs (`text`, `query`, `source.app`, `source.url`),
`args.<name>`, `settings.<id>`, and `language`. Values are escaped for where they land: percent-encoded
in a URL, JSON-escaped in a JSON body, form-encoded in a form body. A header value containing a line
break is refused. A template naming something the command doesn't have MUST make the package invalid
at install time. There are no expressions, conditions or loops.

`http` responses must be JSON, at most 2 MB. A path is dot-separated keys and array indexes
(`web.results`, `data.0.text`); a missing path yields nothing. Everything a package returns, from any
runner, is untrusted: Lasso trims it (titles 200 characters, snippets 500, tool answers 4,000) and
gives it to models fenced as content, never as instructions.

A failure (non-2xx, a timeout, a non-zero exit) shows "<name> didn't work: <reason>" where the user
asked for it, and is skipped silently in a background search.

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
| Changes text in your apps | `output: "replace"` | Only on the user's click, never from a model. |
| Needs a key | `secret` settings | The Keychain, per package. |

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

- `name`: `a-z`, `0-9`, `_`, at most 40 characters; prefixed with the package id if two clash.
- `description`: at most 200 characters.
- `args`: up to 6, each `string`, `number` or `boolean`, all required.
- **Budget:** the descriptions of all enabled tools together are capped at 1,500 characters (about
  400 tokens). Past that, Settings asks which to offer. `search` commands aren't tools: they feed
  Lasso's one web search, so ten search packages cost the model nothing extra.
- **Asking first:** when a model runs a command whose output is `notify`, `open` or `file`, or any
  `shortcut` or `script` command, Lasso MUST show what will run with what input and wait for Allow.
  Read-only `http` and `prompt` commands run without asking. A model can never run a `replace`
  command.

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
Files it saved to `~/LassoWorkspace/<id>/` are the user's and are left.

**Same id:** a higher version updates; the same or a lower one is refused ("Already installed").

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

- If a Tavily or SerpApi key is saved and that connector was on, Lasso installs the package once, from
  a copy bundled with that release (no download), and moves the key to the package's Keychain item.
  Search behaves as before: Tavily `primary`, SerpApi `reserve`, the same limits.
- Without a saved key nothing is installed; they're in Browse like any package.
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

## Out of scope for version 1

Each needs a format addition, decided here before it's built:

- **Plugins in Swift**, or anything loaded into Lasso's own process. Scripts run outside it, sandboxed.
- **Sign-in flows** (OAuth). They need a browser window; keys and tokens cover most services.
- **Request signing** (AWS-style), multi-step http calls, pagination.
- **Sending images over http** and multipart uploads (a script with `network` can).
- **Non-JSON http responses** (XML, HTML).
- **Local MCP servers** as a runner.
- **Agent skills** (instructions for the Agent) as a package part.
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
| `replace` never from a model | Chat: a model can't call a command whose output is `replace`. |
| Model runs of acting commands need the user | Chat: a model's call to a `notify`, `open` or `file` command, a Shortcut or a script shows the approval and runs nothing until Allow; Deny runs nothing. |
| Tool budget | Settings: enabling tools past 1,500 characters of descriptions asks which to offer, and the model is offered only those. |
| Limits honoured | Engine: after `daily` calls, the next search skips the package. |
| Review on wider access | Install: an update adding a host, network, a runner or an input shows the review with it highlighted; one changing only a prompt doesn't; one changing a script always does. |
| Remove deletes everything | Install: the package folder, preferences, Keychain items, bookmarks and data folder are gone; `~/LassoWorkspace/<id>/` is kept. |
| Catalog hash checked | Install: a download whose SHA-256 differs from `index.json` is refused. |
| Tavily and SerpApi migration | Migration: a saved Tavily key with Tavily on → package installed, key moved, the same request as before (the local server compares); no key → nothing installed; a second launch repeats nothing. |
| Same search after removing the Swift code | Search: with both packages installed, `WebSourcesProvider` sends the same requests as the old code and returns the same titles and URLs in the same order for recorded responses. Accepted differences: SerpApi results are labelled "SerpApi" instead of "Google" and carry its snippets. |
