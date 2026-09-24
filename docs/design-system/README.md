# car's design system

How car looks and how its interface code is written, so that all of it
reads as one app and none of it breaks in ways that are hard to find. The
code is `App/Design/`: `Design.swift` holds every size, spacing, font and
color, and `Components.swift` the pieces the window is made of. A view
uses those names and nothing of its own.

## Three rules

1. **It is a Mac app.** System fonts, system colors (which follow light and
   dark mode and the person's accent color), standard controls and standard
   containers: a sidebar that is a sidebar, a toolbar that is a toolbar,
   Settings as a grouped form. When AppKit or SwiftUI has a standard piece
   for something, that is the piece. Nothing is restyled to look different
   from what the Mac does.
2. **Quiet.** Almost everything is the label hierarchy in grey: primary,
   secondary, tertiary. Color says state and nothing else: red is recording,
   orange is something that failed and will not fix itself, and a drawing's
   own ink marks that drawing. The accent color is the system's, for
   selection and links. No decoration, no gradients, no cards around things
   that are not separate things.
3. **The session is the content.** The window exists to show what
   was said, what was done and what was on the screen. It is dense and
   aligned to one grid so that density reads as order. Chrome gets out of
   its way.

## The files

- [foundations.md](foundations.md): type, spacing, color, shape, symbols,
  motion, and how car writes (capitalization, times).
- [components.md](components.md): each shared piece and when to use it.
- [surfaces.md](surfaces.md): the menu, the pill, the window, the picture
  viewer, Settings: what each is for and how it is laid out.
- [engineering.md](engineering.md): how the interface code is built so it
  does not hang, crash or drift (SwiftUI decides no size anything depends
  on), and how a view is checked without a person.

## Changing it

A new size, color or text style goes in `Design.swift` with a line here in
foundations.md saying what it is for; a new kind of piece goes in
`Components.swift` and components.md. If a view needs a number that is not
in `Design.swift`, either it belongs there or the view is wrong.
