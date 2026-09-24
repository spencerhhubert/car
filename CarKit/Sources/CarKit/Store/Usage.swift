import Foundation

// What transcription has cost: every call to OpenRouter is a row in the
// catalog, with the session and chunk it was for, the model, the seconds of
// sound sent and the dollars OpenRouter reported. With sessions running for
// hours this is the number to watch, so the menu shows it and `car usage`
// prints it.
public enum Usage {
    public static func record(session: String?, chunk: Int?, purpose: String, model: String,
                              audioSeconds: Double?, cost: Double) {
        let at = ISO8601DateFormatter().string(from: Date())
        Catalog.shared.async { h in
            try h.run("""
                INSERT INTO usage (at, session, chunk, purpose, model, audio_seconds, cost)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, [at, session, chunk, purpose, model, audioSeconds, cost])
        }
    }

    public struct Total: Sendable {
        public let cost: Double
        public let audioSeconds: Double
        public let calls: Int
    }

    /// Everything since `date`, or ever.
    public static func total(since date: Date? = nil) -> Total {
        let since = ISO8601DateFormatter().string(from: date ?? .distantPast)
        let r = try? Catalog.shared.sync { h in
            h.rows("""
                SELECT COALESCE(SUM(cost), 0) AS cost, COALESCE(SUM(audio_seconds), 0) AS audio, COUNT(*) AS calls
                FROM usage WHERE at >= ?
                """, [since]).first
        }
        return Total(cost: r?.real("cost") ?? 0, audioSeconds: r?.real("audio") ?? 0, calls: r?.int("calls") ?? 0)
    }

    /// What one session has cost.
    public static func total(session: String) -> Total {
        let r = try? Catalog.shared.sync { h in
            h.rows("""
                SELECT COALESCE(SUM(cost), 0) AS cost, COALESCE(SUM(audio_seconds), 0) AS audio, COUNT(*) AS calls
                FROM usage WHERE session = ?
                """, [session]).first
        }
        return Total(cost: r?.real("cost") ?? 0, audioSeconds: r?.real("audio") ?? 0, calls: r?.int("calls") ?? 0)
    }

    /// Since `date`, by model, dearest first.
    public static func byModel(since date: Date? = nil) -> [(model: String, total: Total)] {
        let since = ISO8601DateFormatter().string(from: date ?? .distantPast)
        let rows = (try? Catalog.shared.sync { h in
            h.rows("""
                SELECT model, SUM(cost) AS cost, COALESCE(SUM(audio_seconds), 0) AS audio, COUNT(*) AS calls
                FROM usage WHERE at >= ? GROUP BY model ORDER BY cost DESC
                """, [since])
        }) ?? []
        return rows.map {
            ($0.text("model") ?? "?",
             Total(cost: $0.real("cost") ?? 0, audioSeconds: $0.real("audio") ?? 0, calls: $0.int("calls") ?? 0))
        }
    }

    /// The spans the menu and `car usage` show: today, the last 7 and 30
    /// days, all of it.
    public static var spans: [(name: String, since: Date?)] {
        let now = Date()
        return [("today", Calendar.current.startOfDay(for: now)),
                ("7 days", now.addingTimeInterval(-7 * 86400)),
                ("30 days", now.addingTimeInterval(-30 * 86400)),
                ("all time", nil)]
    }

    public static func dollars(_ d: Double) -> String {
        d < 1 ? String(format: "$%.3f", d) : String(format: "$%.2f", d)
    }
}
