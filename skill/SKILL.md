---
name: owl
description: Read what someone said and did in an owl session (their voice and everything on their Mac, on one clock, with pictures and drawings) and do what they asked. Use when a message says "owl marker <n> set at <time> in session <id>", "new owl session <id>" (or owl-dev), or asks about an owl session.
---

# owl sessions

owl is a Mac menu bar app that records the person talking while they work,
for hours at a time: what they say, and everything on the screen (apps,
windows, pages, clicks, selections, typing, pictures, and drawings made
while talking, so "this one here" has an answer). While it runs they set
**markers**, and a marker is how they hand you a task: **what they said
before it is the instruction; the screen is what their words point at.**

The line you get is one of:

- `owl marker 3 set at 12:31:05 pm in session 20260924-122534`: read what
  was said up to marker 3 and do what it asks.
- `new owl session 20260924-122534`: the whole session is the message.
- `owl-dev …` in either: the development copy. Use `owl-dev` for every
  command below.

## Read it

```
owl marker <session> <n>             what was said up to marker n, since the marker before it
owl marker <session> <n> --from -30m  the same, reaching back 30 minutes (or --from start, --from m2, --from 12:30)
owl session <session> [--from M] [--to M]   the timeline, any stretch of it
owl events <session> [--from M] [--to M]    every event, JSON, one a line (element names, URLs, paths, pictures)
owl words <session> [--from M] [--to M]     every word with its time, JSON
```

`owl marker` waits until the words up to the marker are transcribed, which
can take a minute right after the marker is set; let it. `owl guide` explains
owl in full.

## Go as deep as the task needs

Start with `owl marker`: what was said since the previous marker. Read all of
it, then decide how much more you need.

- **The words carry it** ("remind me to call the supplier Monday", "draft a
  reply saying no"): act on the words.
- **It leans on earlier talk** ("like I said", "the thing from before", "for
  the last twenty minutes I've been describing"): reach back with
  `--from -30m`, `--from m2` or `--from start`. Sessions run for hours; take
  the stretch the words ask for, not the whole day.
- **They point** ("this", "here", "that one", "like this"): resolve each at
  its moment. Look for, in order: a drawing set into the words
  (`{red circle 1}`) and its `drew` line, which says what it was drawn
  around; then the click, selection, page, window or Finder selection at that
  moment. Open the picture nearest it; a drawing's own picture is the whole
  screen with the drawing and its number drawn in.
- **The task lives in the detail on screen** (a CAD model to change, a layout
  to copy, a bug they walked through): go through the pictures in order, and
  `owl events` for exact element names, URLs and paths.

## The timeline

- `[mm:ss.mmm]` (or `h:mm:ss.mmm`) is one clock for words and events alike.
- Quoted lines are speech. `{red circle 1}` inside a quote is where in the
  sentence that drawing was made. `▶ marker 3, set at …` is a hand-off point.
- Other lines: `app`, `window` (title, document), `page` (URL), `finder`
  (folder, selected files), `focus`, `selected`, `click` (the element under
  the pointer), `key` (shortcuts only), `typed` (how many keys, and the
  field's value afterwards), `scroll`, `picture <path> (why)`, `drew`,
  `faded`, `wiped`, and an app's own report of what it shows.
- A drawing is in pictures until its `faded` or `wiped` line. Drawings fade
  six seconds after they are made, or as soon as the screen under them
  changes a lot.
- Pictures are the focused window, or the whole screen for a drawing, at the
  path the line gives. When the text and a picture disagree, the picture is
  right.

## Cautions

- The words are a model's transcription. Names, part numbers and jargon can
  be misheard: check them against what was on screen before acting on them.
- The header says if the session is still recording (the words reach only so
  far), or if a stretch failed (`owl transcribe <session>` tries again). A
  stretch with no speech has no words; there is no instruction in it.
- Keystrokes are never recorded, only what a field held afterwards, and
  never a password field.
- A session is someone's day on their computer. Never copy it, or anything
  from it, into a repo, a commit or anything public.
