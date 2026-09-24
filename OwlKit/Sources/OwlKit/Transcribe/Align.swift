import Foundation

// Lay the remote model's words onto the local model's timed words.
//
// Two transcripts of one recording: A, the words worth keeping (the remote
// model's), and B, words with times (the local model's, or a model's timed
// segments cut into words). They mostly agree, with different mistakes,
// so a global alignment matches most of A to B one for one and each matched
// word takes B's time. A word with no partner (B missed it, or heard it
// differently) is placed between its nearest matched neighbours, in
// proportion to its length.
enum Align {
    struct Timed: Codable {
        var text: String
        /// Seconds into the audio.
        var start: Double
        var end: Double
        /// "matched", "interpolated"; Refine appends "+onset" when it moved
        /// the start to a heard onset.
        var how: String
    }

    static func normalize(_ s: String) -> String {
        s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init).joined()
    }

    /// `duration` is the length of the audio, for words with no anchor at all.
    static func merge(text: [String], timed: [LocalModel.Word], duration: Double) -> [Timed] {
        let a = text.map(normalize)
        let b = timed.map { normalize($0.text) }
        let pairs = align(a, b)
        var out: [Timed] = text.map { Timed(text: $0, start: -1, end: -1, how: "interpolated") }
        for (i, j) in pairs {
            out[i].start = timed[j].start
            out[i].end = timed[j].end
            out[i].how = "matched"
        }
        interpolate(&out, duration: duration)
        return out
    }

    private static func similar(_ x: String, _ y: String) -> Int {
        if x == y { return x.isEmpty ? 0 : 3 }
        if x.isEmpty || y.isEmpty { return -2 }
        if x.count >= 3, y.count >= 3, x.hasPrefix(y) || y.hasPrefix(x) { return 1 }
        if x.count >= 5, y.count >= 5, x.prefix(4) == y.prefix(4) { return 1 }
        if x.count >= 4, editsWithinOne(x, y) { return 1 }
        return -2
    }

    private static func editsWithinOne(_ x: String, _ y: String) -> Bool {
        let xs = Array(x), ys = Array(y)
        if abs(xs.count - ys.count) > 1 { return false }
        var i = 0, j = 0, edits = 0
        while i < xs.count && j < ys.count {
            if xs[i] == ys[j] { i += 1; j += 1; continue }
            edits += 1
            if edits > 1 { return false }
            if xs.count > ys.count { i += 1 } else if ys.count > xs.count { j += 1 } else { i += 1; j += 1 }
        }
        return edits + (xs.count - i) + (ys.count - j) <= 1
    }

    /// Banded Needleman-Wunsch: returns matched (i, j) pairs.
    static func align(_ a: [String], _ b: [String]) -> [(Int, Int)] {
        let n = a.count, m = b.count
        guard n > 0, m > 0 else { return [] }
        let band = n * m <= 2_500_000 ? max(n, m) : max(150, abs(n - m) + 100)
        let width = 2 * band + 1
        let gap = -1
        let none = Int32.min / 4
        func center(_ i: Int) -> Int { Int((Double(i) * Double(m) / Double(n)).rounded()) }
        var score = [Int32](repeating: none, count: (n + 1) * width)
        var dir = [UInt8](repeating: 0, count: (n + 1) * width)
        func idx(_ i: Int, _ j: Int) -> Int? {
            let k = j - center(i) + band
            return (k >= 0 && k < width) ? i * width + k : nil
        }
        for i in 0...n {
            let lo = max(0, center(i) - band), hi = min(m, center(i) + band)
            if lo > hi { continue }
            for j in lo...hi {
                guard let here = idx(i, j) else { continue }
                if i == 0 && j == 0 { score[here] = 0; continue }
                var best = none, d: UInt8 = 0
                if i > 0, j > 0, let p = idx(i - 1, j - 1), score[p] != none {
                    let s = score[p] + Int32(similar(a[i - 1], b[j - 1]))
                    if s > best { best = s; d = 1 }
                }
                if i > 0, let p = idx(i - 1, j), score[p] != none, score[p] + Int32(gap) > best {
                    best = score[p] + Int32(gap); d = 2
                }
                if j > 0, let p = idx(i, j - 1), score[p] != none, score[p] + Int32(gap) > best {
                    best = score[p] + Int32(gap); d = 3
                }
                score[here] = best
                dir[here] = d
            }
        }
        var pairs: [(Int, Int)] = []
        var i = n, j = m
        while i > 0 || j > 0 {
            guard let here = idx(i, j), score[here] != none else {
                // Fell out of the band; give up on the rest.
                break
            }
            switch dir[here] {
            case 1:
                if similar(a[i - 1], b[j - 1]) > 0 { pairs.append((i - 1, j - 1)) }
                i -= 1; j -= 1
            case 2: i -= 1
            case 3: j -= 1
            default: i = 0; j = 0
            }
        }
        return pairs.reversed()
    }

    private static func interpolate(_ w: inout [Timed], duration: Double) {
        let matched = w.indices.filter { w[$0].how == "matched" }
        guard let first = matched.first else {
            // Nothing lined up at all: spread the words over the whole take.
            let chars = w.reduce(0) { $0 + max($1.text.count, 1) }
            var at = 0.0
            for i in w.indices {
                let share = duration * Double(max(w[i].text.count, 1)) / Double(max(chars, 1))
                w[i].start = at; w[i].end = at + share; at += share
            }
            return
        }
        // Before the first anchor and after the last: a quarter second a word.
        var t = w[first].start
        for i in stride(from: first - 1, through: 0, by: -1) {
            let len = max(0.12, min(0.4, 0.06 * Double(w[i].text.count)))
            w[i].end = max(0, t); w[i].start = max(0, t - len); t = w[i].start
        }
        let last = matched.last!
        t = w[last].end
        for i in (last + 1)..<w.count {
            let len = max(0.12, min(0.4, 0.06 * Double(w[i].text.count)))
            w[i].start = t; w[i].end = t + len; t = w[i].end
        }
        // Between anchors: the gap shared by length.
        for (p, q) in zip(matched, matched.dropFirst()) where q - p > 1 {
            let from = w[p].end, to = max(w[q].start, from)
            let chars = (p + 1..<q).reduce(0) { $0 + max(w[$1].text.count, 1) }
            var at = from
            for i in (p + 1)..<q {
                let share = (to - from) * Double(max(w[i].text.count, 1)) / Double(chars)
                w[i].start = at; w[i].end = at + share; at += share
            }
        }
    }
}
