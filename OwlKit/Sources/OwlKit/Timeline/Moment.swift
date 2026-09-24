import Foundation

// A moment in a session, as a person or an agent writes one on the command
// line (`--from`, `--to`):
//
//   start          the session's first moment
//   end            its last
//   m3             marker 3
//   -20m, -90s     that long before `end` (the end of the range asked for)
//   1:02:03, 12:30 a time on the session clock
public enum Moment {
    public static func parse(_ s: String, in id: String, end: Int) -> Int? {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        if t == "start" { return 0 }
        if t == "end" { return end }
        if t.hasPrefix("m"), let n = Int(t.dropFirst()) {
            return Session.markers(id).first { $0.n == n }?.t
        }
        if t.hasPrefix("-"), let unit = t.last, let v = Double(t.dropFirst().dropLast()) {
            let seconds: Double
            switch unit {
            case "s": seconds = v
            case "m": seconds = v * 60
            case "h": seconds = v * 3600
            default: return nil
            }
            return max(0, end - Int(seconds * 1000))
        }
        let parts = t.split(separator: ":").map { Double($0) }
        guard (2...3).contains(parts.count), !parts.contains(nil) else { return nil }
        let v = parts.map { $0! }
        let seconds = v.count == 3 ? v[0] * 3600 + v[1] * 60 + v[2] : v[0] * 60 + v[1]
        return Int(seconds * 1000)
    }
}
