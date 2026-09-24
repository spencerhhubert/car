# car 🏎️

Continuous action recording: a Mac app for talking to an AI agent about
what is on your screen. Start a session in the morning (hold ⌘, tap ⌥
twice) and talk while you work, circling or pointing at things as you go. car
records it as one timeline: every word with the moment it was said, next to
the app, page, click and selection on screen at that moment, with pictures.
Whenever you want an agent to act on what you just said, tap ⌥ twice: the
clipboard gets one line naming that marker. Paste it into an agent and it
reads what you said up to it, reaching further back as the task needs. You
can read any session back yourself in car's window, as a script.

**Why:** feedback and ideas come fastest out loud, while pointing at the
thing. A typed message keeps a fraction of that. A session keeps all of it:
what you said, what "this" and "right there" meant, and what the screen showed
when you said it.

![A session in a CAD model: talking, a red circle drawn from the pill, then stop and transcribe](docs/media/demo.gif)

The captions are car's own transcript of that session, at the times car gave
each word.

## What the agent gets

`car session 20260924-124432`, the session above, trimmed (`…`) and with the
document's URL shortened:

```
[00:00.133–00:24.464] “All right, let's see what we have here. Um, this looks this looks more accurate, although we're still getting a clearance pro- we're getting a separate clearance problem right right there, {red circle 1} uh, which is probably worth investigating.”
[00:00.134] app → Brave Browser
[00:00.134] page https://cad.onshape.com/documents/… “400_Sorter V2 - Electronics | PSU wiring review”
[00:00.451] picture shots/00000451.jpg (app)
[00:00.722] click left Brave Browser image
[00:01.094] picture shots/00001094.jpg (click)
…
[00:12.011] scroll 14 in Brave Browser over image
[00:12.118] picture shots/00012118.jpg (scroll)
[00:18.512] drew red circle 1 around image in Brave Browser “400_Sorter V2 - Electronics | PSU wiring review”
[00:18.581] picture shots/00018581.jpg (red circle 1)
[00:20.680] click left Brave Browser image
[00:21.059] red circle 1 faded as the screen under it changed
…
[00:24.464–00:28.981] “The rest of it seems legit to me, though.”
[00:24.915] click left Brave Browser image
[00:25.290] picture shots/00025290.jpg (click)
[00:30.610] session end
```

`{red circle 1}` sits where it was drawn in the sentence, and every picture
taken while it was up has it drawn in with its number:

<img src="docs/media/red-circle-1.jpg" width="420" alt="shots/00018581.jpg, cropped: the red circle with its number 1">

## Try it

Needs macOS 26, Xcode and `xcodegen`. There is no download: clone this and
run `./build.sh release`, which builds, signs and installs it, then grant its
permissions in its Settings (the gear at the foot of its sidebar). It asks for an OpenRouter key the first time it
needs one. How to start a session, mark, draw and stop is in the
[guide](docs/guide.md). An agent learns to read sessions from
[`skill/SKILL.md`](skill/SKILL.md).

Everything else is in [docs](docs/README.md).
