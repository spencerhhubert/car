import CoreGraphics
import Testing
@testable import CarKit

@Suite struct MarksTests {
    @Test func shiftMakesASquareAndA45DegreeArrow() {
        var box = Mark(n: 1, tool: .rectangle, ink: .red, at: CGPoint(x: 100, y: 100), time: 0)
        box.extend(to: CGPoint(x: 160, y: 130), constrained: true)
        #expect(box.bounds.width == box.bounds.height)
        var arrow = Mark(n: 2, tool: .arrow, ink: .blue, at: .zero, time: 0)
        arrow.extend(to: CGPoint(x: 100, y: 90), constrained: true)
        #expect(abs(arrow.points[1].x - arrow.points[1].y) < 0.001)
        #expect(arrow.anchor == arrow.points[1])
    }

    @Test func aClickIsNotADrawing() {
        var m = Mark(n: 1, tool: .circle, ink: .green, at: CGPoint(x: 10, y: 10), time: 0)
        m.extend(to: CGPoint(x: 12, y: 11), constrained: false)
        #expect(!m.isDrawn)
        #expect(m.name == "green circle 1")
    }

    @Test func aLongStrokeIsThinnedForTheRecord() {
        var pen = Mark(n: 3, tool: .pen, ink: .yellow, at: .zero, time: 0)
        for i in 1...500 { pen.extend(to: CGPoint(x: Double(i) * 2, y: 0), constrained: false) }
        let kept = pen.fields["points"] as! [[Int]]
        #expect(kept.count <= 65)
        #expect(kept.last == [1000, 0])
    }

    @Test func fadingIgnoresNoiseAndSeesAChange() {
        let a: [UInt8] = (0..<400).map { UInt8(($0 * 37) % 200 + 20) }
        let noise = a.map { UInt8(Int($0) + (Int($0) % 3) - 1) }
        let other = a.reversed().map { $0 }
        #expect(!Fading.changed(a, noise))
        #expect(Fading.changed(a, other))
        let blank = [UInt8](repeating: 250, count: 400)
        #expect(!Fading.changed(blank, blank.map { $0 - 3 }))
        #expect(Fading.changed(blank, a))
    }
}
