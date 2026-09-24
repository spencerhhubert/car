import CoreGraphics
import CoreText
import Foundation

// Drawing on the screen during a session: a pen, an arrow, a circle and a
// rectangle, in one of a few named inks. A finished drawing is a mark,
// numbered in the order drawn ("red circle 1"). It goes into the session as an
// event saying what it was drawn on, into the words at the moment it was drawn
// ("this part here {red circle 1}"), and into every picture it is on, with its
// number. The mark in the timeline, on the screen and in the picture is one
// thing, so "this part here" has an answer.
//
// Points are in the display space (Space, in AX.swift). Drawing.swift is the
// layer on the screen that takes the mouse and shows the marks.

enum Tool: String, CaseIterable, Sendable {
    case pen, arrow, circle, rectangle

    /// What a mark made with it is called: "the red circle".
    var noun: String {
        switch self {
        case .pen: "stroke"
        case .arrow: "arrow"
        case .circle: "circle"
        case .rectangle: "rectangle"
        }
    }

    var symbol: String {
        switch self {
        case .pen: "pencil.tip"
        case .arrow: "arrow.up.right"
        case .circle: "circle"
        case .rectangle: "rectangle"
        }
    }

    /// A shape is drawn once and the pointer goes back to the apps; the pen
    /// stays in hand for the next stroke. Excalidraw's rule.
    var staysInHand: Bool { self == .pen }
}

enum Ink: String, CaseIterable, Sendable {
    case red, yellow, green, blue, purple

    var cgColor: CGColor {
        switch self {
        case .red: CGColor(srgbRed: 1.00, green: 0.23, blue: 0.19, alpha: 1)
        case .yellow: CGColor(srgbRed: 1.00, green: 0.80, blue: 0.00, alpha: 1)
        case .green: CGColor(srgbRed: 0.20, green: 0.78, blue: 0.35, alpha: 1)
        case .blue: CGColor(srgbRed: 0.04, green: 0.52, blue: 1.00, alpha: 1)
        case .purple: CGColor(srgbRed: 0.69, green: 0.32, blue: 0.87, alpha: 1)
        }
    }

    /// The number on a badge of this ink.
    var onInk: CGColor { self == .yellow ? CGColor(gray: 0, alpha: 1) : CGColor(gray: 1, alpha: 1) }
}

struct Mark: Sendable {
    /// Line width in points, on the screen and (scaled) in pictures.
    static let width: CGFloat = 4
    /// The dark edge under every line, so any ink shows on any background.
    static let edge = CGColor(gray: 0, alpha: 0.45)

    let n: Int
    let tool: Tool
    let ink: Ink
    /// The pen's stroke, point by point; for the others, where the drag began
    /// and where it has got to.
    private(set) var points: [CGPoint]
    /// Session ms at the press and at the release.
    let start: Int
    var end: Int

    init(n: Int, tool: Tool, ink: Ink, at p: CGPoint, time: Int) {
        self.n = n
        self.tool = tool
        self.ink = ink
        points = tool == .pen ? [p] : [p, p]
        start = time
        end = time
    }

    var name: String { "\(ink.rawValue) \(tool.noun) \(n)" }

