# Engineering the interface

car runs all day on someone's Mac, recording, so its window must never hang
it, crash it, or cost anything while closed. These are the rules the
interface code follows, and why.

## The bug this is built against

SwiftUI hangs or crashes when a view's size or position feeds back into its
own layout: a row is measured, the view moves to keep something in place,
which measures more rows, and it never settles. The first sessions window
did this: a `LazyVStack` of rows of very different heights in a
`ScrollView` holding a scroll position hung at full CPU after a minute of
scrolling with a mouse wheel. The same family covers windows sized from
their content (layout loops between a hosting controller and a split view),
state set from geometry (`GeometryReader` or `onGeometryChange` writing
`@State` that changes the geometry), and scroll positions or anchors bound
to state.

So the rule is: **SwiftUI decides no size that anything else depends on.**
AppKit owns every size that moves: the window, the split, scrolling, and the
height of every row. SwiftUI draws inside sizes it is given.

## Who owns what

- **AppKit owns the app, the window and the chrome.** `App.swift` is an
  `NSApplicationDelegate`; the window is an `NSWindowController`
  (`MainWindow`) with an `NSSplitViewController` for the sidebar and an
  `NSToolbar`; the main pane (`DetailController`) swaps AppKit child
  controllers: the script, Settings, or an empty state.
- **AppKit scrolls the script.** It is an `NSTableView`
  (`ScriptController`) whose row heights come from `ScriptLayout`, which
  measures the text with the fonts SwiftUI draws it in (`TextStyle.nsFont`)
  and adds up the actions and pictures at their fixed sizes. Each row's
  SwiftUI view sits in a reused cell and lays out top-down at fixed column
  widths: no alignment guides, no state that changes a size, nothing that
  asks for room. A row that needs all its actions ("4 more") asks the table
  for its new height; it does not grow on its own.
- **SwiftUI draws the pieces** (a row, the sidebar list, Settings, the
  picture viewer), hosted with `host(_:)` or `NSHostingView`, always with
  `sizingOptions = []`: the size is AppKit's to decide.
- The window sets `isReleasedWhenClosed = false` and is let go of after it
  closes; closing it stops everything it was reading (the script's reader,
  the list's refresh, the title), while the app, and any recording, carries
  on.

## State

- The window's state is `@Observable`, `@MainActor` classes it owns
  (`Library`, `ScriptModel`, `SettingsModel`). Views read them; only the
  models change them, only on the main actor. AppKit controllers follow them
  with `Observations`, in a task they cancel when they stop.
- What a view shows is a value: `Script`, `SessionSummary` and their rows are
  `Sendable` structs built by CarKit. The catalog is read off the main thread
  (`ScriptReader` is an actor; `Library` reads in a detached task), and the
  result is assigned on the main actor in one step. A view never holds a
  database row, a dictionary of `Any`, or anything another thread changes.
- A live session is read again once a second while it is on screen, asking
  only for what changed; the table reloads only when something did, and
  keeps the heights of rows that did not change.
- Anything that repeats (a clock, a poll) lives as long as what needs it:
  `TimelineView` for a clock, a task the controller cancels for a loop.

## Identity and lists

- Every `ForEach` is over `Identifiable` values with ids that are stable
  across reads (a row's id comes from its start on the session clock). Never
  `ForEach` over indices: an array that shrinks under an index is a crash.
- Anything that loads (a picture) has a fixed size before it loads, so
  nothing moves. Pictures are decoded off the main thread, at the size they
  are shown, into a cache of bounded size, and a row lets go of its picture
  when it scrolls away.

## Code

- No force unwraps, `try!` or `fatalError` in the interface code (a required
  AppKit initializer that can never be called is the exception).
- No `GeometryReader`, `onGeometryChange` or scroll-position binding that
  writes state a layout depends on.
- No sizes, fonts or colors outside `Design.swift`.
- Every view handles each state it can be in: nothing yet, empty, live,
  finished, failed.

## When it hangs anyway

`Watchdog.swift` asks the main thread to answer every second. If it has not
answered in three, a sample of every thread goes to
`~/Library/Logs/car-hang-<time>.txt` (or `car-dev-hang-…`), with a line in the
log. Read that before guessing.

## Checking a view without a person

Views are checked by running them, never by driving the person's screen:

```
tools/viewcheck/run.sh <session id> [light|dark]
```

builds a small program from the app's own sources, reads a backup of a
catalog (car-dev's, or `CATALOG=`), and:

- **stress**: scrolls the real window with mouse-wheel events and jumps and
  resizes it, handing the events to the window's own views, and fails on any
  step the main thread took more than a quarter second to come back from;
- **fit**: checks every row's height from `ScriptLayout` against the height
  SwiftUI needs for it at three widths, and fails on any row that would be
  cut off;
- **pictures**: renders the script's rows at their given heights, the
  sidebar's rows, the picture viewer and Settings.

It shows its windows fully transparent and deaf to the mouse for the seconds
it takes, since SwiftUI draws nothing into a window that was never shown.
Run it, and look at every picture, before calling a change to a view done.
