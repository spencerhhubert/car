import AVFoundation
import Foundation

// Move each word's start to the moment it was actually heard.
//
// A recognizer's word boundary is good to a few tens of milliseconds; a frame
// is 33. So for every word, look at the sound's energy in a short window
// around its given start and snap the start to the first rise above the
// local floor, i.e. the onset. Only the start moves, and only inside the
// window, so a bad guess cannot move a word far.
enum Refine {
    /// RMS energy in dB, one value per `hop` seconds.
    static func envelope(url: URL, hop: Double = 0.005) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let fmt = file.processingFormat
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(file.length)) else { return [] }
        try file.read(into: buf)
        guard let ch = buf.floatChannelData?[0] else { return [] }
        let n = Int(buf.frameLength)
        let step = max(1, Int(fmt.sampleRate * hop))
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

    static func onsets(_ words: inout [Align.Timed], env: [Float], hop: Double = 0.005) {
        guard !env.isEmpty else { return }
        let n = env.count
        func frame(_ t: Double) -> Int { max(0, min(n - 1, Int(t / hop))) }
        var floorAt = 0.0
        for i in words.indices {
            let w = words[i]
            let length = max(0.05, w.end - w.start)
            let lo = frame(max(floorAt, w.start - 0.08))
            let hi = frame(w.start + min(0.12, 0.5 * length))
            guard hi > lo + 2 else { continue }
            // The floor is the quiet part of the second around the word.
            let around = Array(env[frame(w.start - 0.6)...frame(w.start + 0.6)]).sorted()
            let floor = around[around.count / 5]
            let peak = env[lo...hi].max() ?? floor
            guard peak - floor > 8 else { continue }
            let threshold = floor + 0.3 * (peak - floor)
            var onset: Int?
            for k in (lo + 1)...hi where env[k] >= threshold && env[k] > env[k - 1] {
                onset = k
                break
            }
            guard let onset else { continue }
            let t = Double(onset) * hop
            if abs(t - w.start) > 0.004 {
                words[i].start = t
                if words[i].end <= t { words[i].end = t + 0.05 }
                words[i].how += "+onset"
            }
            floorAt = words[i].start
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
