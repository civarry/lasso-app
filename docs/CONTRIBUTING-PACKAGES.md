# Making a Lasso package

A package adds something to Lasso without changing Lasso's code. This version of Lasso runs:

- **Search packages**: a web service Lasso asks when it searches the web (in chat, Identify and the
  Agent).
- **Commands**: a button in the capture toolbar, a `/command` in chat, a "Send to" target, a hotkey
  on text highlighted in any app, or a tool the chat model and Lasso's Agent can call. A command either
  runs a prompt on the model the user chose in Lasso, or calls a web service.

Shortcuts and scripts come in later steps; they're described in
[PACKAGES.md](PACKAGES.md), which is the full format and the source of truth when this guide and it
disagree.

A package is one JSON file, `<id>.lasso.json`. You write it, people add it in **Settings › Packages ›
+** (drop the file, choose it, or paste its text), and Lasso shows them exactly what it does before
they say yes.

## A first package in five minutes

This one searches Wikipedia, needs no key, and works as written:

```json
{
  "lasso": 1,
  "id": "wikipedia-search",
  "version": "1.0.0",
  "name": "Wikipedia",
  "summary": "Encyclopedia articles for a search.",
  "author": "Your name",
  "category": "knowledge",
  "icon": { "symbol": "book.closed", "domain": "wikipedia.org" },
  "hosts": ["en.wikipedia.org"],
  "commands": [ {
    "id": "search",
    "title": "Wikipedia",
    "surfaces": ["search"],
    "input": ["query"],
    "output": "results",
    "run": {
      "http": {
        "url": "https://en.wikipedia.org/w/api.php",
        "query": { "action": "query", "list": "search", "format": "json", "srlimit": "5", "srsearch": "{{query}}" }
      },
      "role": "reserve",
      "results": { "list": "query.search", "title": "title", "snippet": "snippet", "limit": 5 }
    },
    "test": { "query": "lasso" }
  } ]
}
```

1. Save it as `wikipedia-search.lasso.json`.
2. In Lasso, open **Settings › Packages**, click **+**, and drop the file in.
3. Read the review: it lists the one host it reaches and what it sends there. Click **Add**.
4. On the package's page, click **Test**. You should see results and how long they took.

That's the whole loop. Edit the file, drop it in again with a higher `version`, and Lasso offers the
update.

## How a search package works

Lasso fills in the request, sends it, reads the JSON that comes back, and turns it into results:

- **`run.http`** describes the request: `url` (always `https`), `method` (`GET` or `POST`), `query`
  (added to the URL), `headers`, and a `json` or `form` body. `{{query}}` is the search;
  `{{settings.<id>}}` is one of your settings, such as an API key. Lasso escapes each value for where it
  goes, so you never encode anything yourself.
- **`run.results`** says where the results are in the answer: `list` is the path to the array, and
  `title`, `url` and `snippet` are paths inside each item. Paths are keys and array indexes joined by
  dots, like `web.results` or `data.0.text`.
- **`run.role`**: `primary` is asked on every search and its results come first; `reserve` is asked
  only when the other sources returned fewer than 5 results. Use `reserve` for a service with a small
  free tier.
- **`limits`** (`daily`, `monthly`) stop Lasso before a free tier runs out. Lasso counts on the user's
  Mac and shows the count on the package's page.

### API keys

Declare a key as a `secret` setting and use it in the request:

```json
"settings": [ { "id": "key", "label": "API key", "kind": "secret", "help": "https://example.com/keys" } ],
...
"headers": { "Authorization": "Bearer {{settings.key}}" }
```

Lasso keeps it in the user's Keychain, sends it only to your package's hosts, shows "Get a key" with your
`help` link, and replaces it with `•••` anywhere a request is logged or shown. A package never sees
another package's settings or Lasso's own keys.

### A server the user runs

For a self-hosted service such as SearXNG, use a `server` setting and start the URL with it. It's the
only way to use plain `http`, and only for a server on the same Mac:

```json
"settings": [ { "id": "server", "label": "Server", "kind": "server" } ],
...
"url": "{{settings.server}}/search", "query": { "q": "{{query}}", "format": "json" }
```

## The standard

Lasso checks these when a package is added, and a package that breaks one is refused with the field
and the reason. They're here so you don't have to find them by trial.

**Identity**
- `lasso` is `1`. `id` is 3 to 40 lowercase letters, digits and `-`, starts with a letter, and never
  changes once people use it. `version` is `MAJOR.MINOR.PATCH`; raise it for every change you share.
