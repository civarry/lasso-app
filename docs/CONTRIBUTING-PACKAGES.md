# Making a Lasso package

A package adds something to Lasso without changing Lasso's code. This version of Lasso runs **search
packages**: a web service that Lasso asks when it searches the web (in chat, Identify and the Agent).
Buttons, chat commands, tools for the model, Shortcuts and scripts come in later steps; they're
described in [PACKAGES.md](PACKAGES.md), which is the full format and the source of truth when this
guide and it disagree.

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

## Editor help

[`packages/schema-v1.json`](packages/schema-v1.json) is a JSON Schema for the format. Point your editor
at it for completion and errors as you type. In VS Code, add this to the top of your file:

```json
"$schema": "https://raw.githubusercontent.com/civarry/lasso-app/main/docs/packages/schema-v1.json",
```

Lasso ignores `$schema`; everything else unknown is an error.

## Sharing it

Until the package catalog opens, share your `.lasso.json` file directly: people add it with **+**,
and the review tells them it came from a file and what it reaches. Put a short README beside it that
says what it sends where, what key it needs and where to get one, and what the free tier allows.

When the catalog opens (`civarry/lasso-packages`, see [PACKAGES.md](PACKAGES.md#the-catalog)), a
package is submitted as a pull request; CI runs the same checks as Lasso, and a maintainer reviews it
before it's listed.

## Checklist before you share

- [ ] Adds cleanly with **+**, and the review lists exactly the hosts you expect.
- [ ] **Test** returns sensible results for your `test` query.
- [ ] Results have titles, links that open the right page, and snippets where the service has them.
- [ ] A wrong key gives a clear failure on the Test button, not a silent empty list.
- [ ] `limits` sit under the free tier; `role` is `reserve` if the tier is small.
- [ ] `version` raised since the last copy you shared.
