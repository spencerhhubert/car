import Foundation
import Testing
@testable import CarKit

@Suite struct VoiceTests {
    static let rate = 16000.0

    /// Seconds of low noise, with a voice-like buzz (a 140 Hz pitch and its
    /// harmonics, gently wobbling) over the given stretches.
    static func sound(_ seconds: Double, voice: [(Double, Double)], noiseDb: Float = -50, voiceDb: Float = -20) -> [Float] {
        var g = SystemRandomNumberGenerator()
        let n = Int(seconds * rate)
        let noise = pow(10, noiseDb / 20), loud = pow(10, voiceDb / 20)
        return (0..<n).map { i in
            let t = Double(i) / rate
            var x = Float.random(in: -1...1, using: &g) * noise
            if voice.contains(where: { t >= $0.0 && t < $0.1 }) {
                let f0 = 140 * (1 + 0.05 * sin(2 * .pi * 3 * t))
                var v = 0.0
                for h in 1...8 { v += sin(2 * .pi * f0 * Double(h) * t) / Double(h) }
                x += Float(v) * loud * 0.5
            }
            return x
        }
    }

    @Test func noiseAloneIsNotVoice() {
        #expect(Voice.segments(Self.sound(6, voice: []), rate: Self.rate).isEmpty)
        #expect(Voice.segments(Self.sound(6, voice: [], noiseDb: -25), rate: Self.rate).isEmpty)
    }

    @Test func voiceIsFoundWhereItIs() {
        let segs = Voice.segments(Self.sound(8, voice: [(2, 3.5), (5.2, 6)]), rate: Self.rate)
        #expect(segs.count == 2)
        #expect(abs(segs[0].start - (2 - Voice.pad)) < 0.1 && abs(segs[0].end - (3.5 + Voice.pad)) < 0.1)
        #expect(abs(segs[1].start - (5.2 - Voice.pad)) < 0.1)
    }

    @Test func aShortGapBetweenSyllablesIsBridged() {
        let segs = Voice.segments(Self.sound(5, voice: [(1, 1.6), (1.8, 2.4)]), rate: Self.rate)
        #expect(segs.count == 1)
    }

    @Test func aClipMapsBackToTheChunk() throws {
        let samples = Self.sound(6, voice: [])
        let segs = [Voice.Segment(start: 1, end: 2), Voice.Segment(start: 4, end: 5)]
        let clip = try Clip(segs, samples, Self.rate)
        defer { clip.remove() }
        #expect(abs(clip.seconds - (2 + Clip.gap)) < 0.001)
        #expect(abs(clip.chunkTime(0.5) - 1.5) < 0.001)
        #expect(abs(clip.chunkTime(1 + Clip.gap + 0.2) - 4.2) < 0.001)
        #expect(abs(clip.chunkTime(1.1) - 2) < 0.001)   // in the gap: the end of the stretch before
        #expect(abs(clip.chunkTime(1.1, starting: true) - 4) < 0.001)   // or, for a start, of the stretch after
    }

    @Test func wordsSpreadOverTheVoiceOnly() {
        let words = Transcribe.spread(["one", "two", "three", "four"],
                                      over: [Voice.Segment(start: 1, end: 2), Voice.Segment(start: 10, end: 11)])
        #expect(words.first!.start == 1)
        #expect(words.allSatisfy { ($0.start >= 1 && $0.start <= 2) || ($0.start >= 10 && $0.start <= 11) })
        #expect(abs(words.last!.end - 11) < 0.001)
    }
}
