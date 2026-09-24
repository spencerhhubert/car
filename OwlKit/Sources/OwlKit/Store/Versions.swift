import Foundation

// Release versions: dotted numbers (0.2.0), compared number by number, so
// 0.10.0 comes after 0.9.3. What the updater asks of a release tag.
public enum Versions {
    public static func newer(_ a: String, than b: String) -> Bool {
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let (p, q) = (i < x.count ? x[i] : 0, i < y.count ? y[i] : 0)
            if p != q { return p > q }
        }
        return false
    }

    private static func parts(_ v: String) -> [Int] {
        (v.hasPrefix("v") ? String(v.dropFirst()) : v).split(separator: ".").map { Int($0) ?? 0 }
    }
}
