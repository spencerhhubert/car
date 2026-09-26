---
name: car
description: Read what someone said and did in a car session (their voice and everything on their Mac, on one clock, with pictures and drawings) and do what they asked. Use when a message says "car marker <n> set at <time> in session <id>", "new car session <id>" (or car-dev), or asks about a car session.
---

# car sessions

car is a Mac menu bar app that records the person talking while they work,
for hours at a time: what they say, and everything on the screen (apps,
windows, pages, clicks, selections, typing, pictures, and drawings made
while talking, so "this one here" has an answer). While it runs they set
**markers**, and a marker is how they hand you a task: **what they said
before it is the instruction; the screen is what their words point at.**

The line you get is one of:

- `car marker 3 set at 12:31:05 pm in session 20260924-122534`: read what
  was said up to marker 3 and do what it asks.
- `new car session 20260924-122534`: the whole session is the message.
- `car-dev …` in either: the development copy. Use `car-dev` for every
  command below.

## Read it

```
car marker <session> <n>             what was said up to marker n, since the marker before it
car marker <session> <n> --from -30m  the same, reaching back 30 minutes (or --from start, --from m2, --from 12:30)
car session <session> [--from M] [--to M]   the timeline, any stretch of it
car events <session> [--from M] [--to M]    every event, JSON, one a line (element names, URLs, paths, pictures)
car words <session> [--from M] [--to M]     every word with its time, JSON
car audio <session> [--from M] [--to M] --out F.wav   the sound itself, one file (for a video, say)
```

`car marker` waits until the words up to the marker are transcribed, which
can take a minute right after the marker is set; let it. So an instruction
you cannot find is never "not transcribed yet". `car guide` explains car in
full.

## A session is many conversations; the marker is yours

A session runs for hours and wanders: the person works on many things, goes
back and forth between them, and hands markers to several agents, each its
own. Most of a session is not about your task. The marker is: **the stretch
right before it is what was meant for you.**

- **Start at the marker and read backwards.** The instruction is what was
  said just before it. The stretch since the previous marker often begins
  with something else entirely (that marker was likely another agent's).
- **Never cut `car marker` short with `head`.** `head` keeps the oldest
  lines and drops the newest, which is where the instruction is. Read it
  whole, or from the end (`tail`); a long stretch is what a busy day looks
  like, not a sign it is not yours.
- **Widen in rings, only as far as the words need:** the last remarks before
  the marker; then the rest since the previous marker; then `--from -10m`,
  `--from -30m`, an earlier marker, `--from start`, when the words lean on
  earlier talk. Stop once you have it.
- **Other markers are other hand-offs.** Talk between them can still be
  about your task (people come back to things): judge by what was said, not
  by where it sits, and leave what is about something else.

## Go as deep as the task needs

Once you have the instruction, decide how much more you need.

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
  `car events` for exact element names, URLs and paths.

## An app's own record beats car's pictures of it

Some apps report what they show through their own `desk` command (car
records each reading as a `desk` line), and such an app may keep a finer
record of its own: every item it opened, where its playhead was to the
millisecond, what was picked, even car's words taken in beside it. When the
person talks about something inside one of those apps ("this clip", "that
one's good"), read that app's record for what they meant (the person's own
notes on this Mac say which apps keep one, and how to read it), and use car
for the words and the rest of the screen. car's pictures of that app are
the last resort, not the first.

## The timeline

- `[mm:ss.mmm]` (or `h:mm:ss.mmm`) is one clock for words and events alike.
- Speech is the lines with a time range, `[1:02.300–1:05.100] “…”`. Element
  names in other lines are quoted too, so `“` alone does not pick out
  speech. `{red circle 1}` inside speech is where in the sentence that
  drawing was made. `▶ marker 3, set at …` is a hand-off point.
- Other lines: `app`, `window` (title, document), `page` (URL), `finder`
  (folder, selected files), `focus`, `selected`, `click` (the element under
  the pointer), `key` (shortcuts only), `typed` (how many keys, and the
  field's value afterwards), `scroll`, `picture <path> (why)`, `drew`,
  `faded`, `wiped`, `copied what was said … to the clipboard` (a quick
  dictation: those words went somewhere as text, most likely a message),
  `microphone → …` (which one recorded from there on), `paused` / `resumed`
  (nothing was recorded between them), and an app's own report of what it
  shows.
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
  far), or if a stretch failed (`car transcribe <session>` tries again). A
  stretch with no speech has no words; there is no instruction in it.
- Keystrokes are never recorded, only what a field held afterwards, and
  never a password field.
- A session is someone's day on their computer. Never copy it, or anything
  from it, into a repo, a commit or anything public.
