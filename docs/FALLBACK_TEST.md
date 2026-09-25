# Free-model fallback: manual test

A click-by-click run of the fallback feature. No setup knowledge needed: every step says exactly what to
click, what to paste, and what you should see.

- **Time:** about 20 minutes for all of it. Tests A to C are the core and take 5.
- **Cost:** nothing. Only models OpenRouter prices at $0 are used.
- **Before you start:** build and run from Xcode (⌘R) with the current working tree.

Tick boxes as you go. If something doesn't match, stop at that step and see
[If something goes wrong](#if-something-goes-wrong) at the bottom.

---

## Preparation

**P1. Open Settings** from the Lasso menu bar icon, then the **Intelligence** tab.

**P2. Confirm your normal model.** Under **Language model**, Protocol should be `Custom` and Model should
be your usual `openai/gpt-oss-120b` (Groq). If not, click the Model button and pick it.

**P3. Turn the feature on.** In the same card, find the **Fallback** row and turn **Free models** on.

- [ ] A **Slow model** row appears below it, set to `After 15 s`. Leave it.

**P4. Opt OpenRouter in.** Click **Manage connections** (link under the card).

1. Find **OpenRouter** in the list, click **Edit**.
2. Turn on **Use as fallback**.
3. Click **Save**, then **Done**.

**P5. Leave every other connection off.** Groq, AIStudio and Geminative stay without **Use as fallback**,
and without **Free tier**. That is deliberate: OpenRouter's free models are detected from the prices it
publishes, so nothing depends on you declaring anything, and if a Groq or Google key turns out to be
billed, a fallback there would cost real money.

**P6. Click Save & Apply** (bottom of the Settings window).

- [ ] The **Fallback** caption now reads something like:
      `21 free models across 1 connection · checked just now. Turn on Use as fallback for Groq, AIStudio
      and Geminative in Manage connections to include them.`

If it says `0 free models`, open **Manage connections** and check OpenRouter shows `· N free` in its row.

---

## Test A: normal use still works

This is your baseline. Nothing should change from before the feature existed.

1. Open Chat with **⌥⌘A**.
2. Paste and send:

```
In one sentence, what is a raccoon?
```

**Expect:**

- [ ] A normal answer within a few seconds.
- [ ] Click **Activity** (above the answer) to expand it: one line, `Answered · Groq · openai/gpt-oss-120b`.
- [ ] No mention of any other model.

---

## Test B: a broken model is replaced

Now break your model on purpose, by selecting a model id that does not exist.

1. Settings ▸ **Intelligence** ▸ **Language model** ▸ click the **Model** button.
2. In the popover, scroll to the bottom and click **Type a model name manually…**.
3. Type exactly:

```
lasso-test/does-not-exist:free
```

4. Click **Add**, then **Save & Apply**.
5. Back in Chat, paste and send:

```
Name three things you would find in a kitchen.
```

**Expect:**

- [ ] You still get a proper answer, within a few seconds.
- [ ] The header chip at the top right still shows **Groq**. Lasso did not change your model for you.
- [ ] Expand **Activity**. Two lines, in this order:
      1. `Groq · lasso-test/does-not-exist:free wasn't found (check the model name and base URL)`
      2. `Answered · OpenRouter · <some free model>`
- [ ] The answer text itself has no "Answered by…" note inside it. That belongs in Activity only.

**Why it matters:** the wording is "wasn't found", not "temporarily unavailable". A wrong model id never
fixes itself, so the message has to say so.

---

## Test C: a model that keeps failing is skipped

Keep the broken model selected. This is the part that stops you waiting on a dead model every message.

1. In the same chat, paste and send:

```
And three things you would find in a bathroom.
```

- [ ] Answers through a free model again (that is miss number two).

2. Now paste and send:

```
What about a garage?
```

**Expect:**

- [ ] A bar appears between the header and the conversation:
      `Using <free model> · lasso-test/does-not-exist:free isn't responding`, with **Switch** and
      **Try again** on the right.
- [ ] This answer arrives with no pause at all. Your broken model was not tried.
- [ ] The header chip still shows **Groq**: your selection is still yours.

3. Click **Try again**, then send:

```
Still there?
```

- [ ] Your broken model is tried once more, fails, and a free model answers. The bar comes back.

4. Click **Switch**.

- [ ] The bar disappears and the header chip changes to the free model. That is the only way your
      selection changes: because you clicked.

5. Put your model back: Settings ▸ **Language model** ▸ **Model** ▸ pick `openai/gpt-oss-120b` under
   **Groq** ▸ **Save & Apply**.

---

## Test D: the Slow model setting

The race itself (your model is slow, a free model starts beside it, first to answer wins) cannot be
staged by hand, because a connection that hangs also hangs when listing its models, so there is nothing
to select. Two parts you can check:

**D1. The control exists.**

1. Settings ▸ **Language model** ▸ **Slow model**.

- [ ] The menu offers `Never`, `After 8 s`, `After 15 s`, `After 30 s`, `After 60 s`.
- [ ] Picking `Never` changes the caption to "Wait for your model however long it takes."
- [ ] Set it back to `After 15 s` and **Save & Apply**.

**D2. The race itself, as an automated run against your real OpenRouter connection.** In Terminal:

```sh
cd lasso-app
TEST_RUNNER_LASSO_LIVE=1 xcodebuild -scheme Lasso -configuration Debug -destination 'platform=macOS' \
  test "-only-testing:LassoTests/FreeModelLiveTests/scenarioG_aHungModelIsRacedAndARealFreeModelAnswers()" \
  2>&1 | grep -E "LIVE G|Test run"
```

- [ ] The `LIVE G` line shows a real free model answering, with "hadn't started answering after 3 s".
- [ ] It finishes in well under a minute (a hung request alone would take 60 s to fail).

---

## Test E: the on-device stand-in

This is the one you asked about: Apple's on-device model answering in place of your model.

**E1. Make on-device the only option.**

1. Settings ▸ **Manage connections** ▸ **OpenRouter** ▸ **Edit** ▸ turn **Use as fallback** off ▸ **Save**
   ▸ **Done**.
2. Select the broken model again: **Model** ▸ `lasso-test/does-not-exist:free` (it is now in the list
   under **Manually added**) ▸ **Save & Apply**.

**E2. Short conversation.** In Chat, start a **new conversation** (the chat title menu at the top
left ▸ **New conversation**), then paste and send:

```
I am planning a small dinner for four people on Friday. Suggest a simple main course.
```

**Expect:**

- [ ] Apple's on-device model answers.
- [ ] Expand **Activity**: `Answered on-device by Apple Intelligence (on-device)`.
- [ ] **The answer is about your dinner.** It should not read as though it has no idea what is going on,
      and should not start a fresh topic. It is told it is standing in and to continue the conversation.

**E3. Follow-up, to check it keeps the thread.** Send:

```
Make it vegetarian.
```

- [ ] The reply adapts the same dish. It should not ask what you are talking about.

**E4. A long conversation is skipped instead of failing.** In the same chat, paste a long block of text,
at least 10,000 characters (any long document, or the paragraph below pasted about 40 times), then send:

```
Here is some background I want you to keep in mind for later questions, repeated so that it is long
enough to matter.
```

**Expect:**

- [ ] You get an error mentioning your own model, not an on-device answer. Apple's model holds about
      2,000 tokens of conversation once its reply is reserved, so it is skipped rather than tried and
      failed.

**E5. Put it back:** **Manage connections** ▸ **OpenRouter** ▸ **Edit** ▸ **Use as fallback** on ▸ **Save**
▸ **Done** ▸ **Save & Apply**.

> If E2 gives an error instead of an on-device answer, check Apple Intelligence is available on this Mac:
> Settings ▸ Intelligence ▸ Language model ▸ Protocol ▸ `Apple Intelligence` should not be greyed out.

---

## Test F: search questions are never answered blind

A model that cannot search must not answer a search question from memory.

1. Keep `lasso-test/does-not-exist:free` selected, with OpenRouter opted back in (E5).
2. In Chat, make sure the **globe** icon in the composer is on.
3. Paste and send:

```
Search the web: what is the latest version of macOS?
```

**Expect (either one is a pass):**

- [ ] A free model that supports tools answers, and Activity shows a `Searching…` step, or
- [ ] You get your model's error.
- [ ] You do **not** get an on-device answer that guesses from training data.

---

## Test G: labels and safety rails

**G1. Tags in the model picker.** Settings ▸ **Language model** ▸ **Model**:

- [ ] OpenRouter's free models show a small `free` tag.
- [ ] Groq and Google models show no tag (you have not turned **Free tier** on for them).

**G2. Tags in Chat.** Chat header ▸ click the model chip ▸ open the **OpenRouter** submenu:

- [ ] The same free models are badged there.

**G3. Connection counts.** Settings ▸ **Manage connections**:

- [ ] OpenRouter's row reads `… · N free`, matching the Fallback caption.

**G4. Local-only mode.** Settings ▸ **General** ▸ **Privacy** ▸ turn **Local-only mode** on:

- [ ] Back on the Intelligence tab, the **Fallback** row is greyed out and its caption says it is paused.
- [ ] Turn local-only back off.

---

## Put everything back

1. Settings ▸ **Language model** ▸ **Model** ▸ `openai/gpt-oss-120b` under **Groq**.
2. **Manage connections** ▸ OpenRouter ▸ **Use as fallback** is on ▸ **Save** ▸ **Done**.
3. **Slow model** is `After 15 s`, **Free models** is on.
4. **Save & Apply**.
5. Quit and reopen Lasso. Cooldowns and routing are kept in memory only, so a relaunch clears them.

Optional: remove the test model from the picker by leaving it unselected; it lives under **Manually
added** and is harmless.

---

## If something goes wrong

Capture two things and send them to me:

1. A screenshot of the chat with **Activity** expanded.
2. The log lines for the last few minutes:

```sh
/usr/bin/log show --predicate 'subsystem == "com.cjcarito.Lasso" AND (category == "intelligence" OR category == "chat")' --last 10m --style compact | tail -40
```

Lines worth looking for yourself:

| Line | Meaning |
|---|---|
| `trying free model …` | a candidate was started |
| `racing a free model` | your model was slow, a candidate joined |
| `routing around …` | your model is being skipped for now |
| `failed before answering …` | an attempt failed before its first word |
| `on-device skipped: …` | the conversation was too big for Apple's model |

---

## What this run does not cover

- **A real rate limit (429).** Forcing one means hammering a provider, so that path is covered by
  automated tests only.
- **Racing inside the app** (D2 runs it against a real provider instead).
- **Groq or Google as fallback sources.** That needs **Free tier**, which is a billing decision: only
  turn it on for a key you know is on a free plan.
- **Identify and the background chat summary.** Both deliberately never use a free model.
