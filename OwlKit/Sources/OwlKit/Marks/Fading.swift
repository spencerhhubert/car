import CoreGraphics
import Foundation

// When a mark's time is up, or what it was drawn on has changed a lot (another
// tab, a scroll, a model turned), it fades. This is the arithmetic for the
// second: the app's ScreenChange feeds it small frames of the screen with
// owl's own windows left out, and asks.
//
// A mark's region (its bounds with a margin) is read as a grid of brightness
// when it is drawn and again on every frame. What the mark was about is gone
// when the region has moved, on average, by half its own spread: measured
// against the region's own contrast, so a sparse list clearing counts as much
// as a busy toolbar scrolling. Checked against pictures of real pages: a
// 30 pt scroll of a list or a toolbar, a 120 pt scroll of anything, a page
// going blank all count; noise, the pointer and a 6 pt nudge do not.
public enum Fading {
    /// A mark holds this long, then fades over `slowly`…
    public static let hold: TimeInterval = 6
    public static let slowly: TimeInterval = 3
    /// …or fades over this once what it was drawn on has changed.
    public static let quickly: TimeInterval = 0.5

    /// A frame of the screen, one brightness byte a pixel.
    public struct Gray: Sendable {
        public let width: Int
        public let height: Int
        public let px: [UInt8]
        public init(width: Int, height: Int, px: [UInt8]) {
            self.width = width
            self.height = height
            self.px = px
        }
    }

    /// The region a mark is watched over: its bounds and a margin.
    public static func region(of m: Mark) -> CGRect {
        let pad = max(24, 0.25 * max(m.bounds.width, m.bounds.height))
        return m.bounds.insetBy(dx: -pad, dy: -pad)
    }

    /// The grid is at most this many cells a side.
    static let cells = 48
    /// The region has changed when its mean move (brightness, of 255) is at
    /// least this share of its spread at the start…
    static let relativeMove = 0.5
    /// …and at least this much, whatever the spread: a blank region is not
    /// changed by noise.
    static let minimumMove = 6.0

    /// The mean brightness of each cell of `rect` (display space) in a frame
    /// of the display at `frame`.
    public static func grid(_ g: Gray, of frame: CGRect, _ rect: CGRect) -> [UInt8] {
        let sx = CGFloat(g.width) / frame.width, sy = CGFloat(g.height) / frame.height
        let x0 = max(0, min(g.width - 1, Int((rect.minX - frame.minX) * sx)))
        let y0 = max(0, min(g.height - 1, Int((rect.minY - frame.minY) * sy)))
        let x1 = max(x0 + 1, min(g.width, Int((rect.maxX - frame.minX) * sx)))
        let y1 = max(y0 + 1, min(g.height, Int((rect.maxY - frame.minY) * sy)))
        let cols = min(cells, x1 - x0), rows = min(cells, y1 - y0)
        var out = [UInt8](repeating: 0, count: cols * rows)
        for r in 0..<rows {
            let ya = y0 + (y1 - y0) * r / rows, yb = y0 + (y1 - y0) * (r + 1) / rows
            for c in 0..<cols {
                let xa = x0 + (x1 - x0) * c / cols, xb = x0 + (x1 - x0) * (c + 1) / cols
                var sum = 0
                for y in ya..<yb { for x in xa..<xb { sum += Int(g.px[y * g.width + x]) } }
                out[r * cols + c] = UInt8(sum / max(1, (yb - ya) * (xb - xa)))
            }
        }
        return out
    }

    public static func changed(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count, !a.isEmpty else { return false }
        let n = Double(a.count)
        let moved = zip(a, b).reduce(0.0) { $0 + Double(abs(Int($1.0) - Int($1.1))) } / n
        let mean = a.reduce(0.0) { $0 + Double($1) } / n
        let spread = a.reduce(0.0) { $0 + abs(Double($1) - mean) } / n
        return moved >= minimumMove && moved >= relativeMove * spread
    }
}
