# How car works

car is short for continuous action recording. This is everything about using
it and what it records, for a person or an agent. The
[README](../README.md) is the short version.

## The keys

One gesture, ⌥ tapped twice, and what you hold with it says what it does:

| | |
|---|---|
| **⌘ ⌥ ⌥** | start a session, or stop the one running |
| **⌥ ⌥** | set a marker for an agent |
| **⇧ ⌥ ⌥** | copy what you just said, as text |

Hold ⌘ or ⇧ (or neither) through both taps. Nothing else starts or stops a
session. The keys need Accessibility; Settings turns them off and on.

## A session

A session is meant to run for hours: start it when you sit down, stop it when
you are done. While it runs, a dot at the bottom of the screen (🏎️ ●) says
so, and brightens with the sound coming in, so a glance says the microphone
hears you. It opens into the toolbar while the pointer is on it: the time and
the level, pause and stop, the drawing tools and inks, and the eraser. Every
button lights up under the pointer and says what it does if the pointer
rests on it. The 🏎️ menu has *Stop Session*, *Pause Session*, *Set Marker*
and *Discard Session…* too.

Paused, nothing is recorded (no sound, no actions, no pictures) and the
microphone is let go, until you resume; the session stays open, its clock
keeps time, and markers still work. The timeline says `paused` and `resumed`
where it happened.

Nothing plays, and nothing is uploaded except the sound to the transcription
model you chose, a chunk at a time.

## Markers: handing it to an agent

Tap **⌥ twice** whenever you want an agent to act on what you have been
saying. car sets a marker at that moment and puts one line on the clipboard:

```
car marker 3 set at 12:31:05 pm in session 20260924-122534
```

