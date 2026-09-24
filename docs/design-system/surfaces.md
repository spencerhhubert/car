# Surfaces

Everything car shows, what each is for, and how it is laid out.

## The menu bar item and its menu (`StatusMenu.swift`)

car is an ordinary app with one window, in the Dock and the app switcher;
the 🏎️ in the menu bar (🏎️● while recording, 🏎️dev for the development
copy) is for working in other apps. Its menu is short on purpose: the
session (Start Session; or Stop Session with its length, Set Marker,
Discard Session… while recording), Open car, Settings…, Quit. A gesture that
does the same as an item is shown to its right, where a key equivalent would
be ("⌘ ⌥ ⌥").

## The pill (`Pill.swift`)

A dot at the bottom of the screen while a session records, brightening and
glowing with the sound coming in (a pause sign while paused), opening into
the toolbar under the pointer: the clock and level, pause and stop, the four
tools, the inks, the eraser. A word when something happens
("marker 3 · copied"); how transcription went when a session stops. It
floats over other apps without taking focus, so it uses the `hud` text
style and a material capsule, and its sizes are `Metrics.Pill`.

Every toolbar button is a `PillButtonStyle`: a square (a circle for an ink)
that lights under the pointer, darkens while pressed, and takes the ink's
color while its tool is in hand, so where a click lands is always visible.
Every button has a tooltip in a sentence, and the panel allows tooltips
while car is not the app in front, which it never is while the pill is in
use.

## The window (`Window/MainWindow.swift`)

One window: a sidebar and a main pane, with a unified toolbar: the sidebar
toggle at the left, and at the right Copy for Agent (the line that hands the
session to an agent) and Show in Finder. The window title is the page in
front, for the Window menu and Mission Control. Closing it leaves car
running; the Dock icon, ⌘0 or Open car brings it back.

**Sidebar** (`Sidebar.swift`): sessions by day, newest first. A row is the
start time, the length at the right (or a dot and a running clock while
recording, a spinner while transcribing, an orange triangle when some of it
failed), and the first words said in it, two lines, like Mail and Notes. At
its foot, Settings (a gear, tinted while Settings is in front; ⌘,).

**The script** (`ScriptController.swift`, `ScriptView.swift`,
`ScriptLayout.swift`): one long scroll, an AppKit table of SwiftUI rows.

```
Today, 2:15 pm  ● Recording
12:08 · 719 words · 97 pictures · 3 markers · $0.012

2:15:48 pm   Um, okay, you should be able to     ▭ Switched to Ghostty  tmux      ┌──────────┐
             find, what is it called?            ↖ Clicked “Terminal…”  text area │ picture  │
                                                 ⌨ Typed 2 keys  into …           └──────────┘
2:17:57 pm   ⚑ Marker 1 ──────────────────────────────────────────────────────── ⧉
2:18:40 pm   ▬▬▬▬▬▬▬▬▬▬▬▬ Transcribing
             ▬▬▬▬▬▬▬▬
             12 minutes later
```

- The margin is the wall time the row starts, in `time`. The first column,
  as wide as the others leave it, is what was said, in `speech`, with the
  drawings made while it was said in their ink. The second is what was done
  from a moment before the words to a few seconds after: one line each, a
  symbol and a phrase in `action` with its detail in `detail`, repeats
  folded ("×3"), at most six and then "4 more". The third is the pictures
  taken then: the first filling the column's width, the rest small beneath.
- A row where nothing was said has only the actions and pictures. A marker
  is a line across with a button that copies its line for an agent. A long
  stretch of nothing says how long.
- Where the words are still to come the row holds their place (`Pending`);
  a live session grows at the bottom and the view stays there while it is
  left there. The footer says what is happening: recording, transcribing,
  what failed, or when it ended.
- Column widths come from the pane's width (`Columns`): actions about a
  quarter (180 to 300), pictures about a fifth (140 to 200), words the rest.

## The picture viewer (`PictureViewer.swift`)

Over the script, on black: the picture as big as the pane allows; beneath,
its time, why it was taken, its place among all the session's pictures, and
what was being said. ← and → step through every picture in the session; Esc,
space, a click beside it or the close button put it away.

## Settings (`Window/SettingsView.swift`)

A page of the window, in a column 620 points wide: grouped sections like a
pane of System Settings. Transcription (the model that writes the words, the
one that keeps time, the key), Microphones (the list in order, each with up,
down and remove, then the system default and Add Microphone), Recording
(the sound's quality, quick dictation's pause), Keys (on or off, and the three gestures), Spent on transcription,
Permissions (each with Grant… until it is given), Disk (pictures, sound, the
catalog, all of it, and what is free on the disk), About (version, the log).
Changes save as they are made. Footers explain in one or two sentences, in
`note`.
