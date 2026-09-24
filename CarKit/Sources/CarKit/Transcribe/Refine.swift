import AVFoundation
import Foundation

// Fit each word to the sound it was said in.
//
// A recognizer's word boundary is good to a few tens of milliseconds, except
// at a pause: it gives the pause to a word beside it, so a word can start
// where the speech before the pause stopped, seconds early, or run on through
// the pause. So a word's span is split at its pauses (a quarter second or
// more at the floor of the sound) into stretches of sound, and the word is
// the loudest of them:
//
//   - when that stretch is not where the span began, the word starts at its
//     first rise (`+pause`);
//   - otherwise its start snaps to the first rise above the local floor in a
//     short window around the given start, the onset (`+onset`); the window
//     is short, so a bad guess cannot move a word far;
//   - it ends where its stretch falls into a pause, when that is before the
//     given end, so a pause reads as the gap between two words, not as part
//     of either.
//
// A span that is all pause, with sound starting just after it, starts there.
enum Refine {
    /// The shortest quiet that counts as a pause, and how far over the floor
    /// is still quiet.
    static let pause = 0.25
    static let quietDb: Float = 9

    /// RMS energy in dB, one value per `hop` seconds.
    static func envelope(_ ch: [Float], rate: Double, hop: Double = 0.005) -> [Float] {
        let n = ch.count
        let step = max(1, Int(rate * hop))
        var out: [Float] = []
        out.reserveCapacity(n / step + 1)
        var i = 0
        while i < n {
            let end = min(n, i + step)
            var sum: Float = 0
            for k in i..<end { sum += ch[k] * ch[k] }
            let rms = (sum / Float(end - i)).squareRoot()
            out.append(rms > 0 ? 20 * log10(rms) : -120)
            i += step
        }
        return out
    }

    /// The sound's floor (its quietest fifth), and its pauses as ranges of
    /// frames: at least `pause` seconds within `quietDb` of the floor.
    static func pauses(_ env: [Float], hop: Double = 0.005) -> (floor: Float, pauses: [Range<Int>]) {
        guard !env.isEmpty else { return (-120, []) }
        let floor = env.sorted()[env.count / 5]
        let shortest = Int(pause / hop)
        var out: [Range<Int>] = []
        var from: Int?
        for k in 0...env.count {
            let quiet = k < env.count && env[k] < floor + quietDb
            if quiet, from == nil { from = k }
            if !quiet, let f = from {
                if k - f >= shortest { out.append(f..<k) }
                from = nil
            }
        }
        return (floor, out)
    }

    /// `snap` false leaves starts that are not moved past a pause where they
    /// are: for words that were snapped already (`car refit`), since
    /// snapping again inside continuous sound can creep.
    static func fit(_ words: inout [Align.Timed], env: [Float], hop: Double = 0.005, snap: Bool = true) {
        guard !env.isEmpty else { return }
        let n = env.count
        let (floor, pauses) = pauses(env, hop: hop)
        func frame(_ t: Double) -> Int { max(0, min(n - 1, Int(t / hop))) }
        func time(_ k: Int) -> Double { Double(k) * hop }
        /// The first rise in `lo...hi` to 30% of the way from the floor
        /// around `at` to the loudest point in the window.
        func onset(_ lo: Int, _ hi: Int, around at: Double) -> Int? {
            guard hi > lo + 2 else { return nil }
            let near = Array(env[frame(at - 0.6)...frame(at + 0.6)]).sorted()
            let floor = near[near.count / 5]
            let peak = env[lo...hi].max() ?? floor
            guard peak - floor > 8 else { return nil }
            let threshold = floor + 0.3 * (peak - floor)
            return ((lo + 1)...hi).first { env[$0] >= threshold && env[$0] > env[$0 - 1] }
        }
        /// How much sound a stretch holds: its loudness over quiet, summed.
        func mass(_ r: Range<Int>) -> Float { env[r].reduce(0) { $0 + max(0, $1 - floor - quietDb) } }
        let late = frame(0.3)
        var floorAt = 0.0
        for i in words.indices {
            let w = words[i]
            let (s, e) = (frame(w.start), max(frame(w.start) + 1, frame(w.end)))
            // The stretches of sound in the span, between its pauses.
            var sound: [Range<Int>] = []
            var at = s
            for p in pauses where p.upperBound > s && p.lowerBound < e {
                if p.lowerBound > at { sound.append(at..<p.lowerBound) }
                at = max(at, p.upperBound)
            }
            if at < e { sound.append(at..<e) }
            if sound.isEmpty {
                // All pause: the word is the sound just after it, if any.
                if let p = pauses.first(where: { $0.lowerBound <= s && $0.upperBound >= e }), p.upperBound < min(n, e + late) {
                    words[i].start = time(p.upperBound)
                    if !words[i].how.contains("+pause") { words[i].how += "+pause" }
                }
            } else if let loudest = sound.max(by: { mass($0) < mass($1) }) {
                if loudest.lowerBound > s {
                    let k = onset(loudest.lowerBound - 1, min(loudest.upperBound - 1, loudest.lowerBound + late),
                                  around: time(loudest.lowerBound)) ?? loudest.lowerBound
                    words[i].start = time(k)
                    if !words[i].how.contains("+pause") { words[i].how += "+pause" }
                } else if snap, let k = onset(frame(max(floorAt, w.start - 0.08)),
                                              frame(w.start + min(0.12, 0.5 * max(0.05, w.end - w.start))), around: w.start),
                          abs(time(k) - w.start) > 0.004 {
                    words[i].start = time(k)
                    words[i].how += "+onset"
                }
                // It ends where its sound falls into a pause.
                if loudest.upperBound < e { words[i].end = time(loudest.upperBound) }
            }
            if words[i].end <= words[i].start { words[i].end = words[i].start + 0.05 }
            // The next word's onset is not this one's.
            floorAt = words[i].start + 0.04
        }
    }

    /// No word starts before the one before it, and none runs into the next:
    /// an onset that moved a start earlier trims the previous word's end.
    static func monotonic(_ w: inout [Align.Timed]) {
        guard w.count > 1 else { return }
        for i in 1..<w.count {
            if w[i].start < w[i - 1].start { w[i].start = w[i - 1].start }
            if w[i - 1].end > w[i].start { w[i - 1].end = w[i].start }
            if w[i].end < w[i].start { w[i].end = w[i].start }
        }
    }
}
