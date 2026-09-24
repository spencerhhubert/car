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

Since then: whether anyone spoke is decided by owl's own voice detection
(`Voice.swift`, no model; 98.8% of onset-verified words caught on real
sessions, about 1.4× the spoken time kept), and only the voice goes to the
models. The remote model (OpenRouter) writes the words, capped and timed out;
the local model (Apple) keeps time with a deadline, since its model fetch has
hung for minutes; both are chosen in the menu. On a real two-minute chunk that
had cost $0.20 and seven minutes (Gemini looping on silence), the same chunk
now costs $0.002 and three seconds. No key ships; a session asks for one.

GitHub releases and a self-updater were built and taken out again the same
day: owl is built locally with `./build.sh release`, and whoever wants it
builds it. (A Developer ID certificate can only be made by the account
holder, and notarizing needs one.) Typing is never named key by key anywhere
now: a terminal's keys had been logged one by one because a terminal does not
look like a text field. `tools/live-test.txt` still plays the old hold-⌥ flow.

The real owl runs this build as of 2026-09-24 (its old sessions imported
into its catalog, a backup of the folders taken first); it holds ⌘⇧R and
⌥ ⌥, and owl-dev's keys are off.

## What is next

- Quick dictation (asked 2026-09-24): hold ⇧ and tap ⌥ twice, and owl
  transcribes what was said since the last long silence (more than ~15 s, a
  setting) and puts those words on the clipboard as fast as it can; the
  session carries on as it was. For answering a message out loud in the
  middle of a long session.

- Bindings (issue #2): any gesture for any action, set by doing it.
- Archiving: the catalog already records each file's store; a command that
  moves old pictures and audio to another drive and updates their rows.
- Retention of raw audio once it has words.
- Long sessions and pictures: a picture per window change all day adds up;
  watch the disk after a few full days.
- The remark grouping (pause > 0.7 s, or sentence end + pause > 0.25 s) is a
  first guess.
