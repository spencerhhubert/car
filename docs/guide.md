# How owl works

Everything about using owl and what it records, for a person or an agent.
The [README](../README.md) is the short version.

## A session

A session is meant to run for hours: start it when you sit down, stop it when
you are done. **⌘⇧R** starts it and **⌘⇧R** stops it; nothing else does.
While it runs, a dot at the bottom of the screen (🦉 ●) says so, and opens
into the toolbar while the pointer is on it: the time and the level, the
drawing tools, and the bin. The menu has *Stop session*, *Set marker* and
*Discard session…* too.

Nothing plays, and nothing is uploaded except the sound to the transcription
model you chose, a chunk at a time.

## Markers: handing it to an agent

Tap **⌥ twice** whenever you want an agent to act on what you have been
saying. owl sets a marker at that moment and puts one line on the clipboard:

```
owl marker 3 set at 12:31:05 pm in session 20260924-122534
```

Paste it into an agent that knows owl (its skill is
[`skill/SKILL.md`](../skill/SKILL.md)). It runs `owl marker 20260924-122534 3`
and reads what you said since the marker before, reaching further back
(`--from -30m`, `--from start`) when your words point there ("like I said
earlier"). The marker also cuts the sound there, so the words up to it are
transcribed straight away; `owl marker` waits the few seconds that takes.

## Drawing while you talk

The toolbar has a pen, an arrow, a circle and a rectangle, and one row of inks
(red, yellow, green, blue, purple) shared by all four. Pick a tool and drag
anywhere on any screen. A shape is drawn once and the pointer goes back to your
apps; the pen stays in hand for the next stroke. A click without a drag, Esc,
or the tool's button again puts a tool down. ⇧ makes a true circle, a square,
or an arrow at 45°.

A drawing is a gesture made while talking, not a note left on the screen: it
holds for six seconds and fades over three. When what it was drawn on changes
a lot (another tab, a scroll, a model turned), it fades in half a second. owl
watches the screen under each drawing with a small, slow capture while
drawings are up, and not at all otherwise. The bin wipes them all at once.

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

The catalog, `owl.sqlite`, holds everything about every session: the
session, its chunks of sound, every word, every event, every marker, what
transcribing it cost, and where each of its files is. The files are only the
heavy data:

```
sessions/20260924-122534/
  audio/0001.m4a   the microphone, a chunk each, 16 kHz mono AAC
  shots/*.jpg      the focused window when something changed; the whole screen for a drawing
  session.md       the timeline, written out when the session finishes
  .lock            held by whoever is recording or transcribing it
```

Each file sits in a store (to begin with, this Mac's sessions folder) at a
path the catalog records, so old pictures can move to another drive by
copying them and changing their rows. The timeline names each picture where
it is now.

Times are milliseconds on one clock for words and events alike, a clock that
keeps counting while the Mac sleeps, so "the word *here*" and "the click"
compare directly however long the session runs. Places on the screen (a
click, a mark) are points from the top-left corner of the main display, the
space the accessibility API and the window server use.

A session is `recording`, then `transcribing` (its last chunks, after it
stops), then `done` or `failed`. Whoever is recording or transcribing one
holds its lock, so a session a crash or a quit left unfinished is found and
finished by the app at its next launch, or by `owl session` or `owl marker`
when asked for it. A crash loses at most the chunk being written.

## The sound, a chunk at a time

The microphone is recorded as chunks of about three minutes, each cut at the
first pause after that (four minutes at most), so each is transcribed while
the next records. A marker cuts one on the spot. Each chunk is stamped on the
session clock from the moment its first sample arrived. The microphone
reopens by itself when it changes or disappears (headphones connecting) and
when the Mac wakes from sleep.

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
   none, from the menu (*Remote model*) or with `owl config remoteModel <id>`;
   `owl models` lists them.
2. **The local model** keeps time: Apple's recognizer on this Mac stamps every
   run of its own transcript with the audio range it was heard in. Its words
   are worse; its clock is real, because it comes from the sound. It writes
   the words when there is no remote model. It is asked with a deadline, since
   fetching its language model has been seen to hang for minutes; set it to
   none from the menu (*Local model*) and the words are spread over the voice
   by length instead.

The two are lined up by a global word alignment (`Align.swift`): each word of
the remote model's transcript that matches a timed word takes its time; a word
with no partner is placed between its matched neighbours by its length. Then
every word's start is moved to the onset actually heard in the sound, inside a
short window around the local model's boundary (`Refine.swift`), which is what
gets it within a frame. `owl words` says how each word was timed: `matched`,
`interpolated` or `spread`, with `+onset` when the start was snapped.

**Judging a remote model's clock.** `owl bench <id> --chunk N --model <id>`
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
reading is sometimes wrong about what a window is showing. owl's own pill and
drawing layer are never in a picture; the drawings are drawn in by owl, with
their numbers.

## Cost and the key

Every call to OpenRouter is in the catalog with what it cost. The menu shows
today and the last 30 days, with a breakdown by span and by model; `owl usage`
prints the same. No key ships with owl: with a remote model chosen, the first
session asks for one (the menu's *OpenRouter key* changes it). It is kept in
`~/Library/Application Support/owl/openrouter.key`, readable by you only, or
comes from `OPENROUTER_API_KEY`. With *Remote model → none*, no key is needed
and the words are the local model's.

## Install

owl is not distributed as a download: you build it. It needs macOS 26 (the
on-device recognizer), Xcode, and `xcodegen` (`brew install xcodegen`);
`ffmpeg` is optional (with it the voice is sent as a small mp3).

```
./build.sh release
```

runs OwlKit's tests, builds, signs with the first Apple Development identity
in the keychain (ad hoc without one), installs `/Applications/owl.app`, and
launches it; at launch it links the `owl` command into `~/.local/bin`. It
refuses while owl is recording or transcribing, and otherwise quits the
running copy properly first, so it is also how owl is updated. Plain
`./build.sh` builds the development copy instead, `/Applications/owl-dev.app`
and `owl-dev`, which runs beside the real one with its own catalog, sessions,
settings, log and permissions, and its keys off until turned on from its menu
(both copies can hold ⌘⇧R, and one press would start a session in each). The
version, the commit it was built from, is at the top of the menu and in
`owl version`.

Then, from the owl menu → Permissions: **Accessibility** (⌥ ⌥ and what is
focused), **Microphone**, **Screen Recording** (pictures, and fading drawings
when the screen changes), and **Automation** for Finder and each browser
(their selection and tabs). Each is a one-time system prompt.

## The command

```
owl marker [<id|last> [<n|last>]] [--from M]   what was said up to a marker; waits for its words
owl session <id|last> [--from M] [--to M]      the timeline, whole or a stretch
owl events <id|last> [--from M] [--to M]       every event, JSON, one a line
owl words <id|last> [--from M] [--to M]        every word, JSON, one a line
owl sessions                                   every session
owl status                                     what is being recorded or transcribed now
owl usage                                      what transcription has cost
owl pointer <id|last>                          the line that hands over a whole session
owl transcribe <id|last> [--again|--all] [--remote-model M|none] [--local-model apple|none]
                                               transcribe what is left (or failed, or all of it again)
owl bench <id|last> [--chunk N] --model M      a model's clock against the on-device one
owl models | config [remoteModel|localModel|keys value] | render <id|last> | guide | version
```

A moment `M` is `start`, `end`, `m3` (marker 3), `-20m` or `-90s` (before
the end of the stretch), or a time on the session clock (`12:30`,
`1:02:03`).

Everything lives under `~/Library/Application Support/owl/`; the log is
`~/Library/Logs/owl.log`. The development copy's are `owl-dev` in both
places.
