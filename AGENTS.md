# AGENTS.md

owl: a Mac menu bar app that records a person's voice and what they do on the
computer as one timeline. Read `README.md` first, then
`agent-notes/handoff.md` (where the work stands), then `agent-notes.local/`
if it exists (facts about this machine, never tracked).

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
- **Delete, don't preserve.** When an approach is replaced, the old one goes
  in the same change. Git is the backup.
- The three permissions the app needs (Accessibility, Microphone, Screen
  Recording, plus Automation per app) can only be granted by the person, in
  System Settings. Say so; do not work around it.

## Layout

```
owl/            the app and the `owl` command, one binary (main.swift decides)
  App.swift       menu bar, session start/stop, the menu
  Gesture.swift   hold ⌥ / double-click; TextProbe
  Overlay.swift   the recording pill
  Mic.swift       AVAudioEngine → 16 kHz mono AAC; input devices
  Session.swift   a session folder, its clock, events.jsonl
  Watcher.swift   what he does → events (workspace, AX observer, monitors, poll)
  AX.swift        accessibility helpers, element descriptions
  Adapters.swift  the generic reading + Finder and browser adapters
  Screenshot.swift ScreenCaptureKit window pictures, dHash dedupe
  OpenRouter.swift the words (and optionally times) from a cloud model
  AppleTimes.swift word times from the on-device recognizer
  Align.swift     lay the text model's words onto the timed words
  Refine.swift    snap word starts to heard onsets; keep them monotonic
  Transcribe.swift the pipeline; bench
  Render.swift    session.md
  CLI.swift       the command
tools/make-icon.swift   renders the icon (output gitignored)
project.yml, build.sh   xcodegen + xcodebuild, install, sign
agent-notes/            what was learned, tracked
```

## Testing without a person

`say -o clip.aiff "..."` then ffmpeg to 16 kHz mono AAC, put it in a session
folder by hand with a `meta.json` (`soundSeconds`, `wallSeconds`,
`audioStartMs`) and a small `events.jsonl`, then `owl transcribe <id>` and
`owl bench <id> --model <id>`. That exercises everything but the microphone
and the watcher. The watcher can only be checked by a person running a
session and reading `session.md` back.
