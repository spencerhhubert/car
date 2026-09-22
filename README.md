# owl 🦉

A menu bar app for the Mac that records your voice and everything you do on
the computer, as one timeline: every word with the moment it was said, and
every app, window, click, selection, page and file that was in front of you
when you said it, with pictures.

Hold ⌥ and talk. Let go to stop, or keep holding past 1.5 s and it latches:
you can let go and the session runs until you press ⌥ again. A double-click
inside a text field also starts one. A pill at the bottom of the screen shows
it is recording, with the level; the X on it throws the session away.

When a session ends, the sound is transcribed and the timeline is written.
Nothing plays, nothing is uploaded except the audio to the transcription
model you chose.

## What a session looks like

```
sessions/20260922-104412/
  audio.m4a        the microphone, 16 kHz mono AAC
  events.jsonl     what happened, one event per line
  shots/*.jpg      the focused window when something changed
  transcript.txt   the words
  words.json       every word: start and end in ms on the session clock, and how it was timed
  session.md       the timeline, words and events interleaved
  meta.json        when, how long, which models, cost
```

`session.md` is meant to be read by a person or an agent:

```
[00:02.100] app → Finder
[00:02.350] window Finder “Downloads” (file:///Users/me/Downloads/)
[00:02.600] picture shots/00002600.jpg (window)
[00:03.120–00:05.870] “okay so these two files here”
[00:04.200] click left Finder row “IMG_1234.MOV”
[00:04.400] finder in /Users/me/Downloads/ selected: /Users/me/Downloads/IMG_1234.MOV, /Users/me/Downloads/IMG_1235.MOV
```

Everything an agent might want beyond that is a file beside it: `words.json`
for the exact moment of a word, `events.jsonl` for the full detail of an
event (the whole accessibility description of what was clicked), `shots/` for
what the screen showed. The timeline names each picture so a reader can open
the one it needs.

Times are milliseconds on one monotonic clock for words and events alike, so
"the word *here*" and "the click" are directly comparable. Each word also
carries its position in the audio file (`s`, `e`, seconds) for pulling that
moment of sound.

## What gets recorded

Two readings of what is in front of you, both always taken:

- **Generic, every app.** The front app, its focused window's title and
  document (a path or URL, for apps that say), the focused element (role,
  title, value, selected text), clicks with the element under the pointer,
  scrolls, shortcuts (`⌘S`), and typing as *how many keys went into which
  field, and what the field then held*. Keystrokes themselves are never
  logged, and a password field's value is never read.
- **Adapters, for apps with a better answer.** Finder: the folder in front
  and the files selected in it. Browsers (Safari, Chrome, Brave, Arc, Edge,
  Vivaldi): the front tab's URL and title. Adding an adapter is one function
  in `owl/Adapters.swift` that returns a dictionary.

Pictures: a JPEG of the focused window, at most ~2 MP, when the front app or
window changes, after a click or a scroll, never more than one every 0.7 s
and only when it differs from the last one (a difference hash). What was
recorded as text is always also recorded as a picture, because the text
reading is sometimes wrong about what a window is showing.

## How the words get their times

Two models, two jobs:

1. **The words** come from a cloud model on OpenRouter (default
   `google/gemini-3-flash-preview`), asked for a verbatim transcript with the
   fillers left in. Pick any audio-capable model from the menu or with
   `owl config textModel <id>`; `owl models` lists them.
2. **The times** come from Apple's on-device recognizer, which stamps every
   run of its own transcript with the audio range it was heard in. Its words
   are worse; its clock is real, because it comes from the sound rather than
   from a model's sense of where in a file a sentence sits.

The two are lined up by a global word alignment (`owl/Align.swift`): each
word of the text model's transcript that matches a timed word takes its
time; a word with no partner is placed between its matched neighbours by its
length. Then every word's start is moved to the onset actually heard in the
sound, inside a short window around the recognizer's boundary
(`owl/Refine.swift`), which is what gets it within a frame.

`words.json` says how each word was timed: `matched`, `interpolated`, with
`+onset` when the start was snapped.

**Judging a time source.** `owl bench <id> --model <id>` asks a model for
its own timestamped segments, lays the same words onto both and reports the
per-word difference in start time. On a 14 s clip, `google/gemini-3-flash-preview`
placed words a median 717 ms from the on-device times, 4% within one frame,
which is why it does not keep time by default. `owl config timeSource
openrouter:<model>` switches to a model's clock if one ever does better.

## Install

Needs macOS 26 (the on-device recognizer), Xcode, and `xcodegen`
(`brew install xcodegen`). `ffmpeg` is optional: with it the audio is sent
to the text model as a small mp3, without it as the AAC file it was recorded
as.

```
./build.sh
```

builds, signs with the first Apple Development identity in the keychain
(ad hoc without one), installs `/Applications/owl.app`, links the `owl`
command into `~/.local/bin`, and launches it. Then, from the owl menu →
Permissions: **Accessibility** (to see the gesture and what is focused),
**Microphone**, **Screen Recording** (pictures), and **Automation** for
Finder and each browser (their selection and tabs). Each is a one-time
system prompt.

The OpenRouter key goes in `~/Library/Application Support/owl/openrouter.key`
(one line) or `OPENROUTER_API_KEY`. Without one, sessions are still recorded
and timed; the words are then the on-device recognizer's.

## The command

```
owl sessions                          every session
owl session last                      the timeline
owl transcribe last [--text-model M] [--time-source apple|openrouter:M]
owl bench last --model M              a model's clock against the on-device one
owl models                            audio-capable models on OpenRouter
owl config [key value]                textModel, timeSource, doubleClick, enabled
owl render last                       rewrite session.md from what is on disk
```

Everything lives under `~/Library/Application Support/owl/`; the log is
`~/Library/Logs/owl.log`.
