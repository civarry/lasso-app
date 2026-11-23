# Leak check (Instruments)

The automated memory tests (`LassoTests/Memory`) check what a test can reach: a closed chat is freed,
its code runs are dropped. This check covers the rest, on the real app, in about ten minutes. Run it
before a release that touched windows, cards, chat or packages.

## Run it

1. In Xcode: **Product › Profile** (⌘I), pick **Leaks**, then Record.
2. Do each of these five times, waiting a second between:
   - Capture an area, then press Esc.
   - Capture, run **Copy text**, then close the card.
   - Capture, run **Summarize** (or Ask AI), close the card while it's still writing.
   - Open the chat (⌃⇧A), send a message, Stop it (⌘.), close the chat.
   - In chat: ⌘K, search, Esc. Regenerate a reply, switch ‹ 1/2 ›.
   - A Python block's **Run**, an html block's **Preview**, then **Open larger** and close it.
   - Settings › Packages: open a package's page, go back.
3. Stop recording.

## Read it

- **Leaks track:** any red mark is a leak. Click it, note the type and the stack.
- **Allocations track › Statistics:** filter for `FloatingPanel`, `NSHostingController`, `WKWebView`,
  `Conversation`, `CGImage`. After the steps above, **# Living** for windows and web views should be
  back to what it was before you started (one chat panel, at most one card). A count that grew by
  five is something held after close.
- **Memory graph** (Debug › Debug Memory Graph, while running from Xcode): purple ! marks are cycles.

## Report

Send the type, how many are still living, and which step grows it. Each one becomes a test in
`LassoTests/Memory` before it's fixed.
