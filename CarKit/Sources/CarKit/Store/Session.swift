import AVFoundation
import Foundation

// A session is a stretch of recording, meant to run for hours: started and
// stopped with ⌘ ⌥ ⌥, marked along the way (a marker hands an agent everything
// up to it), its sound cut into chunks that are transcribed as they close.
//
// The catalog (Catalog.swift) holds everything about it. Its folder holds
// only the heavy files, which the catalog points at:
//
//   sessions/<id>/
//     audio/<n>.m4a    the microphone, one chunk each, at the session's
//                      sound quality (Sound.swift)
//     shots/<t>.jpg    pictures of the screen
//     session.md       the timeline, written out when the session finishes
//     .lock            held by the process recording or transcribing it
//
// A session is recording, then transcribing (its last chunks), then done or
// failed. The lock says whether anyone is still at it: a session left
// recording or transcribing with its lock free was orphaned by a crash or a
// quit, and whoever finds it (the app at launch, `car session` or
// `car marker` asked for it) finishes it. The lock is an flock, so the kernel
// lets go of it when its holder dies, however it dies.
//
// The id is the local start time, so ids sort chronologically.
public final class Session: @unchecked Sendable {
    public let id: String
    public let dir: URL
    public let startedAt: Date
    /// The session clock's zero, on `Clock`.
    public let t0: Double
    public let lock: SessionLock
    private let mutex = NSLock()
    private var open = true

