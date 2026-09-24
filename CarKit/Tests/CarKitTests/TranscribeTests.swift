import Testing
@testable import CarKit

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

    /// An envelope (5 ms frames) of speech over the given stretches and
    /// quiet elsewhere.
    private func envelope(_ seconds: Double, speech: [(Double, Double)]) -> [Float] {
        (0..<Int(seconds / 0.005)).map { k in
            let t = Double(k) * 0.005
            return speech.contains { t >= $0.0 && t < $0.1 } ? -30 + Float(k % 3) : -70 + Float(k % 2)
        }
    }

    private func t(_ text: String, _ s: Double, _ e: Double) -> Align.Timed {
        Align.Timed(text: text, start: s, end: e, how: "matched")
    }

    @Test func theFirstWordAfterAPauseStartsWhereTheSoundDoes() {
        // Speech 0–1 s, two seconds of quiet, speech 3–4 s. The recognizer
        // gave the pause to "two".
        let env = envelope(5, speech: [(0, 1), (3, 4)])
        var words = [t("one", 0, 1), t("two", 1, 3.5), t("three", 3.5, 4)]
        Refine.fit(&words, env: env)
        #expect(abs(words[1].start - 3) < 0.03 && words[1].how.hasSuffix("+pause"))
        #expect(abs(words[0].start - 0) < 0.03 && abs(words[0].end - 1) < 0.03)
    }

    @Test func aWordRunningIntoAPauseEndsWhereTheSoundFalls() {
        let env = envelope(5, speech: [(0, 1), (3, 4)])
        var words = [t("one", 0, 1.6), t("two", 3, 4)]
        Refine.fit(&words, env: env)
        #expect(abs(words[0].start - 0) < 0.03 && abs(words[0].end - 1) < 0.03)
        #expect(!words[0].how.contains("pause") && abs(words[1].start - 3) < 0.03)
    }

    @Test func aWordWhollyInThePauseBeforeItsSoundMovesToIt() {
        // Its span is silence, and its sound begins just after it.
        let env = envelope(4, speech: [(0, 1), (2.1, 3)])
        var words = [t("one", 0, 1), t("you", 1.4, 2.0), t("can", 2.0, 3)]
        Refine.fit(&words, env: env)
        #expect(abs(words[1].start - 2.1) < 0.03)
    }

    @Test func aWordIsItsLoudestStretchNotWhateverFollowsThePause() {
        // The word, then ten seconds of quiet, then a faint knock, all in
        // one span: it is the word.
        let env: [Float] = envelope(14, speech: [(2, 2.6)]).enumerated().map { k, v in
            let t = Double(k) * 0.005
            return t >= 12.6 && t < 12.9 ? -58 : v
        }
        var words = [t("a,", 0.5, 13)]
        Refine.fit(&words, env: env)
        #expect(abs(words[0].start - 2) < 0.03 && abs(words[0].end - 2.6) < 0.03)
    }

    @Test func aFaintKnockBeforeThePauseIsNotTheWord() {
        let env: [Float] = envelope(9, speech: [(6, 7)]).enumerated().map { k, v in
            let t = Double(k) * 0.005
            return t >= 0.3 && t < 0.5 ? -58 : v
        }
        var words = [t("you", 0, 6.5)]
        Refine.fit(&words, env: env)
        #expect(abs(words[0].start - 6) < 0.03 && words[0].how.hasSuffix("+pause"))
    }

    @Test func aShortGapIsNotAPause() {
        let env = envelope(3, speech: [(0, 1), (1.15, 2)])
        var words = [t("one", 0, 1.15), t("two", 1.15, 2)]
        Refine.fit(&words, env: env)
        #expect(!words[1].how.contains("pause") && abs(words[0].end - 1.15) < 0.001)
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
