# Components

The shared pieces, in `App/Design/Components.swift`. A view that needs one
of these things uses this one.

- **`RecordingDot`**: a small red dot. The only sign that something is
  recording: in the sidebar row, the title's status, the footer, a row whose
  words are still being recorded.
- **`StatusBadge`**: what a session is doing, beside its title: recording
  (dot), transcribing (spinner), not all transcribed (orange triangle, the
  reason on hover). Nothing when it is done.
- **`Pending`**: where words are still to come. Two grey lines hold the
  place the words will take; the first row of a stretch says what it is
  waiting for ("Words to come" with the dot, or "Transcribing" with a
  spinner). The words replace it in place when they arrive.
- **`Thumbnail`**: a picture, small, filling a box of a fixed size, so a
  list of them never jumps while they load. It is made from the file off the
  main thread and kept in a cache of bounded size (`Pictures`), and let go of
  when it scrolls away. The whole picture is a click away.
- **`Said.styled`**: what was said, with each drawing made while it was
  said ("{red circle 1}") set in the drawing's ink.
- **`Script.Action.Kind.symbol`**: the one symbol for each kind of action.

Standard pieces, used as they come:

- `ContentUnavailableView` for an empty place ("No Sessions") with one line
  saying how to fill it.
- `ProgressView().controlSize(.mini)` for something working.
- `Form` with `.formStyle(.grouped)`, `LabeledContent`, `Picker`, `Toggle`,
  `Stepper` for Settings.
- `Button` with `.buttonStyle(.plain)` around a picture, `.link` for a
  quiet action in running text, `.borderless` for an icon in a row.