- `name` up to 40 characters; `summary` one sentence up to 120, saying what it does, not how good it is.
- `author` is who maintains it. Lasso can't verify it and tells users so.

**Reaching the network**
- List every host the package contacts in `hosts`: exact names, no wildcards, ports or paths. A request
  to anything else, including through a redirect, is refused.
- `https` only. Templates can't change the scheme or the host.
- Lasso adds `User-Agent: Lasso/<version>` and sends no cookies. You can't set `Host`, `Cookie`,
  `Content-Length` or `Connection`.
- Answers must be JSON, at most 2 MB, within `timeout` seconds (1 to 20, default 8).

**What comes back**
- Titles are cut to 200 characters and snippets to 500; HTML tags are removed. Only `http` and `https`
  links become source links.
- Everything a package returns is treated as content, never as instructions to a model.

**Being a good citizen**
- Ask only for what the search needs: no extra hosts, no settings you don't use.
- Set `limits` under the service's free tier, so a user isn't billed by surprise.
- Give a `test` query that returns results; people press Test first.
- Unknown fields are errors, so a typo can't silently do nothing. Check the spelling against
  [PACKAGES.md](PACKAGES.md) or use the schema below.

**Local-only mode**
- When the user turns on local-only mode, packages that reach off the Mac are paused automatically.
  A `server` package pointed at `localhost` keeps working. You don't need to do anything for this.

## Commands: buttons, /commands, Send to and hotkeys

A command says **where it appears** (`surfaces`), **what it takes** (`input`), **how it runs** (`run`)
and **what happens with the result** (`output`). This one adds an "Explain simply" button to the capture
toolbar and `/explain` to chat, and runs on the user's own model, so it works offline when that model
is on their Mac:

```json
{
  "lasso": 1, "id": "study-tools", "version": "1.0.0", "name": "Study tools",
  "summary": "Explain anything you lasso, simply.", "author": "Your name", "category": "writing",
  "commands": [ {
    "id": "explain", "title": "Explain simply", "symbol": "lightbulb",
    "surfaces": ["toolbar", "slash"], "input": ["text"], "when": { "minLength": 40 },
    "run": { "prompt": "Explain this so a 10-year-old understands it, in at most 5 sentences:\n\n{{text}}" },
    "output": "markdown"
  } ]
}
```

**Where it appears**
- `toolbar`: a button after Lasso's own in the capture toolbar, running on the text Lasso read from
  the capture. People reorder or hide it in Settings › Toolbar like any other.
- `slash`: `/<id>` in chat, on the text typed after it or the last reply. Lasso's own names (`new`,
  `clear`, `copy`, `about`, `web`, `help`) are taken; if two packages share an id, both become
  `/<package-id>-<id>`.
- `send`: an entry in "Send to", on a capture and in a chat reply's ⋯ menu. Its output must be
  `notify`, `copy` or `open`.
- `hotkey`: listed in Settings › Keyboard Shortcuts under Highlighted text; the user sets a key that runs
  it on the text highlighted in any app. Your package never picks the key.
- `tool`: a tool the chat model (when it can call tools) and Lasso's Agent can use. Needs a `tool`
  object, below.

**How it runs**
- `prompt` runs on the model the user chose in Settings › Models, never another one. `{{text}}` is
  given to the model between markers that tell it not to follow instructions inside, so captured text
  can't take over your prompt. A `secret` setting can't go into a prompt. Up to 4,000 characters, plus an
  optional `system` of 1,000.
- `http` calls a web service, under the same rules as search packages. `answer` is the path to the
  value to use from the JSON it returns.

**What happens with the result**
- `markdown`: shown in a result card on a capture, as a reply in chat.
- `copy`: copied to the clipboard.
- `replace`: pasted over the highlighted text. Only for `hotkey` commands; one ⌘Z undoes it.
- `open`: a page opened in the browser. Only from `http`, where the address is your template on a
  declared host; Lasso builds it and the browser opens it, without Lasso fetching it.
- `notify`: a short confirmation, the `answer` when it's 60 characters or less, otherwise "Done".

**When it shows (`when`)**, all optional: `match` (a regular expression), `detects` (`link`, `email`,
`phone`, `address`, `date`, `flight`, `tracking`, `money`), `apps` (bundle ids), `minLength`,
`maxLength`, `hasImage`. In the toolbar a button whose `match`, `detects` or `apps` fails is hidden, and
one that's only too short or long is greyed. In chat there's no source app, so `apps` never holds there.
For example, a button that opens parcel tracking only when there's a tracking number:

