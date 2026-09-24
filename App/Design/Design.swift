import AppKit
import CarKit
import SwiftUI

// car's design system in code: the only place a size, a spacing, a font or a
// color is decided. docs/design-system/ says why each is what it is and when
// to use which. Views use these names, never a number of their own:
//
//   .textStyle(.body)            not .font(.system(size: 13))
//   Spacing.m                      not 12
//   Tint.recording               not .red
//
// car is a Mac app: system fonts, system colors (which follow light and dark
// mode and the accent color), standard controls. Color says state and
// nothing else.

/// Spacing, on a 4-point grid.
enum Spacing {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
}

/// Corner radii.
enum Radius {
    /// Placeholders, small chips.
    static let small: CGFloat = 4
    /// Pictures.
    static let medium: CGFloat = 6
    /// Panels laid over content: the picture viewer's caption.
    static let large: CGFloat = 10
}

/// The few colors that mean something. Everything else is the system's
/// label hierarchy (.primary, .secondary, .tertiary, .quaternary).
enum Tint {
    /// A session is recording.
    static let recording = Color.red
    /// Something did not work and will not fix itself.
    static let failed = Color.orange
    /// A mark's own ink.
    static func ink(_ ink: Ink) -> Color { Color(cgColor: ink.cgColor) }
}

/// Text, by what it is rather than how big it is. Each maps to a system
/// text style, so it follows the system's sizes.
enum TextStyle {
    /// A window's content title: the session's date.
    case title
    /// Facts under a title.
    case subtitle
    /// What was said: the script's own text.
    case speech
    /// A line of the actions column.
    case action
    /// Secondary detail after an action.
    case detail
    /// The time of a row: 12-hour, monospaced digits.
    case time
    /// A row's note: "Transcribing", a gap.
    case note
    /// A sidebar row's first line.
    case listTitle
    /// A sidebar row's second line.
    case listDetail
    /// The pill over other apps: rounded, so it reads as car's and not the app's.
    case hud

    var font: Font {
        switch self {
        case .title: .title2.weight(.semibold)
        case .subtitle: .callout
        case .speech: .body
        case .action, .detail: .callout
        case .time: .callout.monospacedDigit()
        case .note: .caption
        case .listTitle: .body.weight(.medium)
        case .listDetail: .callout
        case .hud: .system(.callout, design: .rounded).weight(.medium)
        }
    }

    /// The same font as AppKit has it, for measuring: the script's rows are
    /// sized from their text before SwiftUI draws them (ScriptLayout.swift).
    var nsFont: NSFont {
        switch self {
        case .title: NSFont.systemFont(ofSize: NSFont.preferredFont(forTextStyle: .title2).pointSize, weight: .semibold)
        case .subtitle, .action, .detail, .time, .listDetail: NSFont.preferredFont(forTextStyle: .callout)
        case .speech: NSFont.preferredFont(forTextStyle: .body)
        case .note: NSFont.preferredFont(forTextStyle: .caption1)
        case .listTitle: NSFont.systemFont(ofSize: NSFont.preferredFont(forTextStyle: .body).pointSize, weight: .medium)
        case .hud: NSFont.preferredFont(forTextStyle: .callout)
        }
    }

    /// The height of one line of it.
    var lineHeight: CGFloat {
        let f = nsFont
        return ceil(f.ascender - f.descender + f.leading)
    }

    var style: HierarchicalShapeStyle {
        switch self {
        case .title, .speech, .listTitle, .hud: .primary
        case .subtitle, .action, .listDetail, .note: .secondary
        case .detail, .time: .tertiary
        }
    }
}

extension View {
    func textStyle(_ s: TextStyle) -> some View {
        font(s.font).foregroundStyle(s.style)
    }
}

/// The sizes of the window and its parts.
enum Metrics {
    static let window = NSSize(width: 1180, height: 760)
    static let windowMin = NSSize(width: 860, height: 480)
    static let sidebar: (min: CGFloat, max: CGFloat) = (200, 320)
    /// Settings reads as a column, not across the whole window.
    static let settingsWidth: CGFloat = 620
    /// The script: its margins, its time gutter, the space between its
    /// columns, and above and below each row.
    static let scriptMargin: CGFloat = Spacing.xl
    static let scriptGutter: CGFloat = 84
    static let columnSpacing: CGFloat = Spacing.l
    static let rowPadding: CGFloat = Spacing.s + Spacing.xxs
    /// Actions a row shows before "N more".
    static let actionsShown = 6
    static let actionSymbol: CGFloat = 14
    /// A row's pictures: the first at the column's width in a box of this
    /// shape, the rest small beneath it.
    static let pictureAspect: CGFloat = 10.0 / 16.0
    static let smallPicture = CGSize(width: 56, height: 36)
    /// The grey lines holding the place of words to come.
    static let pendingLines: (long: CGFloat, short: CGFloat, height: CGFloat) = (260, 170, 8)
}

/// The words car writes about time, the one way everywhere: 12-hour, lower
/// case am and pm, like the lines it puts on the clipboard.
enum Format {
    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        f.amSymbol = "am"
        f.pmSymbol = "pm"
        return f
    }

    private static let clock = formatter("h:mm a")
    private static let clockSeconds = formatter("h:mm:ss a")
    private static let weekday = formatter("EEEE")
    private static let dayMonth = formatter("d MMMM")
    private static let dayMonthYear = formatter("d MMMM yyyy")
    private static let full = formatter("EEEE d MMMM")

    /// "2:15 pm"
    static func time(_ d: Date) -> String { clock.string(from: d) }
    /// "2:15:48 pm"
    static func timeSeconds(_ d: Date) -> String { clockSeconds.string(from: d) }

    /// A day as a list heads it: "Today", "Yesterday", "Tuesday", "22 September".
    static func day(_ d: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        if let days = cal.dateComponents([.day], from: cal.startOfDay(for: d), to: cal.startOfDay(for: now)).day,
           days < 7 { return weekday.string(from: d) }
        return cal.isDate(d, equalTo: now, toGranularity: .year) ? dayMonth.string(from: d) : dayMonthYear.string(from: d)
    }

    /// A session's name: "Today, 2:15 pm", "Thursday 24 September, 2:15 pm".
    static func session(_ d: Date) -> String {
        let cal = Calendar.current
        let day = cal.isDateInToday(d) ? "Today" : cal.isDateInYesterday(d) ? "Yesterday" : full.string(from: d)
        return "\(day), \(time(d))"
    }

    /// A length of time as a clock: "2:13", "1:02:13".
    static func length(ms: Int) -> String {
        let t = max(0, ms / 1000)
        return t < 3600 ? String(format: "%d:%02d", t / 60, t % 60)
                        : String(format: "%d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60)
    }

    /// A length of time in words: "12 minutes", "2 hours 5 minutes".
    static func span(ms: Int) -> String {
        let m = ms / 60000
        if m < 60 { return m == 1 ? "1 minute" : "\(m) minutes" }
        let h = m / 60, r = m % 60
        return (h == 1 ? "1 hour" : "\(h) hours") + (r == 0 ? "" : r == 1 ? " 1 minute" : " \(r) minutes")
    }

    /// "1 word", "104 words"
    static func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }
}
