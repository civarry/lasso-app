# Lasso packages

Status: **draft, format version 1.** Nothing here is built yet. This document is the contract the
engine, the Settings screens and the catalog are built and tested against; when code and this document
disagree, one of them is a bug, and the fix is decided here first.

A package adds something to Lasso without changing Lasso's code: a search source, a service to look
things up in, a place to send what you lassoed, or a new capture-toolbar button. Packages are installed
and removed by the user, like packages on Linux, from a public catalog or from a file.

The words MUST, MUST NOT, SHOULD and MAY are used as in RFC 2119. Every MUST has a check listed in
[Verification](#verification) that fails when the rule is broken.

## Contents

- [Principles](#principles)
- [The package file](#the-package-file)
- [Types](#types): search, lookup, send, action
- [Templates](#templates)
- [Reading responses](#reading-responses)
- [Settings and keys](#settings-and-keys)
- [What a package may reach](#what-a-package-may-reach)
- [Model and Agent tools](#model-and-agent-tools)
- [Installing, updating, removing](#installing-updating-removing)
- [The catalog](#the-catalog)
- [Tavily and SerpApi](#tavily-and-serpapi)
- [Examples](#examples)
- [Out of scope for version 1](#out-of-scope-for-version-1)
- [Verification](#verification)

## Principles

1. **A package describes; Lasso does.** A package is data: which address to call, where the key goes,
   how to read the answer, what prompt to run. It contains no code, so a package can't do anything
   Lasso's engine doesn't do, and pasting one from a forum is safe.
2. **The user sees what leaves the Mac.** Every host a package can reach, everything it reads (your
   selection, the image, a search query) and every key it needs is shown before it's installed.
3. **Local-only means local-only.** In local-only mode no package reaches anything off the Mac. One
   gate, in the engine, enforces it for every package.
4. **Small for the model.** A package offered to a model as a tool costs context on every request, so
   tool descriptions are short and only enabled packages are offered.
5. **Built-in stays small.** Lasso keeps only what makes it work with zero setup (the keyless web
   search, the core capture actions). Everything optional is a package, including Tavily and SerpApi.

## The package file

One UTF-8 JSON file, at most 64 KB, conventionally named `<id>.lasso.json`.

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
  "search": { ... }
}
```

### Top-level fields

| Field | Required | Rules |
|---|---|---|
| `lasso` | yes | Format version, an integer. Lasso MUST refuse a package whose `lasso` is higher than the newest version it reads, with the message "Needs a newer Lasso". |
| `id` | yes | 3 to 40 characters, lowercase `a-z`, `0-9` and `-`, starting with a letter. Unique in the catalog. Never changes once published. |
| `version` | yes | Semantic version `MAJOR.MINOR.PATCH`. |
| `name` | yes | 1 to 40 characters, shown in Settings and on buttons. |
| `summary` | yes | 1 to 120 characters, one sentence saying what it does. |
| `author` | yes | A name or handle. |
| `homepage` | no | An `https` URL about the service or the package. |
| `icon` | no | `symbol`: an SF Symbol name. `domain`: a domain whose logo is shown when online. With neither, Lasso shows a generic icon. |
| `hosts` | when the package uses the network | Every host it may contact, exact names (`api.example.com`), no wildcards, no ports, no paths. See [What a package may reach](#what-a-package-may-reach). |
| `settings` | no | Values the user enters, such as a key. See [Settings and keys](#settings-and-keys). |
| `limits` | no | `{"daily": n, "monthly": n}`: Lasso stops calling the package once either is reached, so a free plan isn't overrun. |
| `minLasso` | no | The oldest Lasso version that runs it, such as `"0.18.0"`. |
| `search`, `lookup`, `send`, `action` | at least one | The parts the package provides. See [Types](#types). A package MAY provide several, such as a Notion package with both `search` and `send`. |

Unknown top-level fields MUST be rejected, so a typo (`"serch"`) is an error rather than a package that
silently does nothing.

## Types

### search

A source of web results for chat, Identify and the Agent. Lasso merges results from every enabled
search package with its built-in web search, removes duplicates and ranks them.

```json
"search": {
  "role": "primary",
  "request": {
    "method": "GET",
    "url": "https://api.search.brave.com/res/v1/web/search",
    "query": { "q": "{{query}}", "count": "8" },
    "headers": { "X-Subscription-Token": "{{settings.key}}", "Accept": "application/json" }
  },
  "results": { "list": "web.results", "title": "title", "url": "url", "snippet": "description" },
  "test": { "query": "lasso app" }
}
```

| Field | Rules |
|---|---|
| `role` | `primary` (asked on every search, its results go first) or `reserve` (asked only when the other sources returned fewer than 5 results). Default `primary`. |
| `request` | See [Requests](#requests). Available values: `query`. |
| `results` | `list` is the path to the array of results; `title`, `url`, `snippet` are paths inside each item. `title` is required; items without one are skipped. `limit` caps how many are used, 1 to 10, default 10. Results are labelled with the package's `name`. |
| `test` | A query the Test button and the catalog's CI run. Required. |

### lookup

Answers from one service, offered to chat and the Agent as a tool (weather, currency, a dictionary,
Wolfram Alpha). The model decides when to call it, from `tool`.

```json
"lookup": {
  "tool": { "name": "convert_currency", "description": "Convert an amount between currencies at today's rate." ,
            "inputs": { "amount": "number", "from": "string", "to": "string" } },
  "request": { "url": "https://api.example.com/convert", "query": { "amount": "{{input.amount}}", "from": "{{input.from}}", "to": "{{input.to}}" } },
  "answer": "result.text",
  "test": { "input": { "amount": 10, "from": "USD", "to": "EUR" } }
}
```

| Field | Rules |
|---|---|
| `tool.name` | `a-z`, `0-9`, `_`, at most 40 characters. Lasso prefixes it with the package id when two packages use the same name. |
| `tool.description` | At most 200 characters. It is sent to the model on every request while the package is enabled. |
| `tool.inputs` | Up to 6 inputs, each `string`, `number` or `boolean`. All are required. |
| `answer` | Path to the text to give the model. Alternatively `results` as in `search`. |

### send

Sends something somewhere: what you lassoed, a chat reply, or what the Agent wrote. It appears as a
"Send to" button in the capture toolbar and on chat replies, and as a tool the Agent may use.

```json
"send": {
  "label": "Add to Todoist",
  "accepts": ["text"],
  "request": {
    "method": "POST",
    "url": "https://api.todoist.com/rest/v2/tasks",
    "headers": { "Authorization": "Bearer {{settings.key}}" },
    "json": { "content": "{{text}}" }
  },
  "done": { "message": "Added to Todoist", "open": "url" }
}
```

| Field | Rules |
|---|---|
| `label` | The button's text, at most 30 characters. |
| `accepts` | `text` in version 1 (images are [out of scope](#out-of-scope-for-version-1)). Available values: `text` (the selected or recognized text, or the reply), `source` (the page or app it came from, when Lasso knows it). |
| `done.message` | Shown after a 2xx response. |
| `done.open` | Optional path to a URL in the response, offered as "Open". |

Sending changes something outside the Mac, so when a **model** (chat or the Agent) asks to send, Lasso
MUST show what will be sent and where, and send only after the user allows it. A button the user
clicks is that permission already.

### action

A capture-toolbar button made of a prompt, run by the model chosen in Settings. No network and no key
of its own: it works in local-only mode whenever the chosen model is local. This is the easiest kind of
package to write.

```json
"action": {
  "label": "Explain simply",
  "symbol": "lightbulb",
  "accepts": ["text"],
  "prompt": "Explain this so a 10-year-old understands it, in at most 5 sentences:\n\n{{text}}",
  "output": "markdown"
}
```

| Field | Rules |
|---|---|
| `label` | The button's text, at most 24 characters. |
| `symbol` | An SF Symbol for the button. |
| `accepts` | `text`, `image`, or both. With `image`, the action is offered only when the chosen model (or image model) can see images. |
| `prompt` | At most 4,000 characters. Available values: `text`, `language` (the Mac's language). The selected text is fenced as content, the same way Lasso fences screen text today, so instructions inside it aren't followed. |
| `output` | `markdown` (shown in the result card) or `copy` (the answer goes to the clipboard and a "Copied" note is shown). |

## Requests

| Field | Rules |
|---|---|
| `method` | `GET` (default) or `POST`. |
| `url` | An absolute `https` URL. Its host MUST be one of `hosts`. Templates are allowed only in the path and query, never in the scheme or host (except a `server` setting, below). |
| `query` | Map of query parameters. Values are templates. |
| `headers` | Map of headers. Values are templates. `Host`, `Content-Length`, `Cookie` and `Connection` can't be set. |
| `json` | A JSON body; string values anywhere inside are templates. Sets `Content-Type: application/json`. |
| `form` | A URL-encoded form body, as a map. Only one of `json` and `form`. |
| `timeout` | Seconds, 1 to 20, default 8. |

Lasso adds `User-Agent: Lasso/<version>` and nothing else: no cookies, no shared session state between
packages.

## Templates

`{{name}}` is replaced by a value. Available names depend on the part (listed with each type), plus:

- `{{settings.<id>}}`: a value the user entered (see below).
- `{{input.<name>}}`: a model's tool input (`lookup` only).

Values are escaped for where they land: percent-encoded in a URL, JSON-escaped in a JSON body,
form-encoded in a form body. A header value containing a line break is rejected. A template naming
something unavailable MUST make the package invalid at install time, not fail later. There are no
expressions, conditions or loops.

## Reading responses

Responses must be JSON (`application/json`, or text that parses as JSON) and at most 2 MB. A path is
dot-separated keys and array indexes, such as `web.results` or `data.0.text`. A missing path yields
nothing; it isn't an error unless it's the `list` of a search, which then counts as no results.

Every text read from a response is untrusted: Lasso trims it (titles 200 characters, snippets 500,
lookup answers 4,000), and gives it to models fenced as content, never as instructions.

A response other than 2xx is a failure. Lasso shows "<name> didn't answer (<status>)" where the user
asked for it (Test, a Send button) and moves on silently in a background search.

## Settings and keys

```json
"settings": [
  { "id": "key", "label": "API key", "kind": "secret", "help": "https://example.com/keys" },
  { "id": "server", "label": "Server", "kind": "server", "placeholder": "https://search.example.org" }
]
```

| Kind | Stored in | Notes |
|---|---|---|
| `secret` | Keychain, under `package.<id>.<setting>` | Never shown again in full, never sent to any host but the package's own, and replaced by `•••` wherever a request is logged or shown (a key in a URL, like SerpApi's, included). |
| `text` | Lasso's preferences | Plain values, such as a Notion database id. |
| `server` | Lasso's preferences | The base URL of a server the user runs (SearXNG, a self-hosted service). Its host is added to the package's allowed hosts, and the user sees it at install. A `server` value may start a request `url`: `"{{settings.server}}/search"`. |

At most 5 settings. `help` is an `https` link shown as "Get a key".

## What a package may reach

- Requests go to `https` hosts listed in `hosts`, or the host of a `server` setting. Lasso's engine
  MUST refuse any other host, including after a redirect, even if the package was edited by hand.
- `http` is allowed only for a `server` setting on this Mac (`localhost`, `127.0.0.1`, `::1`), for
  services the user runs locally.
- **Local-only mode:** packages whose requests leave the Mac are paused and shown as such; `action`
  packages and packages that only reach this Mac keep working. The check is in the engine, at the
  moment of the request, not only in the interface.
- A package can read only its own settings. It never sees another package's key, Lasso's own keys,
  files, the screen, or the clipboard, except the values a type hands it (`query`, `text`, `source`,
  tool inputs).

## Model and Agent tools

Enabled `lookup` and `send` packages are offered as tools to chat (when the model supports tools) and
to Lasso's Agent (through Lasso's tool server). `search` packages aren't separate tools: they feed
Lasso's single web search, so ten search packages cost the model nothing extra. `action` packages
aren't tools; they're buttons.

## Installing, updating, removing

**Sources:** the Browse list (the catalog), a file dropped or chosen with **+**, JSON pasted with
**+**, or a `lasso://install?id=<id>` link (which opens Browse at that package; it never installs
silently).

**Before installing**, Lasso validates the file (every rule above) and shows a review: name, author,
what it adds (types and buttons), the hosts it reaches, what it reads, and the keys it asks for. The
user installs or cancels. An invalid package shows every problem found, each with the field it's in.

**Installed packages** live in `~/Library/Application Support/Lasso/Packages/<id>.lasso.json`, are
listed in Settings › Packages with an on/off switch, and are re-validated at every launch (a package a
newer Lasso no longer accepts is turned off with the reason shown).

**Updates** come from the catalog and are never automatic. If an update reaches new hosts, reads more,
or asks for new settings, the review is shown again listing what's new. Settings and keys carry over
when their ids are unchanged.

**Removing** deletes the file, its preferences and its Keychain items.

**Same id:** installing a package whose id is already installed is an update if its version is higher,
and is refused otherwise ("Already installed").

## The catalog

A public GitHub repository, `civarry/lasso-packages`:

```
packages/<id>/<id>.lasso.json     the package
packages/<id>/README.md           what it sends where, the plan it needs, its limits
index.json                        generated by CI, never edited by hand
schema/v1.json                    JSON Schema for editors
CONTRIBUTING.md                   how to write, test and submit a package
```

`index.json` lists, for each package: `id`, `version`, `name`, `summary`, `author`, types, `hosts`,
`minLasso`, the raw file URL and its SHA-256. Lasso fetches `index.json` only when the user opens
Browse or checks for package updates (never in local-only mode), and refuses a downloaded package whose
SHA-256 doesn't match the index.

**CI on every pull request** loads each changed package with Lasso's own validator (a command-line
build of the same code the app uses), checks that `id` matches the folder, that the version went up,
that the README exists, and runs each part's `test` where it needs no key (with a key, the author pastes
a successful Test result into the pull request). Merging regenerates `index.json`; merging is
publishing.

## Tavily and SerpApi

Their Swift code is removed; they become catalog packages (`tavily`, `serpapi`), defined in
[Examples](#examples). For people upgrading:

- If a Tavily or SerpApi key is saved and that connector was on, Lasso installs the package once, from
  a copy bundled with that release (no download), and moves the key from its old Keychain item to the
  package's. Search behaves as before: Tavily `primary`, SerpApi `reserve`, the same limits.
- Without a saved key, nothing is installed; they're in Browse like any package.
- The migration runs once and is recorded, so removing the package afterwards is final.

## Examples

### Tavily (search)

```json
{
  "lasso": 1, "id": "tavily", "version": "1.0.0",
  "name": "Tavily", "summary": "Web search tuned for AI: clean, ranked results.",
  "author": "Lasso", "homepage": "https://tavily.com",
  "icon": { "symbol": "magnifyingglass.circle", "domain": "tavily.com" },
  "hosts": ["api.tavily.com"],
  "settings": [ { "id": "key", "label": "API key", "kind": "secret", "help": "https://app.tavily.com/" } ],
  "limits": { "daily": 40, "monthly": 960 },
  "search": {
    "role": "primary",
    "request": {
      "method": "POST", "url": "https://api.tavily.com/search",
      "headers": { "Authorization": "Bearer {{settings.key}}" },
      "json": { "api_key": "{{settings.key}}", "query": "{{query}}", "max_results": 6, "search_depth": "basic" }
    },
    "results": { "list": "results", "title": "title", "url": "url", "snippet": "content", "limit": 6 },
    "test": { "query": "lasso app" }
  }
}
```

### SerpApi (search, reserve)

```json
{
  "lasso": 1, "id": "serpapi", "version": "1.0.0",
  "name": "SerpApi", "summary": "Google results, used when other sources come back thin.",
  "author": "Lasso", "homepage": "https://serpapi.com",
  "icon": { "symbol": "magnifyingglass.circle.fill", "domain": "serpapi.com" },
  "hosts": ["serpapi.com"],
  "settings": [ { "id": "key", "label": "API key", "kind": "secret", "help": "https://serpapi.com/manage-api-key" } ],
  "limits": { "daily": 10, "monthly": 240 },
  "search": {
    "role": "reserve",
    "request": {
      "url": "https://serpapi.com/search.json",
      "query": { "engine": "google", "num": "8", "q": "{{query}}", "api_key": "{{settings.key}}" }
    },
    "results": { "list": "organic_results", "title": "title", "url": "link", "snippet": "snippet", "limit": 6 },
    "test": { "query": "lasso app" }
  }
}
```

### SearXNG on your own server (search, no key)

```json
{
  "lasso": 1, "id": "searxng", "version": "1.0.0",
  "name": "SearXNG", "summary": "Search through a SearXNG server you run.",
  "author": "Lasso", "homepage": "https://docs.searxng.org",
  "icon": { "symbol": "server.rack" },
  "settings": [ { "id": "server", "label": "Server", "kind": "server", "placeholder": "http://localhost:8888" } ],
  "search": {
    "request": { "url": "{{settings.server}}/search", "query": { "q": "{{query}}", "format": "json" } },
    "results": { "list": "results", "title": "title", "url": "url", "snippet": "content" },
    "test": { "query": "lasso app" }
  }
}
```

### Slack webhook (send)

```json
{
  "lasso": 1, "id": "slack-webhook", "version": "1.0.0",
  "name": "Slack", "summary": "Post what you lassoed to a Slack channel.",
  "author": "Lasso", "icon": { "symbol": "number", "domain": "slack.com" },
  "hosts": ["hooks.slack.com"],
  "settings": [ { "id": "path", "label": "Webhook path", "kind": "secret",
                  "help": "https://api.slack.com/messaging/webhooks" } ],
  "send": {
    "label": "Post to Slack", "accepts": ["text"],
    "request": { "method": "POST", "url": "https://hooks.slack.com/services/{{settings.path}}",
                 "json": { "text": "{{text}}" } },
    "done": { "message": "Posted to Slack" }
  }
}
```

### Flashcards (action)

```json
{
  "lasso": 1, "id": "flashcards", "version": "1.0.0",
  "name": "Flashcards", "summary": "Turn what you lassoed into question-and-answer cards.",
  "author": "Lasso",
  "action": {
    "label": "Flashcards", "symbol": "rectangle.on.rectangle", "accepts": ["text"],
    "prompt": "Make up to 8 flashcards from this text. Format each as **Q:** question, then **A:** answer.\n\n{{text}}",
    "output": "markdown"
  }
}
```

## Out of scope for version 1

Each of these needs a format addition, decided here before it's built:

- **Code in packages** (scripts, JavaScript transforms). Not planned: it would undo principle 1.
- **Sign-in flows** (OAuth). They need a browser window; keys and tokens cover most services.
- **Request signing** (AWS-style HMAC), multi-step calls, pagination.
- **Sending images** and multipart uploads.
- **Non-JSON responses** (XML, HTML).
- **Agent skills** (instructions for Lasso's Agent) as a package type.
- **Dependencies between packages.** Each package stands alone.

## Verification

Each MUST, with the check that fails when it's broken. Tests live in `LassoTests/Packages/`; the
validator's command-line build runs the same checks in the catalog's CI.

| Rule | Check |
|---|---|
| Newer `lasso` format refused | Validator test: `"lasso": 2` → "Needs a newer Lasso". |
| Unknown fields refused | Validator test: a misspelled top-level field and a misspelled field inside `search` are each reported by name. |
| Unknown template names refused at install | Validator test: `{{settings.nope}}` and `{{qurey}}` are each reported. |
| Template escaping | Engine test: a query with `&`, `#`, a space, a quote and a newline arrives intact in a URL, a JSON body and a form body (local test server); a line break in a header value is refused. |
| Hosts enforced, including redirects | Engine test against a local server: an undeclared host is refused before connecting; a 302 to an undeclared host is not followed. |
| `http` only for a local `server` | Validator test: `http://example.com` as `server` refused, `http://localhost:8888` accepted. |
| Local-only gate in the engine | Engine test: with local-only on, a request to a declared off-Mac host is refused without a connection (local server records zero hits); an `action` still runs. |
| Settings isolation | Engine test: package B's template `{{settings.key}}` resolves to B's key, never A's; Lasso's own Keychain items aren't reachable by any name. |
| Response limits | Engine test: a 3 MB response is refused; long titles and snippets are trimmed to their limits. |
| Model-initiated send needs the user | Chat test: a model tool call to a `send` package shows the approval and makes no request until allowed; deny makes none. |
| Limits honoured | Engine test: after `daily` calls, the next search skips the package. |
| Review shown again on wider access | Install test: an update adding a host shows the review listing the new host; one changing only the prompt doesn't. |
| Secrets never logged | Engine test: after a request with a secret in the query, a header and the body, the captured log and the Test details contain `•••` and not the secret. |
| Remove deletes everything | Install test: after removal, the file, preferences and Keychain items are gone. |
| Catalog hash checked | Install test: a download whose SHA-256 differs from `index.json` is refused. |
| Tavily and SerpApi migration | Migration test: a saved Tavily key with Tavily on → package installed, key moved, search makes the same request as before (local server compares); no key → nothing installed; second launch → nothing repeated. |
| Same search behaviour after removing the Swift code | Search test: with the Tavily and SerpApi packages installed, `WebSourcesProvider` sends the same requests as the old code and returns the same titles and URLs, in the same order, for recorded responses. Known differences, accepted: SerpApi results are labelled "SerpApi" instead of "Google", and now carry its snippets. |
