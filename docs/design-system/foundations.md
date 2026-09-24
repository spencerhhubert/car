# Foundations

All of these are in `App/Design/Design.swift`.

## Type: `TextStyle`

Text is named by what it is, and each name maps to a system text style, so
it follows the system's sizes. `.textStyle(.speech)` sets the font and the
color together.

| Style | What it is | Font | Color |
|---|---|---|---|
| `title` | a window's content title: a session's date | title2, semibold | primary |
| `subtitle` | facts under a title | callout | secondary |
| `speech` | what was said: the script's own text | body | primary |
| `action` | a line of the actions column | callout | secondary |
| `detail` | what follows an action, a picker's aside | callout | tertiary |
| `time` | a row's time | callout, monospaced digits | tertiary |
| `note` | a row's note ("Transcribing"), a gap, a form's footer | caption | secondary |
| `listTitle` | a sidebar row's first line | body, medium | primary |
| `listDetail` | a sidebar row's second line | callout | secondary |
| `hud` | the pill, over other apps | callout, rounded, medium | primary |

Rounded type is the pill's alone: it floats over other apps and should read
as car's, not theirs. Weight marks at most one thing per line. Nothing is
set in a point size of its own.

## Spacing: `Spacing`

A 4-point grid: `xxs` 2, `xs` 4, `s` 8, `m` 12, `l` 16, `xl` 24, `xxl` 32.
Inside a group (a label and its value, an icon and its text) use `xs` or
`s`; between groups `m` or `l`; around a window's content `xl`. The script's
rows are `s` + `xxs` apart top and bottom; its columns `l` apart.

## Color: `Tint` and the label hierarchy

- Text and symbols are `.primary`, `.secondary`, `.tertiary`: the words
  someone said are primary, what was done secondary, the time and details
  tertiary.
- `Tint.recording` (red): a session is recording. Only ever a dot.
- `Tint.failed` (orange): something failed and will not fix itself.
- `Tint.ink(_)`: a drawing's own ink, on that drawing's name and symbol.
- Fills are the system's (`.fill.tertiary` behind a picture while it loads).
  Separators are `.separator`.
- The picture viewer is the one dark surface, in light mode too: a picture
  is shown on black, the way a photo is everywhere on a Mac.

## Shape: `Radius`

`small` 4 for placeholder lines and chips, `medium` 6 for pictures,
`large` 10 for panels laid over content. Pictures have a hairline border
(`.separator`) so a white window does not bleed into a white page.

## Symbols

SF Symbols only, at the size of the text beside them (`TextStyle.note.font`
next to a callout line), in that text's color or one step quieter. Each
kind of action has one symbol, set in `Script.Action.Kind.symbol`
(Components.swift): an app switch `macwindow.on.rectangle`, a window
`macwindow`, a page `globe`, Finder `folder`, a click `cursorarrow.click`,
a shortcut `command`, typing `keyboard`, a selection `text.cursor`, a
scroll `arrow.up.and.down`, a drawing `pencil.tip` (in its ink), a wipe
`eraser`, an app's own report `text.page`, a dictation `text.quote`, a pause
`pause.circle`, a resume `play.circle`, a microphone `mic`.

## Motion

None beyond what the system does. State changes are not animated; the one
transition is the picture viewer's fade. Nothing moves to draw attention.

## Writing: `Format`

- Title case for menu items, buttons, window titles and toolbar labels
  ("Start Session", "Copy for Agent"); sentence case for everything else,
  labels and notes included.
- Times are 12-hour with lower-case am and pm: "2:15 pm", "2:15:48 pm",
  the same as the lines car puts on the clipboard. Lengths are clocks
  ("2:13", "1:02:13"); gaps are words ("12 minutes later").
- Days as a list heads them: "Today", "Yesterday", a weekday within the
  week, then "22 September".
- Plain words, no jargon: "Words to come", not "pending chunk".
