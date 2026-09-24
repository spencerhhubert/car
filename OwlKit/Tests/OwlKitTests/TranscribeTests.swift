import Testing
@testable import OwlKit

@Suite struct AlignTests {
    private func w(_ t: String, _ s: Double, _ e: Double) -> LocalModel.Word { LocalModel.Word(text: t, start: s, end: e) }

    @Test func matchesWordsAndPlacesTheRestBetween() {
        let timed = [w("okay", 0, 0.3), w("so", 0.4, 0.5), w("this", 0.6, 0.8), w("part", 0.9, 1.1)]
        let out = Align.merge(text: ["Okay,", "so", "uh", "this", "part"], timed: timed, duration: 2)
        #expect(out.map(\.how) == ["matched", "matched", "interpolated", "matched", "matched"])
        #expect(out[0].start == 0 && out[3].start == 0.6)
        #expect(out[2].start >= out[1].end && out[2].end <= out[3].start)
    }

    @Test func nothingInCommonSpreadsOverTheTake() {
        let out = Align.merge(text: ["alpha", "beta"], timed: [w("gamma", 0, 1)], duration: 4)
        #expect(out.allSatisfy { $0.how == "interpolated" })
        #expect(out.last!.end <= 4.0001)
    }

    @Test func monotonicTrimsOverlaps() {
        var words = [Align.Timed(text: "a", start: 0, end: 1, how: "matched"),
                     Align.Timed(text: "b", start: 0.5, end: 0.8, how: "matched"),
                     Align.Timed(text: "c", start: 0.4, end: 0.3, how: "matched")]
        Refine.monotonic(&words)
        #expect(words[0].end == 0.5)
        #expect(words[2].start >= words[1].start && words[2].end >= words[2].start)
    }
}
