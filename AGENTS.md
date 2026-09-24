# AGENTS.md

owl: a Mac menu bar app that records a person's voice and what they do on the
computer as one timeline, for hours at a time, and hands stretches of it to AI
agents at markers. Read `README.md` first, then `docs/guide.md` (how it
works), then `docs/handoff.md` (where the work stands), then
`agent-notes.local/` if it exists (facts about this machine, never tracked).

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
    ⌥, and windows, taps, streams and tickers exist only while in use. A
    session runs for hours, so what it costs per hour (CPU, disk, pictures,
    dollars sent to OpenRouter) is what matters.
  - A crash, a quit or a hung app never costs a session. The catalog holds a
    session's state, its chunks are closed as they go, and its lock says
    whether anyone is at it; an unfinished one is finished by whoever finds
    it.
  - Measure CPU and memory before calling a change done.
- **OwlKit is tested; keep it that way.** Everything that is not the Mac's
  screen, keys or microphone lives in OwlKit and has tests
  (`swift test --package-path OwlKit`, which `build.sh` runs first and which
  must pass). New logic goes where it can be tested, with its test.

## Working on it: the dev copy

The person uses the real owl while you work. **Never stop, restart or replace
`/Applications/owl.app` unless they say so.**

- `./build.sh` builds and installs the development copy,
  `/Applications/owl-dev.app`, with the `owl-dev` command. It has its own
  bundle id, sessions and settings (`Application Support/owl-dev`), log
  (`~/Library/Logs/owl-dev.log`) and permissions, and the menu bar shows it as
  🦉dev. Its keys (⌘⇧R, ⌥ ⌥) are off by default, since only one app can own
  ⌘⇧R; turn them on from its menu, or start and stop sessions from the menu.
  It reads the OpenRouter key from the real copy's folder when it has none.
  `build.sh` only ever quits and replaces owl-dev.
- `./build.sh release` builds and installs the real owl. It refuses while owl
  is recording or transcribing (`owl status`), otherwise quits it (SIGTERM is
  a proper quit: a session that has just started is closed, not cut off) and
  swaps in the new build. Run it only when the person asks.
- The dev copy needs its own grants (Accessibility, Microphone, Screen
  Recording, Automation) before it can record. Only the person can give them,
  from its menu → Permissions.

## Rules

- **`skill/SKILL.md` is how every agent learns to read a session**, and
  other places only point at it. Any change to what a session holds or how
  it reads (a new event, a new command, a changed line) updates it, and
  `docs/guide.md`, in the same change. Keep the skill short: what owl is, how
  deep to go, what each line means.

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
OwlKit/                 a Swift package: everything that is not the Mac's screen, keys or microphone
  Sources/OwlKit/
    Store/                where things are
      Catalog.swift         owl.sqlite: sessions, chunks, words, events, markers, files and their stores, usage
      Session.swift         a session: writing it (the app), reading it back (everyone); Clock; SessionLock
      Usage.swift           what transcription has cost
      Config.swift          settings, where things live, owl vs owl-dev
      Log.swift             the log; Failure, the one error type
    Transcribe/           sound into timed words
      Transcriber.swift     a session's chunks, one at a time, as they close; settles the session
      Transcribe.swift      one chunk: on-device times, the text model, alignment; bench
      OpenRouter.swift, AppleTimes.swift, Align.swift, Refine.swift
    Timeline/             reading a session out
      Render.swift          the timeline, whole or a stretch; markers; drawings set into the words
      Moment.swift          start, end, m3, -20m, 12:30
      Pointer.swift         the lines owl puts on the clipboard
    Marks/                drawings
      Marks.swift           tools, inks, a mark's geometry, drawing it into a picture
      Fading.swift          when a mark fades: its time, or what is under it changing
  Tests/OwlKitTests/
App/                    the menu bar app and the `owl` command, one binary (main.swift decides)
  App.swift               sessions: ⌘⇧R, markers, finishing, the pill; Menu.swift the menu
  CLI.swift               the command
  Capture/                the Mac's side
    Recording.swift         the session being recorded: microphone, watcher, drawing, transcriber
    Mic.swift               the microphone as chunks cut at pauses; reopens after sleep or a device change
    Keys.swift              ⌘⇧R (a system hot key) and ⌥ ⌥
    Watcher.swift           what the person does → events
    Adapters.swift          the reader queue; the generic reading + Finder, browser and desk adapters
    AX.swift                accessibility helpers, hit tests, element descriptions; Space
    Screenshot.swift        window and display pictures, marks drawn in, dHash dedupe
  Drawing/                drawing on the screen
    Drawing.swift           the layer: tool in hand, ink, canvas windows, Escape tap, fading
    ScreenChange.swift      small, slow captures of the screen under the marks
    Pill.swift              the pill: a dot while recording, the toolbar on hover
skill/SKILL.md          how an agent reads a session and acts on it
docs/                   guide.md (how owl works; `owl guide` prints it), handoff.md, media/ (Git LFS)
tools/                  make-icon; the live test (drive.swift, drive.sh, live-test.sh, live-test.txt)
project.yml, build.sh   xcodegen + xcodebuild (OwlKit as a local package), tests, sign, install (dev or release)
```

## Testing without a person

- **OwlKit:** `swift test --package-path OwlKit`. Tests that touch the
  catalog call `testRoot` first, which points `OWL_ROOT` at a folder of their
  own; no test writes into a real copy.
- **The pipeline, end to end, with no microphone:** a scratch SwiftPM program
  depending on `OwlKit` plays the app. It creates a `Session`, copies
  `say -o` clips in as chunks with `chunkOpened`/`chunkClosed`, sets a marker,
  hands chunks to a `Transcriber` and holds or drops the lock. Then
  `owl-dev marker`, `owl-dev session` and friends run against it (the same
  `OWL_ROOT` for both keeps it out of owl-dev's catalog). This is how a marker
  waiting on its words, and a session picked up after a crash, are checked.
- **Recovery in the app:** quit owl-dev with SIGTERM mid-session and open it:
  it finishes the session at launch.
- **Views:** copy the app's sources to a scratch folder, drop `private` where
  the test reaches in, and compile them with a `main.swift` of its own that
  renders `PillView` in an NSHostingView that is never put on screen
  (`cacheDisplay`). Then look at the files.
- **Live, end to end, on a Mac no one is using:** `tools/drive.sh HOST` puts
  owl-dev and OwlDrive (`tools/drive.swift`, a driver that plays a plan of real
  mouse and key input and takes screen pictures) on HOST;
  `tools/live-test.sh HOST` plays `tools/live-test.txt` there and brings back
  the pictures and the timelines. HOST needs someone logged in, owl-dev's keys
  on, and the two apps' grants, given once by a person (Screen Sharing is
  enough). Its sessions record that room: delete them after. Never point it
  at a Mac someone is using.
