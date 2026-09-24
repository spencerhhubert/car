# Engineering the interface

car runs all day in someone's menu bar, so its windows must never crash it,
hang it, or cost anything while closed. These are the rules the interface
code follows, and why.

## Who owns what

- **AppKit owns the app, the windows and the chrome.** `App.swift` is an
  `NSApplicationDelegate`; each window is an `NSWindowController`
  (`SessionsWindow`, `SettingsWindow`) with an `NSSplitViewController` for a
  sidebar and an `NSToolbar`; `Windows.swift` opens and closes them and
  keeps the Dock icon and the menu bar in step. Window lifetime, activation
  and the menus are plain AppKit, done one way, in one place.
- **SwiftUI draws what is inside a pane**, hosted with the `host(_:)`
  helper, which sets `sizingOptions = []`: the pane's size is AppKit's to
  decide. A hosting controller that also sizes its window from its content
  fights the split view over it; that fight is a classic source of layout
  loops and crashes.
- Every window sets `isReleasedWhenClosed = false` and is let go of by
  `Windows` after it closes. Closing a window ends everything it was doing:
  its models' loops run as SwiftUI `.task`s of its views, and are cancelled
  with them.

## State

- A window's state is an `@Observable`, `@MainActor` class it owns
  (`Library`, `ScriptModel`, `SettingsModel`). Views read it; only the model
  changes it, and only on the main actor.
- What a view shows is a value: `Script`, `SessionSummary` and their rows
  are `Sendable` structs built by CarKit. The catalog is read off the main
  thread (`ScriptReader` is an actor; `Library` reads in a detached task), and
  the result is assigned on the main actor in one step. A view never holds a
  database row, a dictionary of `Any`, or anything another thread changes.
- A live session is read again once a second while it is on screen, asking
  only for what changed, and the model is updated only when something did.
  The list of sessions is read every two seconds while the window is open,
  and at once when this app starts or stops one.
- Anything that repeats (a clock, a poll) lives as long as the view that
  needs it: `TimelineView` for a clock, `.task` for a loop.

## Identity and lists

- Every `ForEach` is over `Identifiable` values with ids that are stable
  across reads (a row's id comes from its start on the session clock).
  Never `ForEach` over indices: an array that shrinks under an index is a
  crash.
- The script is a `LazyVStack` in a `ScrollView`, so only the rows on screen
  exist. Rows are `Equatable` and marked `.equatable()`, so a new read
  redraws only the rows that changed. A list of more than a few thousand
  rows would move to an `NSTableView`.
- Anything that loads (a picture) has a fixed size before it loads, so the
  list does not jump. Pictures are decoded off the main thread, at the size
  they are shown, into a cache of bounded size, and a row lets go of its
  picture when it scrolls away.

## Code

- No force unwraps, `try!` or `fatalError` in the interface code (a
  required AppKit initializer that can never be called is the exception).
- No `GeometryReader` inside a row. The pane's width is read once, with
  `onGeometryChange`, and handed down.
- No sizes, fonts or colors outside `Design.swift`.
- Every view handles each state it can be in: nothing yet (a spinner),
  empty (`ContentUnavailableView`), live, finished, failed.

## Checking a view without a person

Views are checked by rendering them, never by driving the person's screen.
`tools/viewcheck` is a small program built from the app's own sources that
reads a copy of the catalog and renders the sessions window's panes, the
script laid out flat, the sidebar rows, the picture viewer and Settings to
PNGs, in light and dark:

```
tools/viewcheck/run.sh <session id> [light|dark]
```

It shows its windows fully transparent and deaf to the mouse for the few
seconds it takes, because SwiftUI draws nothing into a window that has
never been shown, and it reads a backup of the catalog so nothing it does
reaches the real one. Look at every picture it writes before calling a
change to a view done.