Paste it into an agent that knows car (its skill is
[`skill/SKILL.md`](../skill/SKILL.md)). It runs `car marker 20260924-122534 3`
and reads what you said since the marker before, reaching further back
(`--from -30m`, `--from start`) when your words point there ("like I said
earlier"). The marker also cuts the sound there, so the words up to it are
transcribed straight away; `car marker` waits the few seconds that takes.

## Quick dictation

Hold **⇧** and tap **⌥ twice** to answer a message out loud without leaving
the session: car cuts the sound there, waits for its words (a few seconds),
and puts what you said since your last pause of 15 seconds or more on the
clipboard as text, ready to paste. The pause is a setting (Settings →
Recording). The session carries on as it was, and the timeline notes it:
`copied what was said since 01:02.000 to the clipboard (42 words)`.

## The window

car is an app like any other: open it and its window shows every session
down the side, newest first, each with the first words said in it, and the
one picked read as a script: a row for each moment, with when it was said in
the margin, what was said, what was done around it, and the pictures taken
then. Click a picture to see it big; ← and → step through every picture in
the session. A marker is a line across with a button that copies it for an
agent. Where the words are still to come, the row says so; a session being
recorded reads live and grows at the bottom.

Settings is the gear at the foot of the sidebar (⌘,): the models, the key,
the microphones, the sound's quality, quick dictation's pause, the keys, what transcription has
cost, what car keeps on the disk, the permissions, and which build this is.

Closing the window leaves car running, and recording if it was. The 🏎️ in
the menu bar starts, stops and marks sessions from any app, and opens the
window.

## Drawing while you talk

The toolbar has a pen, an arrow, a circle and a rectangle, and one row of inks
(red, yellow, green, blue, purple) shared by all four. Pick a tool and drag
anywhere on any screen. A shape is drawn once and the pointer goes back to your
apps; the pen stays in hand for the next stroke. A click without a drag, Esc,
or the tool's button again puts a tool down. ⇧ makes a true circle, a square,
or an arrow at 45°.

A drawing is a gesture made while talking, not a note left on the screen: it
holds for six seconds and fades over three. When what it was drawn on changes
a lot (another tab, a scroll, a model turned), it fades in half a second. car
watches the screen under each drawing with a small, slow capture while
drawings are up, and not at all otherwise. The eraser wipes them all at
once; the session keeps them.

Each drawing is a mark, numbered in the order drawn: *red circle 1*, *blue
arrow 2*. It is recorded with what it was drawn on, set into the words at the
moment it was drawn, drawn with its number into every picture taken while it
is up, and gets a picture of the whole screen the moment it is finished. So
"this part here" has an answer:

```
[00:12.050–00:15.900] “so this part here {red circle 1} is the one that's wrong”
[00:13.200] drew red circle 1 around button “Save” in Safari “Settings”
[00:13.260] picture …/sessions/20260924-122534/shots/00013260.jpg (red circle 1)
[00:16.410] red circle 1 faded as the screen under it changed
```

## Where it all is

The catalog, `car.sqlite`, holds everything about every session: the
session, its chunks of sound, every word, every event, every marker, what
transcribing it cost, and where each of its files is. The files are only the
heavy data:

```
sessions/20260924-122534/
  audio/0001.m4a   the microphone, a chunk each, at the session's sound quality
  shots/*.jpg      the focused window when something changed; the whole screen for a drawing
  session.md       the timeline, written out when the session finishes
  .lock            held by whoever is recording or transcribing it
```

Each file sits in a store (this Mac's sessions folder, or the recordings
folder) at a path the catalog records, so old pictures can move to another
drive by copying them and changing their rows. The timeline names each
picture where it is now.

**The recordings folder.** Settings → Recording → Keep recordings in can put
the sound and pictures somewhere else: a folder on an external drive, say.
Each file goes there if the folder is there at the moment it is written, and
to this Mac's sessions folder if it is not, so a drive that is not plugged
in, or is unplugged in the middle of a session, never costs a recording. The
pill says when a session starts without the folder, and each time it goes
or comes back. The catalog, the timelines and the locks stay on this Mac.
Choosing the folder writes to it once straight away, so anything macOS asks
about the drive is asked then and not in the middle of a session.
`car config recordings <folder|none>` sets it too.

Times are milliseconds on one clock for words and events alike, a clock that
keeps counting while the Mac sleeps, so "the word *here*" and "the click"
compare directly however long the session runs. Places on the screen (a
click, a mark) are points from the top-left corner of the main display, the
space the accessibility API and the window server use.

A session is `recording`, then `transcribing` (its last chunks, after it
stops), then `done` or `failed`. Whoever is recording or transcribing one
holds its lock, so a session a crash or a quit left unfinished is found and
finished by the app at its next launch, or by `car session` or `car marker`
when asked for it. A crash loses at most the chunk being written.

## The sound, a chunk at a time

The microphone is recorded as chunks of about three minutes, each cut at the
first pause after that (four minutes at most), so each is transcribed while
the next records. A marker cuts one on the spot. Each chunk is stamped on the
session clock from the moment its first sample arrived.

Which microphone: Settings → Microphones is a list in order. car records
from the first one on it that is connected; when that one is unplugged it
moves to the next, not to whatever the Mac's default is, and when one higher
up is plugged back in it moves back up, cutting the chunk there. Below the
list is always the system default, for when none of them is connected. A
microphone that is open but sends nothing for four seconds (another app took
the camera it belongs to) is opened again, and after two tries it is passed
over for the next one down, until it is unplugged and plugged back in. The
pill says so each time it moves, and the timeline says which microphone
every stretch came from (`microphone → Wireless Lav`). The microphone also
reopens when the Mac wakes from sleep.

## Sound quality

Settings → Recording → Quality picks how a session keeps its sound, from the
next session on:

- **Low**: 16 kHz mono AAC, about 14 MB an hour. Enough for the words.
- **Medium**: 48 kHz mono AAC at 160 kbps, about 70 MB an hour. Good enough
  to publish: the narration of a video, say.
- **High**: 48 kHz mono Apple Lossless, 24-bit, about 300 MB an hour (less
  in a quiet room). The microphone exactly as it came.

Transcription hears every quality at 16 kHz, so a better one costs disk and
nothing else: not time, not money. A session's first line says which it was
kept at (`session start, sound kept at 48 kHz, lossless`).

`car audio <session> --from M --to M --out narration.wav` joins a stretch
of a session's chunks back into one file (WAV, 24-bit, at the rate it was
kept at), each chunk at its place on the session clock and silence where
nothing was recorded, ready for a video editor. `M` is any moment, as for
`car session`, so `--from m2 --to m3` is what was said between two markers.