```json
"surfaces": ["toolbar"], "input": ["text"], "when": { "detects": ["tracking"] }, "output": "open",
"run": { "http": { "url": "https://parcelsapp.com/en/tracking/{{text}}" } }
```

with `"hosts": ["parcelsapp.com"]` at the top.

**Tools for models.** Add `"tool"` to `surfaces` and describe it for the model:

```json
{ "id": "convert", "title": "Convert currency", "surfaces": ["tool"], "input": ["args"], "output": "markdown",
  "run": { "http": { "url": "https://api.example.com/convert",
                     "query": { "amount": "{{args.amount}}", "to": "{{args.to}}" } }, "answer": "result" },
  "tool": { "name": "convert_currency", "description": "Convert an amount to another currency at today's rate.",
            "args": { "amount": "number", "to": "string" } },
  "test": { "args": { "amount": 5, "to": "EUR" } } }
```

- `name`: lowercase letters, digits and `_`, starting with a letter, at most 40. If it clashes with
  another package's or one Lasso has, it's offered as `<package_id>_<name>`.
- `description`: at most 200 characters, read by the model with every request. Say what it does and
  when to use it. All offered tools share a 1,500-character budget, so short is kind: the user turns off
  the ones that don't fit.
- `args`: up to 6, `string`, `number` or `boolean`, all required; use them as `{{args.<name>}}`. A command
  with the `args` input is only a tool. To make one command both Send to and a tool, take `text` and give
  the tool a `text` argument.
- `output`: `markdown`, `copy`, `notify` or `open`. Lasso asks the user first, on its own card, whenever
  a model runs one that does more than return text: `copy`, `notify`, `open`, or an `http` method other
  than `GET`. A model can never run a `replace` command.

What your tool returns goes to the model as content, fenced, at most 4,000 characters.

**Not yet:** images as input. A package using it is refused with "This version of Lasso can't … yet".

## Shortcuts and scripts: run something on the Mac

**A Shortcut** reaches Reminders, Notes, Calendar, HomeKit and most apps without an API. The package
names one of the user's own Shortcuts; Lasso runs it with Apple's `shortcuts` tool, passing the text in
and reading the Shortcut's output back:

```json
{
  "lasso": 1, "id": "reminders", "version": "1.0.0", "name": "Reminders",
  "summary": "Add what you lasso to Reminders.", "author": "Your name",
  "commands": [ {
    "id": "add", "title": "Add to Reminders", "symbol": "checklist", "surfaces": ["send"],
    "input": ["text"], "output": "notify",
    "run": { "shortcut": { "name": "Add to Reminders from Lasso",
                           "get": "https://www.icloud.com/shortcuts/0123456789abcdef", "offline": true } }
  } ]
}
```

- `get` is an iCloud link to your Shortcut: the package's page offers it while the user doesn't have one
  by that name.
- Mark `offline` only if the Shortcut never uses the internet: it then runs in local-only mode, on your
  word.

**A script** is a program in the package folder's `scripts/` (any language with a `#!` line). Share the
whole folder, not only `lasso.json`. Lasso writes one JSON object to its standard input (the inputs you
declared and the non-secret settings) and reads its answer from standard output: plain text, or
`{"text": …}`, `{"path": …}` for a file, or `{"results": [{"title", "url", "snippet"}]}` for search.

```text
my-package/
  lasso.json
  scripts/to-csv.py
```

- **A table someone lassoes:** take the `table` input (rows on lines, cells split by tabs) with
  `"when": {"detects": ["table"]}`; Lasso rebuilds the rows and columns from the capture. Add a `howTo`
  line so people know what to lasso.
- **A search script on this Mac** (no `network`) becomes a source: people type **@** and its name in chat,
  or Lasso picks it when a message fits the "What's in it" line they set. It gets their own words in
  `query`; return the files that hold at least two of them, with the lines that hold the most as the
  snippet. Only the 3 best passages in all reach the model.
- It runs **in a sandbox**: it can write only its own folder (also its `HOME`) and `TMPDIR`, read only
  the system, its package and any `folder` setting the user picked, and has no internet unless the
  command says `"network": true`. Files it returns are copied to `~/LassoWorkspace/<package>/`.
- Secrets arrive only as `LASSO_SECRET_<SETTING>` environment variables, never on standard input.
- Lines on standard error starting `progress:` show while it runs; on failure, the last line of
  standard error is shown, so make it a sentence.
