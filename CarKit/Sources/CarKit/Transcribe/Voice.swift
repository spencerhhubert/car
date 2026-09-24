import Accelerate
import Foundation

// Where in a stretch of sound someone is talking: voice activity detection,
// with no model. Transcribing everything to find out whether anything was said
// would be asking a recognizer "there is speech; what is it?" about every
// silent minute of a session that runs all day. This answers the first half
// for almost nothing, so a silent chunk costs nothing and a talking one sends
// only its talking.
//
// A 20 ms frame is voice when both hold:
//   - it is louder than the room: its energy is `aboveFloor` dB over the noise
//     floor, which follows the quiet of the last few seconds (a low
//     percentile), so a fan or a hum raises the bar rather than passing it;
//   - it is voiced: its normalised autocorrelation has a peak at a lag of a
//     voice's pitch (70–400 Hz). A voice buzzes at its pitch; fans, hiss,
//     clicks and keyboards do not.
// Then the voiced frames become segments: gaps shorter than `bridge` are
// closed (the unvoiced sounds between syllables), anything shorter than
// `shortest` is dropped (a knock, a cough), and each segment is widened by
// `pad` on both sides, which brings back the unvoiced onsets and endings
// ("s", "t", "f") that voicing alone misses.
public enum Voice {
    public static let frame = 0.02
    static let aboveFloor: Float = 9
    static let voicing: Float = 0.42
    static let bridge = 0.35
    static let shortest = 0.15
    static let pad = 0.25
    /// Seconds of history the noise floor is taken over, and its percentile.
    static let floorWindow = 4.0
    static let floorPercentile = 0.15

    /// A stretch of voice, in seconds from the start of the sound.
    public struct Segment: Equatable, Sendable {
        public var start: Double
        public var end: Double
        public var length: Double { end - start }
    }

    /// The voiced segments of a file, and its samples, at the rate
    /// transcription hears everything at.
    public static func segments(url: URL) throws -> (segments: [Segment], samples: [Float], rate: Double) {
        let samples = try Sound.heard(url)
        return (segments(samples, rate: Sound.heardRate), samples, Sound.heardRate)
    }

    public static func segments(_ x: [Float], rate: Double) -> [Segment] {
        let n = Int(rate * frame)
        guard n > 0, x.count >= n else { return [] }
        let frames = x.count / n
        let minLag = Int(rate / 400), maxLag = min(n - 1, Int(rate / 70))

        // Energy (dB) and voicing of every frame.
        var energy = [Float](repeating: -120, count: frames)
        var voiced = [Float](repeating: 0, count: frames)
        x.withUnsafeBufferPointer { all in
            for f in 0..<frames {
                let p = all.baseAddress! + f * n
                var power: Float = 0
                vDSP_measqv(p, 1, &power, vDSP_Length(n))
                energy[f] = power > 0 ? 10 * log10(power) : -120
                guard power > 1e-9 else { continue }
                // Normalised autocorrelation at each candidate pitch lag.
                var best: Float = 0
                var lag = minLag
                while lag <= maxLag {
                    let m = vDSP_Length(n - lag)
                    var dot: Float = 0, e1: Float = 0, e2: Float = 0
                    vDSP_dotpr(p, 1, p + lag, 1, &dot, m)
                    vDSP_svesq(p, 1, &e1, m)
                    vDSP_svesq(p + lag, 1, &e2, m)
                    let r = dot / max(1e-12, (e1 * e2).squareRoot())
                    if r > best { best = r }
                    lag += 1
                }
                voiced[f] = best
            }
        }

        // The noise floor under each frame: a low percentile of the energy
        // over the window before it (the start of the sound uses what it has).
        let span = max(1, Int(floorWindow / frame))
        var floor = [Float](repeating: -120, count: frames)
        var window: [Float] = []
        window.reserveCapacity(span)
        let stride = max(1, span / 20)
        var current: Float = -120
        for f in 0..<frames {
            window.append(energy[f])
            if window.count > span { window.removeFirst() }
            if f % stride == 0 || f < 50 {
                let sorted = window.sorted()
                current = sorted[min(sorted.count - 1, Int(Double(sorted.count) * floorPercentile))]
            }
            floor[f] = current
        }

        // Voiced frames into segments.
        var out: [Segment] = []
        var runStart: Int?
        for f in 0...frames {
            let on = f < frames && energy[f] > floor[f] + aboveFloor && voiced[f] > voicing && energy[f] > -60
            if on, runStart == nil { runStart = f }
            if !on, let s = runStart {
                out.append(Segment(start: Double(s) * frame, end: Double(f) * frame))
                runStart = nil
            }
        }
        var merged: [Segment] = []
        for s in out {
            if let last = merged.last, s.start - last.end < bridge {
                merged[merged.count - 1].end = s.end
            } else {
                merged.append(s)
            }
        }
        let total = Double(x.count) / rate
        return merged.filter { $0.length >= shortest }
            .map { Segment(start: max(0, $0.start - pad), end: min(total, $0.end + pad)) }
            .reduce(into: [Segment]()) { acc, s in
                if let last = acc.last, s.start <= last.end { acc[acc.count - 1].end = max(last.end, s.end) }
                else { acc.append(s) }
            }
    }
}
