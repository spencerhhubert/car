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

Beside the menu bar there are now two windows: the sessions, read as a
script (words, what was done around them, the pictures, live while
recording, a picture big on a click), and Settings, which took everything
that was a choice out of the menu. How they look and how their code is kept
from breaking is `docs/design-system/`; `tools/viewcheck` renders them to
pictures for checking.

Verified:
- CarKit's tests (`swift test --package-path CarKit`): alignment, onsets,
  remarks with drawings and markers, the clock, moments, pointer lines, mark
  geometry, fading, the catalog, and the script's rows (what goes near a
  remark, words still to come, markers, repeats folding, long gaps) and
  quick dictation's stretch.
- The windows rendered from a real session in light and dark
  (`tools/viewcheck`): the script, the sidebar rows, the picture viewer,
  Settings.
- Earlier: a marker waiting for its words, a session picked up after a
  crash, the screen-change test, the voice detection against real sessions.

Not verified live yet: the new keys (⌘ ⌥ ⌥ and ⇧ ⌥ ⌥; ⌥ ⌥ is unchanged),
quick dictation end to end, the sessions window with a person's mouse (the
toolbar, the Dock icon coming and going, keys in the picture viewer), the
microphone watchdog. car-dev has them; it needs its grants and its keys
turned on. `tools/live-test.txt` still plays the old hold-⌥ flow.

The microphone watchdog came from a real loss: a session recorded nine
minutes with the microphone (a webcam's, whose camera another app had just
opened) sending nothing, and nothing noticed. Now four seconds without a
buffer reopens it, two failed tries fall back to the system default, and the
pill says so.

## Renaming owl to car

The repo, the package (CarKit), the apps (car, car-dev), the bundle ids
(com.car.mac…), the folders (`Application Support/car`, `car.sqlite`,
`car.log`) and the lines on the clipboard all say car. owl-dev's data was
moved to car-dev with a one-off script (folder, catalog file, the catalog's
store root, the log; old app and command removed). The installed owl is
moved the same way once it is idle and the person says so. A new bundle id
means new grants: Accessibility, Microphone, Screen Recording and Automation
are given again, once.

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
