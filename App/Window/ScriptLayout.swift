import AppKit
import CarKit

// The script's geometry, decided in one place: the widths of its columns
// from the width of the pane, and the height of every row from what is in
// it. The table (ScriptController.swift) asks for a row's height before the
// row is drawn and SwiftUI draws the row inside it (ScriptView.swift), so
// SwiftUI never decides a height and scrolling never waits on a layout pass.
// Text is measured with the fonts SwiftUI draws it in (TextStyle.nsFont),
// a little narrower than it is drawn, so a row is never shorter than its
// text; tools/viewcheck checks every row of a session against SwiftUI's own
// size for it.
struct ScriptLayout: Equatable {
    /// The table's width, and the four columns inside it.
    let width: CGFloat
    let gutter = Metrics.scriptGutter
    let speech: CGFloat
    let actions: CGFloat
    let pictures: CGFloat

    init(width: CGFloat) {
        self.width = width
        let content = max(0, width - 2 * Metrics.scriptMargin)
        actions = min(300, max(180, content * 0.26))
        pictures = min(200, max(140, content * 0.19))
        speech = max(120, content - Metrics.scriptGutter - actions - pictures - 3 * Metrics.columnSpacing)
    }

    /// The first picture of a row fills this box.
    var firstPicture: CGSize { CGSize(width: pictures, height: (pictures * Metrics.pictureAspect).rounded()) }

    /// How many of a row's other pictures fit small beneath the first, and
    /// how many are left over for "+N".
    func smallPictures(_ others: Int) -> (shown: Int, more: Int) {
        let room = max(1, Int((pictures + Spacing.xs) / (Metrics.smallPicture.width + Spacing.xs)))
        return others > room ? (room - 1, others - room + 1) : (others, 0)
    }

    // MARK: - heights

    var headerHeight: CGFloat {
        Spacing.l + TextStyle.title.lineHeight + Spacing.xs + TextStyle.subtitle.lineHeight + Spacing.xl
    }

    func footerHeight(_ note: String) -> CGFloat {
        let text = width - 2 * Metrics.scriptMargin - gutter - Metrics.columnSpacing - Spacing.l - Spacing.s
        return 2 * Spacing.xl + max(16, Self.text(note, .note, width: text))
    }

    /// A row's height, `expanded` when all its actions are shown.
    func height(_ row: Script.Row, expanded: Bool) -> CGFloat {
        var h: CGFloat = 0
        if row.gapBefore != nil { h += TextStyle.note.lineHeight + 2 * Spacing.m }
        if row.marker != nil { return h + max(TextStyle.action.lineHeight, 22) + 2 * Spacing.m }

        let said: CGFloat
        switch row.speech {
        case .said(let text):
            said = Self.text(Said.plain(text), .speech, width: speech, lineSpacing: Spacing.xxs)
        case .quiet:
            said = 0
        case .recording(let first), .transcribing(let first):
            said = (first ? TextStyle.note.lineHeight + Spacing.s : 0) + 2 * Metrics.pendingLines.height + Spacing.s
        case .failed(let why, let first):
            said = first ? TextStyle.action.lineHeight + Spacing.xxs + Self.text(why, .note, width: speech) : 0
        case .lost(let first):
            said = first ? Self.text(Self.lost, .note, width: speech) : 0
        }

        let shown = expanded ? row.actions.count : min(row.actions.count, Metrics.actionsShown)
        var did = CGFloat(shown) * TextStyle.action.lineHeight + CGFloat(max(0, shown - 1)) * Spacing.xs
        if shown < row.actions.count { did += Spacing.xs + TextStyle.detail.lineHeight }

        var saw: CGFloat = 0
        if !row.pictures.isEmpty {
            saw = firstPicture.height
            if row.pictures.count > 1 { saw += Spacing.xs + Metrics.smallPicture.height }
        }

        let drop = Self.calloutDrop
        return h + max(said, shown > 0 ? did + drop : 0, saw, TextStyle.time.lineHeight + drop) + 2 * Metrics.rowPadding
    }

    static let lost = "Not saved: car stopped before this stretch was written."

    /// A callout line set beside a body line drops this far, so their
    /// baselines meet.
    static let calloutDrop = max(0, (TextStyle.speech.nsFont.ascender - TextStyle.action.nsFont.ascender).rounded())

    /// The height of `s` set in `style`, wrapped at `width`. Measured a
    /// little narrower than it is drawn: a line too many is a little air, a
    /// line too few would cut the text off.
    static func text(_ s: String, _ style: TextStyle, width: CGFloat, lineSpacing: CGFloat = 0) -> CGFloat {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = lineSpacing
        let r = NSAttributedString(string: s, attributes: [.font: style.nsFont, .paragraphStyle: p])
            .boundingRect(with: NSSize(width: max(1, width - 8), height: .greatestFiniteMagnitude),
                          options: [.usesLineFragmentOrigin, .usesFontLeading])
        return ceil(r.height) + 1
    }
}