    var bounds: CGRect {
        let xs = points.map(\.x), ys = points.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    /// What the mark is about: where an arrow points, the middle of anything else.
    var anchor: CGPoint {
        tool == .arrow ? points[1] : CGPoint(x: bounds.midX, y: bounds.midY)
    }

    /// Where its number goes in a picture: the arrow's tail, a shape's
    /// top-left corner, the start of a stroke.
    var badge: CGPoint {
        switch tool {
        case .circle, .rectangle: CGPoint(x: bounds.minX, y: bounds.minY)
        case .pen, .arrow: points[0]
        }
    }

    /// Was this a drag at all, or a click?
    var isDrawn: Bool { max(bounds.width, bounds.height) >= 5 }

    /// The drag has reached `p`. Constrained (shift held): a circle rather
    /// than an ellipse, a square, an arrow at a multiple of 45°.
    mutating func extend(to p: CGPoint, constrained: Bool) {
        let a = points[0]
        switch tool {
        case .pen:
            if let last = points.last, hypot(p.x - last.x, p.y - last.y) < 1.5 { return }
            points.append(p)
        case .arrow:
            var q = p
            if constrained {
                let step = CGFloat.pi / 4
                let angle = (atan2(p.y - a.y, p.x - a.x) / step).rounded() * step
                let d = hypot(p.x - a.x, p.y - a.y)
                q = CGPoint(x: a.x + d * cos(angle), y: a.y + d * sin(angle))
            }
            points[1] = q
        case .circle, .rectangle:
            var q = p
            if constrained {
                let s = max(abs(p.x - a.x), abs(p.y - a.y))
                q = CGPoint(x: a.x + (p.x >= a.x ? s : -s), y: a.y + (p.y >= a.y ? s : -s))
            }
            points[1] = q
        }
    }

    /// The mark as a path, every point passed through `map` into a view's or
    /// a picture's coordinates.
    func path(_ map: (CGPoint) -> CGPoint) -> CGPath {
        let path = CGMutablePath()
        switch tool {
        case .pen:
            let pts = points.map(map)
            path.move(to: pts[0])
            guard pts.count > 2 else {
                path.addLine(to: pts.last!)
                return path
            }
            // A curve through the midpoints, so the stroke is smooth rather
            // than the polyline the mouse reported.
            for i in 1..<(pts.count - 1) {
                let mid = CGPoint(x: (pts[i].x + pts[i + 1].x) / 2, y: (pts[i].y + pts[i + 1].y) / 2)
                path.addQuadCurve(to: mid, control: pts[i])
            }
            path.addLine(to: pts.last!)
        case .arrow:
            let (a, b) = (points[0], points[1])
            let len = max(hypot(b.x - a.x, b.y - a.y), 0.001)
            let head = min(20, max(10, len * 0.3))
            let (vx, vy) = ((a.x - b.x) / len, (a.y - b.y) / len)
            func wing(_ turn: CGFloat) -> CGPoint {
                CGPoint(x: b.x + head * (vx * cos(turn) - vy * sin(turn)),
                        y: b.y + head * (vx * sin(turn) + vy * cos(turn)))
            }
            path.move(to: map(a))
            path.addLine(to: map(b))
            path.move(to: map(wing(0.5)))
            path.addLine(to: map(b))
            path.addLine(to: map(wing(-0.5)))
        case .circle:
            path.addEllipse(in: Mark.rect(map(points[0]), map(points[1])))
        case .rectangle:
            let r = Mark.rect(map(points[0]), map(points[1]))
            let corner = min(6, r.width / 2, r.height / 2)
            path.addRoundedRect(in: r, cornerWidth: corner, cornerHeight: corner)
        }
        return path
    }

    private static func rect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// Draw the mark into a picture: the stroke as it was on the screen, and
    /// its number. `scale` is pixels per point; the context is y-up.
    func draw(in ctx: CGContext, scale: CGFloat, map: (CGPoint) -> CGPoint) {
        let path = self.path(map)
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.addPath(path)
        ctx.setStrokeColor(Mark.edge)
        ctx.setLineWidth((Mark.width + 2.5) * scale)
        ctx.strokePath()
        ctx.addPath(path)
        ctx.setStrokeColor(ink.cgColor)
        ctx.setLineWidth(Mark.width * scale)
        ctx.strokePath()

        let c = map(badge)
        let r = 11 * scale
        let disc = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
        ctx.setFillColor(ink.cgColor)
        ctx.fillEllipse(in: disc)
        ctx.setStrokeColor(Mark.edge)
        ctx.setLineWidth(1.5 * scale)
        ctx.strokeEllipse(in: disc)
        let font = CTFontCreateUIFontForLanguage(.emphasizedSystem, 13 * scale, nil)
            ?? CTFontCreateWithName("Helvetica-Bold" as CFString, 13 * scale, nil)
        let text = NSAttributedString(string: "\(n)", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): ink.onInk,
        ])
        let line = CTLineCreateWithAttributedString(text)
        let glyphs = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        ctx.textPosition = CGPoint(x: c.x - glyphs.midX, y: c.y - glyphs.midY)
        CTLineDraw(line, ctx)
    }

    /// The mark as events.jsonl has it. Coordinates are whole points in the
    /// display space; a stroke is thinned to at most 64 points.
    var fields: [String: Any] {
        func xy(_ p: CGPoint) -> [Int] { [Int(p.x.rounded()), Int(p.y.rounded())] }
        let b = bounds
        var f: [String: Any] = [
            "n": n, "name": name, "tool": tool.rawValue, "color": ink.rawValue, "start": start,
            "rect": [b.minX, b.minY, b.width, b.height].map { Int($0.rounded()) },
            "at": xy(anchor),
        ]
        switch tool {
        case .pen:
            let step = max(1, (points.count + 63) / 64)
            var kept = stride(from: 0, to: points.count, by: step).map { points[$0] }
            if kept.last != points.last { kept.append(points.last!) }
            f["points"] = kept.map(xy)
        case .arrow:
            f["from"] = xy(points[0])
            f["to"] = xy(points[1])
        case .circle, .rectangle:
            break
        }
        return f
    }
}