## From sound to words

A session runs all day and is mostly quiet, so the first question about a
chunk is whether anyone spoke in it, and that is answered without a model
(`Voice.swift`): a 20 ms frame is voice when it is louder than the room (9 dB
over the noise floor of the last few seconds) and it buzzes at a voice's pitch
(its autocorrelation peaks at a lag of 70–400 Hz), which fans, hiss, clicks
and keyboards do not. Frames become stretches, short gaps between syllables
are bridged, and each stretch is widened a quarter second to keep its soft
edges. Checked against the words of real sessions, it catches 98.8% of words
at their onset and keeps about 1.4 times the time actually spoken; a chunk
with no voice goes no further and costs nothing.

The voice alone is cut into one short clip, and two models hear it:

1. **The remote model** writes the words: a cloud model on OpenRouter
   (default `google/gemini-3-flash-preview`), asked for a verbatim transcript
   with the fillers left in. It is billed for the voice, not the chunk, and its
   answer is capped at what a person could say in the time, so a model that
   starts repeating itself is stopped there. Pick any audio-capable model, or
   none, in Settings (*Words by*) or with `car config remoteModel <id>`;
   `car models` lists them.
2. **The local model** keeps time: Apple's recognizer on this Mac stamps every
   run of its own transcript with the audio range it was heard in. Its words
   are worse; its clock is real, because it comes from the sound. It writes
   the words when there is no remote model. It is asked with a deadline, since
   fetching its language model has been seen to hang for minutes; set it to
   none in Settings (*Times by*) and the words are spread over the voice
   by length instead.

The two are lined up by a global word alignment (`Align.swift`): each word of
the remote model's transcript that matches a timed word takes its time; a word
with no partner is placed between its matched neighbours by its length. Then
every word is fitted to the sound (`Refine.swift`). A recognizer gives a pause
to the word after it, so that word would start where the speech before the
pause stopped, seconds early; a pause of a quarter second or more inside a
word's span is taken out, and the word starts at the first rise after it.
Otherwise the start moves to the onset heard in a short window around the
local model's boundary, which is what gets it within a frame. A word ends
where the sound falls into a pause, so a pause reads as the gap between two
words, never inside one. `car words` says how each word was timed: `matched`,
`interpolated` or `spread`, with `+pause` when its start was moved past a
pause and `+onset` when it was snapped.

**Judging a remote model's clock.** `car bench <id> --chunk N --model <id>`
asks a model for its own timestamped segments, lays the same words onto both
and reports the per-word difference in start time. On a 14 s clip,
`google/gemini-3-flash-preview` placed words a median 717 ms from the local
model, 4% within one frame, which is why the local model keeps time.

## What gets recorded

Two readings of what is in front of you, both always taken:

- **Generic, every app.** The front app, its focused window's title and
  document (a path or URL, for apps that say), the focused element (role,
  title, value, selected text), clicks with the element under the pointer,
  scrolls, shortcuts (`⌘S`) and the keys that act (return, tab, esc, the
  arrows), and typing as *how many keys went into which element, and what it
  then held*. Every other key counts as typing wherever it goes (a terminal
  does not look like a text field). Keystrokes themselves are never logged,
  and a password field's value is never read.
- **Adapters, for apps with a better answer.** Finder: the folder in front
  and the files selected in it. Browsers (Safari, Chrome, Brave, Arc, Edge,
  Vivaldi): the front tab's URL and title. An app that ships a command of its
  own name in `Contents/Resources` with a `desk` subcommand: what it prints.
  Adding an adapter is one function in `Adapters.swift` that returns a
  dictionary.

