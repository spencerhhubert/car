# Handoff

## Where it stands

car (continuous action recording; it was called owl until 2026-09-24)
records sessions meant to run for hours. One gesture does everything: ⌥
tapped twice, with ⌘ held to start or stop a session, alone to set a marker
(the sound is cut there and `car marker N set at <time> in session <id>` goes
on the clipboard for an agent), with ⇧ held for quick dictation (what was
said since the last long pause, as text on the clipboard). The sound is
recorded in chunks of about three minutes, cut at pauses and transcribed as
they close; whether anyone spoke is decided by car's own voice detection,
and only the voice goes to the models (a remote one on OpenRouter writes the
words, Apple's on-device one keeps time; they run side by side). The catalog
(`car.sqlite`) holds every session, chunk, word, event, marker, cost, and
where each file is.

car is an ordinary app with one window, in the Dock, with a 🏎️ in the
menu bar for working in other apps. The window lists the sessions, reads the
one picked as a script (words, what was done around them, the pictures, live
while recording, a picture big on a click), and has Settings at the foot of
its sidebar, which took everything that was a choice out of the menu,
disk use included. How it looks and how its code is kept from hanging is
`docs/design-system/`; `tools/viewcheck` stress-scrolls it, checks every
row's height, and renders it to pictures.

The first version of the script was a SwiftUI lazy stack in a scroll view
and hung (full CPU, never settling) after a minute of mouse-wheel scrolling:
SwiftUI measuring rows and moving the view to hold its place, round and
round. It is now an AppKit table whose row heights car works out itself
(`ScriptLayout`), and `Watchdog.swift` samples the app if its main thread
ever stops answering for three seconds. The table hung once too (2026-09-24,
a live session on screen, a mouse attached), and the watchdog's sample
showed why: it was being reloaded from inside its own layout pass. That
rule, and the check that now fails on it, are in
`docs/design-system/engineering.md`.

Verified:
- CarKit's tests (`swift test --package-path CarKit`): alignment, onsets,
  remarks with drawings and markers, the clock, moments, pointer lines, mark
  geometry, fading, the catalog, and the script's rows (what goes near a
  remark, words still to come, markers, repeats folding, long gaps) and
  quick dictation's stretch.
- The window against real sessions (`tools/viewcheck`): a live session's
  rows arriving while it follows the bottom; 600 wheel steps, 200 jumps and
  60 resizes with both kinds of scroller, no step over 100 ms, and no
  reentrant table change; every row's height at
  least what SwiftUI needs at three widths; the script, sidebar rows,
  picture viewer and Settings rendered in light and dark.
- Earlier: a marker waiting for its words, a session picked up after a
  crash, the screen-change test, the voice detection against real sessions.

Not verified live yet: the pill's hover, tooltips and pulsing dot (rendered
by viewcheck, not yet under a person's pointer), pause and resume, the
microphone list moving down and back up as devices come and go, the new keys (⌘ ⌥ ⌥ and ⇧ ⌥ ⌥; ⌥ ⌥ is unchanged),
quick dictation end to end, the window with a person's mouse (the toolbar,
the Settings button, keys in the picture viewer), the microphone watchdog,
the hang watchdog. car-dev has them; it needs its grants and its keys
turned on. `tools/live-test.txt` still plays the old hold-⌥ flow.

The microphone watchdog came from a real loss: a session recorded nine
minutes with the microphone (a webcam's, whose camera another app had just
opened) sending nothing, and nothing noticed. Now four seconds without a
buffer reopens it, two failed tries fall back to the system default, and the
pill says so.

## Sound quality

Sessions keep their sound at low (16 kHz AAC, what every session had until
2026-09-24), medium (48 kHz AAC, 160 kbps) or high (48 kHz Apple Lossless),
chosen in Settings; transcription reads every chunk at 16 kHz, so the
choice changes nothing but the disk. `car audio` joins a stretch into one
WAV for use elsewhere. Tested in CarKit (each quality written, heard and
joined); not yet recorded live at medium or high. Pictures are still one
quality; tiers for them are issue #8, which needs measuring first.

## The recordings folder

Sound and pictures can go to a folder of the person's choosing (an external
drive); each file goes there while it is there and to this Mac while it is
not, recorded per file in the catalog's stores, and a chunk whose drive
vanishes mid-write is closed and the next one opens wherever the session says
two seconds later. Tested in CarKit with a folder that goes and comes back;
not yet with a real drive yanked mid-session.

## Renaming owl to car

The repo, the package (CarKit), the apps (car, car-dev), the bundle ids
(com.car.mac…), the folders (`Application Support/car`, `car.sqlite`,
`car.log`) and the lines on the clipboard all say car. owl-dev's data was
moved to car-dev, and the installed owl to car on 2026-09-24 once it was
idle, with a one-off script (folder, catalog file, the catalog's store
root, the log; old app and command removed). A new bundle id means new
grants: Accessibility, Microphone, Screen Recording and Automation are given
again, once.

## What is next

- Bindings (issue #2): any gesture for any action, set by doing it.
- Archiving: the catalog already records each file's store; a command that
  moves old pictures and audio to another drive and updates their rows.
- Retention of raw audio once it has words.
- Long sessions and pictures: a picture per window change all day adds up;
  watch the disk after a few full days.
- The remark grouping (pause > 0.7 s, or sentence end + pause > 0.25 s) and
  the script's grouping of actions (1.5 s before a remark to 3 s after) are
  first guesses.