    public init(input: String) throws {
        startedAt = Date()
        t0 = Clock.now
        (id, dir) = try Session.makeFolder(for: startedAt)
        guard let lock = SessionLock(dir) else { throw Failure("could not lock \(dir.path)") }
        self.lock = lock
        for sub in ["audio", "shots"] {
            try FileManager.default.createDirectory(at: dir.appending(path: sub), withIntermediateDirectories: true)
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        iso.timeZone = .current
        let (id, started) = (id, iso.string(from: startedAt))
        try Catalog.shared.sync { h in
            try h.run("INSERT INTO sessions (id, started_at, time_zone, state, input) VALUES (?, ?, ?, 'recording', ?)",
                      [id, started, TimeZone.current.identifier, input])
        }
    }

    /// Milliseconds since the session started, now.
    public var now: Int { ms(Clock.now) }

    /// A reading of `Clock` on the session clock, in ms.
    public func ms(_ clock: Double) -> Int { Int(((clock - t0) * 1000).rounded()) }

    private var isOpen: Bool { mutex.withLock { open } }

    /// Record one event. `fields` must be JSON-encodable. An event that
    /// arrives after the session closed (a picture still being taken when it
    /// stopped) is dropped.
    public func event(_ kind: String, _ fields: [String: Any] = [:], at t: Int? = nil) {
        guard isOpen else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys, .withoutEscapingSlashes]),
              let json = String(data: data, encoding: .utf8)
        else { Log.line("event \(kind) is not JSON; dropped"); return }
        let (id, t) = (id, t ?? now)
        Catalog.shared.async { h in
            try h.run("INSERT INTO events (session, t, kind, data) VALUES (?, ?, ?, ?)", [id, t, kind, json])
        }
    }

    /// A picture was written to `shots/<name>`: catalog the file and record
    /// the moment.
    public func shot(_ name: String, at t: Int, _ fields: [String: Any]) {
        guard isOpen else { return }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: dir.appending(path: "shots/\(name)").path)[.size])
            as? Int
        let id = id
        Catalog.shared.async { h in
            var f = fields
            try h.transaction {
                try h.run("INSERT INTO files (session, kind, t, store, path, bytes) VALUES (?, 'shot', ?, 'local', ?, ?)",
                          [id, t, "\(id)/shots/\(name)", bytes])
                f["file"] = h.lastID
                let data = try JSONSerialization.data(withJSONObject: f, options: [.sortedKeys, .withoutEscapingSlashes])
                try h.run("INSERT INTO events (session, t, kind, data) VALUES (?, ?, 'shot', ?)",
                          [id, t, String(decoding: data, as: UTF8.self)])
            }
        }
    }

    /// A marker now: its number, and the wall time it was set at.
    public func marker() throws -> (n: Int, t: Int, at: Date) {
        let (id, t, at) = (id, now, Date())
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        iso.timeZone = .current
        let n = try Catalog.shared.sync { h -> Int in
            let n = (h.rows("SELECT MAX(n) AS n FROM markers WHERE session = ?", [id]).first?.int("n") ?? 0) + 1
            try h.run("INSERT INTO markers (session, n, t, at) VALUES (?, ?, ?, ?)", [id, n, t, iso.string(from: at)])
            return n
        }
        return (n, t, at)
    }

    /// Chunk `n` of the sound began at `start` (on `Clock`), in `file`
    /// under the session's folder. It is in the catalog from its first
    /// sample, so a crash mid-chunk leaves a row that says what was lost.
    public func chunkOpened(_ n: Int, file: String, start: Double) {
        let (id, start) = (id, ms(start))
        Catalog.shared.async { h in
            try h.transaction {
                try h.run("INSERT INTO files (session, kind, t, store, path) VALUES (?, 'audio', ?, 'local', ?)",
                          [id, start, "\(id)/\(file)"])
                try h.run("INSERT INTO chunks (session, n, start_ms, state, file) VALUES (?, ?, ?, 'recording', ?)",
                          [id, n, start, h.lastID])
            }
        }
    }

    /// Chunk `n` is finished (its last sample at `end`, on `Clock`) and can
    /// be transcribed.
    public func chunkClosed(_ n: Int, file: String, end: Double, seconds: Double, peakDb: Double) {
        let bytes = (try? FileManager.default.attributesOfItem(atPath: dir.appending(path: file).path)[.size]) as? Int
        let (id, end) = (id, ms(end))
        Catalog.shared.async { h in
            try h.run("""
                UPDATE chunks SET end_ms = ?, sound_seconds = ?, peak_db = ?, state = 'recorded'
                WHERE session = ? AND n = ?
                """, [end, seconds, peakDb, id, n])
            try h.run("UPDATE files SET bytes = ? WHERE id = (SELECT file FROM chunks WHERE session = ? AND n = ?)",
                      [bytes, id, n])
        }
    }

    /// No more events: the session is over and its last chunks are being
    /// transcribed.
    public func close() {
        shut()
        let (id, length) = (id, now)
        Catalog.shared.async { h in
            try h.run("UPDATE sessions SET state = 'transcribing', length_ms = ? WHERE id = ?", [length, id])
        }
    }

    /// Throw the session away: rows, files, folder.
    public func remove() {
        shut()
        let id = id
        _ = try? Catalog.shared.sync { h in try h.run("DELETE FROM sessions WHERE id = ?", [id]) }
        try? FileManager.default.removeItem(at: dir)
        lock.release()
    }

    private func shut() { mutex.withLock { open = false } }

    /// Wait until everything handed to the catalog is written: before the
    /// app quits.
    public static func flush() { _ = try? Catalog.shared.sync { _ in } }

    private static func makeFolder(for date: Date) throws -> (String, URL) {
        try FileManager.default.createDirectory(at: Config.sessionsDir, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let base = f.string(from: date)
        for n in 1...50 {
            let id = n == 1 ? base : "\(base)-\(n)"
            let dir = Config.sessionsDir.appending(path: id)
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
                return (id, dir)
            } catch let e as NSError where e.code == NSFileWriteFileExistsError {
                continue
            }
        }
        throw Failure("no free session id at \(base)")
    }

    // MARK: - reading sessions back

    public static func dir(_ id: String) -> URL { Config.sessionsDir.appending(path: id) }

    public static func list() -> [SessionRecord] {
        (try? Catalog.shared.sync { h in h.rows("SELECT * FROM sessions ORDER BY id").map(SessionRecord.init) }) ?? []
    }

    public static func record(_ id: String) -> SessionRecord? {
        try? Catalog.shared.sync { h in h.rows("SELECT * FROM sessions WHERE id = ?", [id]).first.map(SessionRecord.init) }
    }

    public static func setState(_ id: String, _ state: SessionRecord.State, error: String? = nil) {
        _ = try? Catalog.shared.sync { h in
            try h.run("UPDATE sessions SET state = ?, error = ? WHERE id = ?", [state.rawValue, error, id])
        }
    }

    public static func chunks(_ id: String) -> [ChunkRecord] {
        (try? Catalog.shared.sync { h in
            h.rows("SELECT * FROM chunks WHERE session = ? ORDER BY n", [id]).map(ChunkRecord.init)
        }) ?? []
    }

    public static func markers(_ id: String) -> [MarkerRecord] {
        (try? Catalog.shared.sync { h in
            h.rows("SELECT * FROM markers WHERE session = ? ORDER BY n", [id]).map(MarkerRecord.init)
        }) ?? []
    }

    /// Events from `from` to `to` (session ms, inclusive), in the order of
    /// the clock, each with `t` and `kind` among its fields.
    public static func events(_ id: String, from: Int = 0, to: Int = .max) -> [[String: Any]] {
        let rows = (try? Catalog.shared.sync { h in
            h.rows("SELECT t, kind, data FROM events WHERE session = ? AND t BETWEEN ? AND ? ORDER BY t, id",
                   [id, from, to])
        }) ?? []
        return rows.compactMap { r in
            guard var e = r.text("data").flatMap({ try? JSONSerialization.jsonObject(with: Data($0.utf8)) })
                as? [String: Any] else { return nil }
            e["t"] = r.int("t")
            e["kind"] = r.text("kind")
            return e
        }
    }

    public static func words(_ id: String, from: Int = 0, to: Int = .max) -> [Word] {
        (try? Catalog.shared.sync { h in
            h.rows("SELECT * FROM words WHERE session = ? AND start_ms BETWEEN ? AND ? ORDER BY start_ms, chunk, i",
                   [id, from, to]).map(Word.init)
        }) ?? []
    }

    /// The chunks whose words up to `t` are still to come: not settled, and
    /// begun before `t`. Not the one a cut at `t` opened, which can begin a
    /// buffer of sound early.
    public static func unsettled(_ id: String, before t: Int) -> [ChunkRecord] {
        chunks(id).filter { !$0.state.settled && $0.startMs < t - 250 }
    }

    /// Every session, newest first, with the first words said in it: what a
    /// list of sessions shows.
    public static func summaries() -> [SessionSummary] {
        (try? Catalog.shared.sync { h in
            h.rows("""
                SELECT s.*, (SELECT group_concat(text, ' ') FROM
                    (SELECT text FROM words w WHERE w.session = s.id ORDER BY start_ms, chunk, i LIMIT 30)) AS opening
                FROM sessions s ORDER BY id DESC
                """).map { SessionSummary(record: SessionRecord($0), opening: $0.text("opening") ?? "") }
        }) ?? []
    }

    /// How many words the session has so far.
    public static func wordCount(_ id: String) -> Int {
        (try? Catalog.shared.sync { h in
            h.rows("SELECT COUNT(*) AS n FROM words WHERE session = ?", [id]).first?.int("n")
        }) ?? 0
    }

    /// Where each of a session's files of one kind is now, by file id.
    public static func files(_ id: String, kind: String) -> [Int: URL] {
        let rows = (try? Catalog.shared.sync { h in
            h.rows("""
                SELECT files.id AS id, stores.root AS root, files.path AS path
                FROM files JOIN stores ON stores.name = files.store WHERE files.session = ? AND files.kind = ?
                """, [id, kind])
        }) ?? []
        var out: [Int: URL] = [:]
        for r in rows {
            if let f = r.int("id"), let root = r.text("root"), let path = r.text("path") {
                out[f] = URL(fileURLWithPath: root).appending(path: path)
            }
        }
        return out
    }

    /// Where a catalogued file is now.
    public static func path(file: Int) -> URL? {
        guard let r = try? Catalog.shared.sync({ h in
            h.rows("SELECT stores.root AS root, files.path AS path FROM files JOIN stores ON stores.name = files.store WHERE files.id = ?",
                   [file]).first
        }), let root = r.text("root"), let path = r.text("path") else { return nil }
        return URL(fileURLWithPath: root).appending(path: path)
    }
}