All of this is asked of other apps off the main thread, each question with a
short limit, so a hung app costs a reading and never the pill or the session.

Pictures: a JPEG of the focused window, at most ~1.5 MP, when the front app
or window changes, after a click or a scroll when the screen changed, never
more than one every 0.7 s, and only when it differs from the last one (a
difference hash). A drawing gets a picture of its whole screen regardless.
What was recorded as text is also recorded as a picture, because the text
reading is sometimes wrong about what a window is showing. car's own pill and
drawing layer are never in a picture; the drawings are drawn in by car, with
their numbers.

## Cost and the key

Every call to OpenRouter is in the catalog with what it cost. Settings shows
today, the last 7 and 30 days and all of it, and the last 30 days by model;
each session's cost is at the top of its script; `car usage` prints the same.
No key ships with car: with a remote model chosen, the first session asks for
one (Settings changes it). It is kept in
`~/Library/Application Support/car/openrouter.key`, readable by you only, or
comes from `OPENROUTER_API_KEY`. With no remote model, no key is needed and
the words are the local model's.

## Install

car is not distributed as a download: you build it. It needs macOS 26 (the
on-device recognizer), Xcode, and `xcodegen` (`brew install xcodegen`).
Nothing else: the app uses only what comes with macOS, so it behaves the
same on every Mac.

```
./build.sh release
```

runs CarKit's tests, builds, signs with the first Apple Development identity
in the keychain (ad hoc without one), installs `/Applications/car.app`, and
launches it; at launch it links the `car` command into `~/.local/bin`. It
refuses while car is recording or transcribing, and otherwise quits the
running copy properly first, so it is also how car is updated. Plain
`./build.sh` builds the development copy instead, `/Applications/car-dev.app`
and `car-dev`, which runs beside the real one with its own catalog, sessions,
settings, log and permissions, and its keys off until turned on in its
Settings (both copies see every tap of ⌥, and one gesture would reach both).
The version, the commit it was built from, is in Settings → About and in
`car version`.

Then, in Settings → Permissions: **Accessibility** (the keys, and what is
focused), **Microphone**, **Screen Recording** (pictures, and fading drawings
when the screen changes), and **Automation** for Finder and each browser
(their selection and tabs). Each is a one-time system prompt: macOS keeps a
grant for as long as the app keeps its bundle id and is signed with the same
certificate, which `build.sh` holds to (it refuses a real car signed any
other way unless `NEW_SIGNATURE=1`). The development copy is another app to
macOS, with grants of its own.

## The command

```
car marker [<id|last> [<n|last>]] [--from M]   what was said up to a marker; waits for its words
car session <id|last> [--from M] [--to M]      the timeline, whole or a stretch
car events <id|last> [--from M] [--to M]       every event, JSON, one a line
car words <id|last> [--from M] [--to M]        every word, JSON, one a line
car audio <id|last> [--from M] [--to M] [--out FILE]
                                               the sound of a stretch as one WAV, at the quality it was kept at
car sessions                                   every session
car status                                     what is being recorded or transcribed now
car usage                                      what transcription has cost
car pointer <id|last>                          the line that hands over a whole session
car transcribe <id|last> [--again|--all] [--remote-model M|none] [--local-model apple|none]
                                               transcribe what is left (or failed, or all of it again)
car refit <id|last>                            time a session's words to its sound again, the way car does now; no model, no cost
car bench <id|last> [--chunk N] --model M      a model's clock against the on-device one
car models | config [remoteModel|localModel|soundQuality|dictationPause|keys value] | render <id|last> | guide | version
```

A moment `M` is `start`, `end`, `m3` (marker 3), `-20m` or `-90s` (before
the end of the stretch), or a time on the session clock (`12:30`,
`1:02:03`).

Everything lives under `~/Library/Application Support/car/`; the log is
`~/Library/Logs/car.log`. The development copy's are `car-dev` in both
places.
