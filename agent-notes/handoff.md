# Handoff

## Where it stands (first shot)

Built and installed; the pipeline is verified end to end on a synthetic clip;
the gesture, pill, microphone and watcher are written and compiled but have
not yet been run through a real session by a person (the app needs the four
grants first).

Verified on a 14 s synthetic clip: text model $0.0006, 48 words, 45 matched
to on-device times, every matched word snapped to an onset. `owl bench` with
`google/gemini-3-flash-preview` keeping time: median 717 ms off, p90 1062,
4% within a frame. The on-device recognizer keeps time; the cloud model
writes words. That is the design and the numbers say why.

## What is next

- A real session, read back. Does the watcher's `focus`/`click` detail read
  well in `session.md`? Is the poll too chatty in a busy browser? Are pictures
  landing when they should (window change, click, scroll)?
- Onset refinement moved 45/45 words on continuous synthetic speech; whether
  it is *right* to a frame needs a clip with known word times (a clip where a
  person taps a key as they say each word would do: the `key` events in the
  session are the ground truth).
- A transcript over ~7 minutes should be chunked before it goes to the text
  model; long clips make chat models loop. Not done.
- Sessions are one take on one microphone. A device change mid-session ends
  the sound (the engine stops on device loss) but not the session.
- Browser adapters read the tab by Apple events, one Automation prompt per
  browser. A page's selected element is only what the generic accessibility
  reading sees.
- The remark grouping in `session.md` (pause > 0.7 s, or sentence end + pause
  > 0.25 s) is a first guess.