/// The session clock: a monotonic clock that keeps counting while the Mac
/// sleeps, so a session that spans a lunch break keeps its times true to the
/// wall. Sound arrives stamped on the host clock, which stops during sleep;
/// `fromHost` converts.
public enum Clock {
    public static var now: Double { Double(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1e9 }

    public static func fromHost(_ hostTime: UInt64) -> Double {
        let host = AVAudioTime.seconds(forHostTime: hostTime)
        let hostNow = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9
        return now - (hostNow - host)
    }
}

public struct SessionRecord: Sendable, Equatable {
    public enum State: String, Sendable { case recording, transcribing, done, failed }

    public let id: String
    public let startedAt: String
    public let timeZone: String
    public let state: State
    public let lengthMs: Int?
    public let input: String?
    public let error: String?

    init(_ r: Row) {
        id = r.text("id") ?? ""
        startedAt = r.text("started_at") ?? ""
        timeZone = r.text("time_zone") ?? ""
        state = State(rawValue: r.text("state") ?? "") ?? .failed
        lengthMs = r.int("length_ms")
        input = r.text("input")
        error = r.text("error")
    }

    public var started: Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return iso.date(from: startedAt) ?? ISO8601DateFormatter().date(from: startedAt)
    }

    public var isLive: Bool { state == .recording || state == .transcribing }
}

