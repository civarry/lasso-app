# Regression tests

Every bug that's fixed gets a test here that fails without the fix, so it can't come back.

- One file per area: `ChatFlow` (Regenerate and its versions, search snippets, package `/command`
  replies), `ChatInput` (composer, panel keys, code blocks, drafts), `ChatHistoryAndSaving` (what the
  model sees, what's saved and restored), `ChatToolsAndAgent` (tool cards, the Agent, images in
  context, save ordering), `Markdown` (rendering, reasoning tags, math, paste), `Capture` (result
  cards closing, translate detection), `PackageSecurity` (sandbox escapes, install/approve/remove), `Intelligence` (providers,
  streams, context windows, what counts as local), `AppShell` (shortcuts, dictation cleanup, Keychain), and `ChatRound8`/`MarkdownRound8` (regressions
  the earlier fixes caused).
- A test's name says the right behaviour; its comment says what went wrong.
- Tests that touch `ChatController.shared` make their own conversation and close it. Tests that need
  packages use their own `PackageStore` in a temporary folder, never this Mac's.
- Before a fix lands: run its test without the fix and watch it fail.

Run them all:

    xcodebuild test -scheme Lasso -destination 'platform=macOS' -only-testing:LassoTests/ReplyVersionRegressionTests \
      -only-testing:LassoTests/ChatInputRegressionTests -only-testing:LassoTests/ChatHistoryAndSavingRegressionTests \
      -only-testing:LassoTests/ChatToolsAndAgentRegressionTests -only-testing:LassoTests/MarkdownRegressionTests

CI runs them with the rest of the suite on every pull request.
