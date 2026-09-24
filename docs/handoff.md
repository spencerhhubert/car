# Handoff

## Where it stands

owl records sessions meant to run for hours. ⌘⇧R starts and stops one;
⌥ ⌥ sets a marker, which cuts the sound there and puts
`owl marker N set at <time> in session <id>` on the clipboard for an agent,
which reads it with `owl marker` (skill: `skill/SKILL.md`). The sound is
recorded in chunks of about three minutes, cut at pauses and transcribed as
they close. The catalog (`owl.sqlite`) holds every session, chunk, word,
event, marker, cost, and where each file is. Drawing on the screen, the
reader queue and the dev copy are as before. The code is split into OwlKit
(a tested Swift package: store, transcription, timeline, marks) and the app
(capture, drawing, the menu, the command).

Verified:
- OwlKit's tests (`swift test --package-path OwlKit`): alignment, onset
  monotonicity, remarks with drawings and markers, the clock, moments,
  pointer lines, mark geometry, the fading test, the catalog round trip.
- End to end without a microphone: a scratch program played the app (three
  `say -o` chunks, a marker after the second, holding the lock). `owl-dev
  marker` waited for the second chunk's words and printed only what came
  before the marker; `owl-dev session` then took over the chunk the "crashed"
  app left and finished the session; ranges and `owl-dev words` work.
- The screen-change test against pictures of real pages.
- owl-dev's older sessions were imported into its catalog.

Not verified live yet: the chunked microphone (the first try on a Bluetooth
headset looped reopening the input, fixed since: a change is looked at half a
second later and only a stopped engine is reopened, at most once a second),
⌘⇧R and ⌥ ⌥, the pill's dot and hover, a session across sleep. The person
runs owl-dev for that; `tools/live-test.txt` still plays the old hold-⌥ flow
and needs the new keys before gravity can run it.

## Before the first release of this

The real owl's sessions are still in the old per-folder files (meta.json,
events.jsonl, words.json, audio.m4a). They go into its catalog the way
owl-dev's did: an import that makes each old session one chunk, turns its
events and pictures into rows, then removes the old files. Back the sessions
folder up first. The old copy knows nothing of locks, so check its log for a
session in progress before `./build.sh release`.

## What is next

- Bindings (issue #2): any gesture for any action, set by doing it.
- Archiving: the catalog already records each file's store; a command that
  moves old pictures and audio to another drive and updates their rows.
- Retention of raw audio once it has words.
- Long sessions and pictures: a picture per window change all day adds up;
  watch the disk after a few full days.
- The remark grouping (pause > 0.7 s, or sentence end + pause > 0.25 s) is a
  first guess.