/// A session as a list shows it.
public struct SessionSummary: Sendable, Identifiable, Equatable {
    public let record: SessionRecord
    /// The first words said in it.
    public let opening: String

    public var id: String { record.id }
}

public struct ChunkRecord: Sendable {
    public enum State: String, Sendable {
        case recording, recorded, transcribed, silent, failed, lost
        /// Nothing more will come of it without being asked.
        public var settled: Bool { self == .transcribed || self == .silent || self == .failed || self == .lost }
    }

    public let n: Int
    public let startMs: Int
    public let endMs: Int?
    public let soundSeconds: Double?
    public let peakDb: Double?
    public let state: State
    /// The model that wrote its words, and the one that timed them.
    public let remoteModel: String?
    public let localModel: String?
    public let note: String?
    public let error: String?
    public let file: Int?

    init(_ r: Row) {
        n = r.int("n") ?? 0
        startMs = r.int("start_ms") ?? 0
        endMs = r.int("end_ms")
        soundSeconds = r.real("sound_seconds")
        peakDb = r.real("peak_db")
        state = State(rawValue: r.text("state") ?? "") ?? .failed
        remoteModel = r.text("remote_model")
        localModel = r.text("local_model")
        note = r.text("note")
        error = r.text("error")
        file = r.int("file")
    }
}

public struct MarkerRecord: Sendable {
    public let n: Int
    public let t: Int
    /// The wall time it was set at, ISO 8601.
    public let at: String

    init(_ r: Row) {
        n = r.int("n") ?? 0
        t = r.int("t") ?? 0
        at = r.text("at") ?? ""
    }
}

public struct Word: Sendable {
    public let chunk: Int
    public let text: String
    public let start: Int
    public let end: Int
    public let how: String

    init(_ r: Row) {
        chunk = r.int("chunk") ?? 0
        text = r.text("text") ?? ""
        start = r.int("start_ms") ?? 0
        end = r.int("end_ms") ?? 0
        how = r.text("how") ?? ""
    }
}

/// The advisory lock on a session folder. Whoever holds it is recording or
/// transcribing the session; the kernel releases it if the holder dies.
public final class SessionLock: @unchecked Sendable {
    private var fd: Int32
    private let mutex = NSLock()

    /// Takes the lock, or nil when someone else has it.
    public init?(_ dir: URL) {
        let fd = Darwin.open(dir.appending(path: ".lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(fd)
            return nil
        }
        self.fd = fd
    }

    public func release() {
        mutex.withLock {
            guard fd >= 0 else { return }
            Darwin.close(fd)
            fd = -1
        }
    }

    deinit { release() }

    /// Whether someone is at the session now.
    public static func isHeld(_ dir: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: dir.path) else { return false }
        guard let probe = SessionLock(dir) else { return true }
        probe.release()
        return false
    }
}
