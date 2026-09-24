# Handoff

## Where it stands

The first shot recorded real sessions well. The second pass built the program
out around four asks, each as if it had been there from the start:

- **Drawing.** Pen, arrow, circle, rectangle and five named inks on the pill;
  marks numbered, recorded with what they were drawn on, set into the words
  (`{red circle 1}`), drawn into pictures with their numbers, and a whole-screen
  picture per mark.
- **The clipboard gets a note for an agent**, not the words (`Pointer.swift`),
  the moment a session stops; `owl session` waits for the words.
- **Sessions overlap.** One recording, any number transcribing. States
  (`recording`, `transcribing`, `done`, `failed`) and a per-session flock make
  that safe across processes and crashes: an orphan is finished by the app at
  launch or by `owl session`.
- **A dev copy** (`./build.sh` → owl-dev) so owl can be worked on while the
  real one is in use; `./build.sh release` refuses while it is busy.

And the robustness pass: every read of another app (accessibility, Apple
events, an app's desk command) moved off the main thread onto one serial
reader queue with timeouts. In a real session the old synchronous AppleScript
let one reading run inside another, which logged `app → Brave`, `app →
Onshape Bridge` twice and out of order. Readings no longer overlap, and an
event keeps the time it happened. Pictures are an actor. The last click's
picture and the last typing are waited for at the end (up to 2 s). SIGTERM is
a proper quit. The gesture watches only ⌥ and clicks when idle, so keys and
scrolls no longer wake owl all day.

Verified with the dev copy and synthetic sessions (`say -o`):
- orphan takeover by `owl-dev session`
- waiting on a held lock, and a second `transcribe` refused
- finishing an orphan at launch after a SIGTERM
- marks inline in the words, and empty focus events dropped
- `pointer` and `guide`
- the pill and marks rendered offscreen and looked at

Not verified: the drawing layer, the Escape tap and the pill's buttons on a
live screen, and the watcher end to end after the reader rewrite. They need
the person to run an owl-dev session, which needs owl-dev's own grants first.

## 2026-09-24, after the person tried owl-dev

- Drawings fade: six seconds, then three to fade; half a second once the
  screen under them changes a lot (`ScreenChange.swift`: a small, slow
  ScreenCaptureKit stream per display, only while marks are up). The change
  test is relative to each region's own contrast. On real page pictures a
  30 pt scroll of a list or toolbar, a 120 pt scroll of anything, and a page
  going blank count; noise, the pointer and a 6 pt nudge do not. A mark
  leaves the record (and the pictures) when it starts to fade: a `fade` event.
- The clipboard line is just `new owl session <id>`; agents learn owl from
  `skill/SKILL.md`, which a vault skill points at.
- owl-dev on the person's Mac had the microphone but not Accessibility or
  Screen Recording in the first try: no Esc, no element names, no pictures,
  and without Screen Recording marks only fade with time.

## What is next

- The person runs an owl-dev session: draw each tool, Esc, clear, stop from
  the pill, start a second session while the first transcribes, paste the
  note into an agent. Then read `session.md` back.
- The first `./build.sh release` goes over a copy from before session states
  and locks. That copy's `owl status` does not exist and it does not handle
  SIGTERM, so check its log for a session in progress before replacing it.
- A take cut off by a crash is lost: AAC in .m4a is unreadable without the
  index written at close. A format that survives a crash (CAF, or PCM
  rolled into AAC at stop) would make crash recovery keep the sound.
- A transcript over ~7 minutes should be chunked before it goes to the text
  model; long clips make chat models loop. Not done.
- Sessions are one take on one microphone. A device change mid-session ends
  the sound (the engine stops on device loss) but not the session.
- The remark grouping in `session.md` (pause > 0.7 s, or sentence end + pause
  > 0.25 s) is a first guess.
