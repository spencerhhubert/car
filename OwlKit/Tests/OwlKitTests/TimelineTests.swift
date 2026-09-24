import Foundation
import Testing
@testable import OwlKit

@Suite struct TimelineTests {
    private func words(_ spec: [(String, Int, Int)]) -> [Word] {
        spec.enumerated().map { i, s in
            Word(Row(values: ["chunk": 1, "i": i, "text": s.0, "start_ms": s.1, "end_ms": s.2, "how": "matched"]))
        }
    }

    @Test func aMarkSitsInTheSentenceWhereItWasDrawn() {
        let w = words([("this", 1000, 1200), ("part", 1250, 1500), ("here", 1550, 1800), ("is", 2600, 2700),
                       ("wrong.", 2750, 3000)])
        let r = Render.remarks(w, marks: [(t: 2000, name: "red circle 1")])
        #expect(r.count == 2)
        #expect(r[0].text == "this part here {red circle 1}")
        #expect(r[1].text == "is wrong.")
    }

    @Test func aMarkerEndsARemark() {
        let w = words([("first", 0, 300), ("thing", 350, 600), ("second", 700, 900)])
        #expect(Render.remarks(w, breaks: [650]).map(\.text) == ["first thing", "second"])
        #expect(Render.remarks(w).map(\.text) == ["first thing second"])
    }

    @Test func clockShowsHoursOnlyWhenThereAreSome() {
        #expect(Render.clock(83_417) == "01:23.417")
        #expect(Render.clock(3_723_004) == "1:02:03.004")
    }

    @Test func pointerLinesNameWhatToRead() {
        #expect(Pointer.session("20260924-122534") == "new \(Config.name) session 20260924-122534")
        var c = DateComponents()
        (c.year, c.month, c.day, c.hour, c.minute, c.second) = (2026, 9, 24, 12, 31, 5)
        let line = Pointer.marker(3, at: Calendar.current.date(from: c)!, in: "20260924-122534")
        #expect(line == "\(Config.name) marker 3 set at 12:31:05 pm in session 20260924-122534")
    }

    @Test func momentsParse() {
        _ = testRoot
        #expect(Moment.parse("start", in: "none", end: 90_000) == 0)
        #expect(Moment.parse("end", in: "none", end: 90_000) == 90_000)
        #expect(Moment.parse("-30s", in: "none", end: 90_000) == 60_000)
        #expect(Moment.parse("-20m", in: "none", end: 90_000) == 0)
        #expect(Moment.parse("12:30", in: "none", end: 0) == 750_000)
        #expect(Moment.parse("1:02:03", in: "none", end: 0) == 3_723_000)
        #expect(Moment.parse("soon", in: "none", end: 0) == nil)
    }
}
