# AGENTS.md

owl: a Mac menu bar app that records a person's voice and what they do on the
computer as one timeline. Read `README.md` first, then
`agent-notes/handoff.md` (where the work stands), then `agent-notes.local/`
if it exists (facts about this machine, never tracked).

## How this program is kept

- **You maintain it.** This codebase is yours to keep in good shape, not a
  place to drop a patch and leave. Anyone opening any file should find code
  that is clean, consistent and plainly correct. When you see something wrong
  or untidy while you are in there, fix it.
- **Build every feature as if it had been planned from the start.** A new
  feature reshapes the structure around it: names, types, files and what a
  session writes change so the result reads as designed, not bolted on. No
  side paths, special cases or flags grafted onto the old shape. When
  something is replaced, the old version goes in the same change. Git is the
  backup.
- **Rock solid and efficient.** owl runs all day on someone's computer and
  sits in the path of everything they do. That means:
  - Nothing that waits on another app runs on the main thread. Accessibility
    reads, Apple events and subprocesses go through the reader queue
    (`Adapters.swift`), and every one has a timeout.
  - Nothing runs that does not need to: no work while idle beyond watching
    for the gesture, and windows and taps exist only while in use.
  - A crash, a quit or a hung app never costs a session. Sessions carry a
    state and a lock (`Session.swift`), and an unfinished one is finished by
    whoever finds it.
  - Measure CPU and memory before calling a change done.

## Working on it: the dev copy

The person uses the real owl while you work. **Never stop, restart or replace
`/Applications/owl.app` unless they say so.**

- `./build.sh` builds and installs the development copy,
  `/Applications/owl-dev.app`, with the `owl-dev` command. It has its own
  bundle id, sessions and settings (`Application Support/owl-dev`), log
  (`~/Library/Logs/owl-dev.log`) and permissions, and the menu bar shows it as
  🦉dev. Its gesture is off by default (turn it on from its menu), so one hold
  of ⌥ never starts two sessions. It reads the OpenRouter key from the real
  copy's folder when it has none. `build.sh` only ever quits and replaces
  owl-dev.
- `./build.sh release` builds and installs the real owl. It refuses while owl
  is recording or transcribing (`owl status`), otherwise quits it (SIGTERM is
  a proper quit: a session that has just started is closed, not cut off) and
  swaps in the new build. Run it only when the person asks.
- The dev copy needs its own grants (Accessibility, Microphone, Screen
  Recording, Automation) before it can record. Only the person can give them,
  from its menu → Permissions.

## Rules

- **Write every tracked file as if the repo were public.** No machine names,
  addresses, account names, paths on a server, keys, or anything about the
  person whose sessions these are. That goes in `agent-notes.local/`
  (gitignored).
- **Never play audio, and never make the machine produce sound.** Test the
  speech pipeline on a file written to disk (`say -o`, ffmpeg) and read the
  numbers back. The person listens, if anyone does.
- **A session is someone's life.** Sessions live outside the repo under
  Application Support; never copy one into the repo, a test fixture, or a
  commit. A synthetic clip is the test fixture.
- **Never print or commit a credential.** The key is read from a file or the
  environment and never logged. `git diff --cached` before every commit.
- **The grants** (Accessibility, Microphone, Screen Recording, Automation per
  app) can only be given by the person, in System Settings. Say so; do not
  work around it.
- **Never drive the person's screen to test.** No synthetic clicks or keys,
  and no windows on their screen beyond owl-dev's own. Views are checked by
  rendering them offscreen (see below).

## Layout

```
owl/            the app and the `owl` command, one binary (main.swift decides)
  App.swift        menu bar, the menu, sessions: one recording, any number transcribing
  Recording.swift  the session being recorded: microphone, watcher, drawing
  Gesture.swift    hold ⌥ / double-click; TextProbe
  Pill.swift       the floating pill: time, level, drawing tools, stop, discard
  Drawing.swift    the drawing layer: tool in hand, ink, canvas windows, Escape tap
  Marks.swift      what a mark is: tools, inks, geometry, how it draws itself
  Session.swift    a session folder, its clock, events.jsonl, Meta, SessionLock
  Watcher.swift    what the person does → events (workspace, AX observer, monitors, poll, marks)
  Adapters.swift   the reader queue; the generic reading + Finder, browser and desk adapters
  AX.swift         accessibility helpers, hit tests, element descriptions; Space
  Screenshot.swift window and display pictures, marks drawn in, dHash dedupe
  Mic.swift        AVAudioEngine → 16 kHz mono AAC; input devices
  OpenRouter.swift the words (and optionally times) from a cloud model
  AppleTimes.swift word times from the on-device recognizer
  Align.swift      lay the text model's words onto the timed words
  Refine.swift     snap word starts to heard onsets; keep them monotonic
  Transcribe.swift the pipeline and its states; bench
  Render.swift     session.md, marks set into the words
  Pointer.swift    the note for an agent that a stopped session leaves on the clipboard
  CLI.swift        the command
  Config.swift     settings, where things live, owl vs owl-dev
  Log.swift        the log; Failure, the one error type
tools/make-icon.swift   renders the icon
tools/drive.swift, drive.sh, live-test.sh, live-test.txt
                        the live test: a driver, its install, its runner, its plan
project.yml, build.sh   xcodegen + xcodebuild, sign, install (dev or release)
agent-notes/            what was learned, tracked
```

## Testing without a person

- **The pipeline.** `say -o clip.aiff "..."`, then ffmpeg to 16 kHz mono AAC.
  Put it in a session folder under owl-dev's sessions by hand with a
  `meta.json` (`id`, `state`, `soundSeconds`, `wallSeconds`, `audioStartMs`,
  `peakDb`) and an `events.jsonl` (marks included), then `owl-dev session <id>`
  (a session left `transcribing` with no one at it is transcribed right there),
  `owl-dev transcribe <id>` and `owl-dev bench <id> --model <id>`.
- **Recovery.** Set a session's state back to `transcribing`, then quit
  owl-dev with SIGTERM and open it: it finishes the session at launch.
- **Views.** Copy the sources (all but `main.swift` and `App.swift`) to a
  scratch folder, drop `private` where the test reaches in, and compile them
  with a `main.swift` of its own that renders `PillView` in an NSHostingView
  that is never put on screen (`cacheDisplay`), and marks onto any image with
  `Screenshot.draw`. Then look at the files.
- **Live, end to end, on a Mac no one is using.** `tools/drive.sh HOST` puts
  owl-dev and OwlDrive (`tools/drive.swift`, a driver that plays a plan of real
  mouse and key input and takes screen pictures) on HOST;
  `tools/live-test.sh HOST` plays `tools/live-test.txt` there (two sessions,
  every tool, every way of putting one down, wiping, stopping from the pill,
  a session started while one transcribes) and brings back the pictures and
  the timelines. HOST needs someone logged in, owl-dev's gesture on, and the
  two apps' grants, given once by a person (Screen Sharing is enough). Its
  sessions record that room: delete them after. Never point it at a Mac
  someone is using.
