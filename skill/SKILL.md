---
name: owl
description: Read an owl session, a recording of someone talking while they use their Mac (the words, every app, window, page, click and selection, pictures of the screen, and what they drew on it), and do what they asked in it. Use when a message says "new owl session <id>" or "new owl-dev session <id>", names an owl session, or asks about one.
---

# owl sessions

owl is a Mac menu bar app. The person holds ⌥ and talks while they work; owl
records what they say and everything they do on the screen, on one clock:
apps, windows, pages, clicks, selections, typing, pictures of the screen, and
drawings (pen, arrow, circle, rectangle) made while talking, so "this one
here" has an answer. A session is how they hand you a task: **what they said
is the instruction; the screen is what their words point at.**

`new owl session <id>` pasted into a chat means: read that session and do
what it asks. `new owl-dev session <id>` is the same from the development
copy; use `owl-dev` and its folder instead.

## Read it

```
owl session <id>        the timeline; waits if the words are still being transcribed
```

The rest is in `~/Library/Application Support/owl/sessions/<id>/`
(`owl-dev/` for the dev copy). `owl guide` explains owl in full.

## Go as deep as the task needs

Read everything they said first, then decide how much of the screen you need.

- **The words carry it** ("remind me to call the supplier Monday", "draft a
  reply saying no"): act on the words. Skip the pictures.
- **They point** ("this", "here", "that one", "the one on the left", "like
  this"): resolve each one at its moment in the timeline. Look for, in order:
  a mark set into the words (`{red circle 1}`) and its `drew` line, which says
  what it was drawn around; then the click, selection, page, window or Finder
  selection at that moment. Open the picture nearest that moment. A mark's own
  picture is the whole screen with the mark and its number drawn in.
- **The task lives in the detail on screen** (a CAD model to change, a layout
  to copy, a bug they walked through, a sequence of steps to repeat): go
  through the pictures in order, and use `events.jsonl` for exact element
  names, URLs and file paths, and `words.json` for exact timing.

## The timeline

- `[mm:ss.mmm]` is one clock for words and events alike.
- Quoted lines are speech, grouped into remarks. `{red circle 1}` inside a
  quote is where in the sentence that mark was drawn.
- Other lines: `app`, `window` (title, document), `page` (URL), `finder`
  (folder, selected files), `focus`, `selected`, `click` (the element under
  the pointer), `key` (shortcuts only), `typed` (how many keys, and the
  field's value afterwards), `scroll`, `picture shots/<ms>.jpg (why)`, `drew`,
  `faded`, `wiped`, and an app's own report of what it shows.
- `drew red circle 1 around button “Save” in Safari “Settings”` names the
  element at the mark's anchor: an arrow's tip, a shape's middle.
- A mark is in pictures until its `faded` or `wiped` line. Marks start to
  fade six seconds after they are drawn, or as soon as the screen under them
  changes a lot (`faded as the screen under it changed`).
- Pictures are the focused window, or the whole screen for a mark, named by
  the session millisecond they were taken. When the text reading and a
  picture disagree, the picture is right.

## The files

- `meta.json`: `state` (`recording`, `transcribing`, `done`, `failed` with
  `error`), `seconds`, `textModel`, `note` (for example, nothing was heard),
  `unverified`.
- `words.json`: every word with `start` and `end` in session ms.
- `events.jsonl`: one event a line, `kind` and `t` (session ms) plus its
  detail; screen places (`x`,`y`, a mark's `rect`, `at`, `points`) are in
  points from the top-left of the main display.
- `transcript.txt`, `audio.m4a`, `shots/`.

## Cautions

- The words are a model's transcription. Names, part numbers and jargon can
  be misheard: check them against what was on screen (titles, pages, files)
  before acting on them.
- A `failed` session: `owl transcribe <id>` tries again. A `note` saying
  nothing was heard means there is no spoken instruction: ask.
- Keystrokes are never recorded, only what a field held afterwards, and
  never a password field.
- A session is someone's day on their computer. Never copy it, or anything
  from it, into a repo, a commit or anything public.