- It's stopped, with anything it started, at its `timeout` (30 seconds unless you say, at most 300).
- List what it needs in `requires` (`{"command": "pandoc", "install": "brew install pandoc"}`): Lasso
  checks, and tells the user the install line. It never installs anything.
- Models always ask the user before running a script or a Shortcut.
- The user can give a package **Full access** (no sandbox). A package can't ask for it, and an update
  that changes a script turns it off.

## Editor help

## Patches: change Lasso itself

A package can also change parts of Lasso instead of adding to it: the prompts behind Summarize and
Proofread, the names of Lasso's actions, the toolbar's default order and hidden buttons, the suggestions
on an empty chat, and extra instructions for the chat model. A package can be only patches:

```json
{
  "lasso": 1, "id": "writing-kit", "version": "1.0.0", "name": "Writing Kit",
  "summary": "Bullet-point summaries and British spelling.", "author": "Your name",
  "patches": [
    { "target": "action.ai.summarize.prompt", "set": "Summarize the text as at most 5 short bullet points." },
    { "target": "action.ai.summarize.title", "set": "Bullets" },
    { "target": "toolbar.hidden", "add": ["lens.search", "color.pick"] },
    { "target": "chat.suggestions", "add": { "title": "Make this email shorter" } },
    { "target": "chat.instructions", "add": "Use British spelling." }
  ]
}
```

- Each patch has a `target` and one of `set`, `add` or `remove`. Every target, what it takes and
  Lasso's own value is in [`patch-targets.md`](patch-targets.md).
- A prompt is only the instructions: Lasso adds the selected text after it, so leave out `{{text}}`.
- The user's own toolbar order and choices in Settings › Toolbar always beat yours.
- `chat.instructions` adds to what the chat model is told; it can't replace Lasso's own. The review shows
  it word for word, so write it for the person reading it too.
- If two packages `set` the same thing, the one installed last is used; the user can pick the other.
  Turning your package off undoes every change.

## Editor help

[`packages/schema-v1.json`](packages/schema-v1.json) is a JSON Schema for the format. Point your editor
at it for completion and errors as you type. In VS Code, add this to the top of your file:

```json
"$schema": "https://raw.githubusercontent.com/civarry/lasso-app/main/docs/packages/schema-v1.json",
```

Lasso ignores `$schema`; everything else unknown is an error.

## Trying it while you write it

- **In Lasso:** turn on Settings › Packages › **Developer mode**. **New Package…** starts a folder from a
  template that already works; **Load Folder…** runs your folder and reloads it each time you save
  (problems show on its page, and the last good version keeps running). Its page's **Test** runs any of
  its commands.
- **On the command line:** `lasso-pkg`, built from Lasso's own source
  (`Tools/lasso-pkg/build.sh ~/bin/lasso-pkg` in a clone of this repo):

```text
lasso-pkg new script my-package             # a starter: search, send, prompt, shortcut or script
lasso-pkg validate my-package --catalog     # what Lasso and the catalog check
lasso-pkg run my-package count --text "a b"  # a script's input and answer; http requests with --send
lasso-pkg pack my-package                   # my-package-1.0.0.lassopkg, one file to share
```

## Sharing it

- **The catalog:** [`civarry/lasso-packages`](https://github.com/civarry/lasso-packages). Add your folder
  at `packages/<id>/` and open a pull request. CI runs `lasso-pkg validate --catalog`, checks the version
  went up and runs your scripts' tests; a maintainer reads every script before merging. Once merged it's
  in everyone's Settings › Packages › Browse, and `lasso://install?id=<id>` opens it there.
- **Directly:** share the `.lassopkg` from `lasso-pkg pack` (or the `.lasso.json` when there are no
  scripts). People add it with **+**, and the review tells them it came from a file and what it reaches.

Either way, put a README beside it that says what it sends where, what key it needs and where to get
one, and what the free tier allows.

## Checklist before you share

- [ ] Adds cleanly with **+**, and the review lists exactly the hosts you expect.
- [ ] **Test** returns sensible results for your `test` query.
- [ ] Results have titles, links that open the right page, and snippets where the service has them.
- [ ] A wrong key gives a clear failure on the Test button, not a silent empty list.
- [ ] `limits` sit under the free tier; `role` is `reserve` if the tier is small.
- [ ] Commands: each one runs from every place it appears, and its `when` shows it where it makes sense
      and nowhere else.
- [ ] A `replace` command's prompt asks for only the rewritten text (no "Here's your text:").
- [ ] `version` raised since the last copy you shared.
- [ ] `lasso-pkg validate <folder> --catalog` passes.
