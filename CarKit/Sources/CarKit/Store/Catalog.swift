import Foundation
import SQLite3

// car's catalog: one SQLite database per copy (car.sqlite beside config.json)
// holding everything known about every session: the session, its chunks of
// sound, its words, its events, its markers, what transcribing it cost, and
// where every file it made lives.
//
// The files (audio chunks, pictures) are the heavy data, and the catalog is
// the only thing that says where they are: each sits in a store (to begin
// with `local`, the sessions folder on this Mac) at a path under that store's
// root. Moving old pictures to another drive is copying them there and
// changing their rows.
//
// One connection per process, used only on its own queue. The app and the
// `car` command share the file: write-ahead log, and a busy timeout for the
// moments both write. Nothing outside CarKit sees SQL: Session.swift and
// Usage.swift are the ways in.
final class Catalog: @unchecked Sendable {
    static let shared = Catalog(Config.root.appending(path: "car.sqlite"))

    private let queue = DispatchQueue(label: "car.catalog")
    private var db: OpaquePointer?

    private init(_ url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
                == SQLITE_OK, let db else {
            Log.line("catalog: cannot open \(url.path)")
            return
        }
        sqlite3_busy_timeout(db, 10_000)
        do {
            let h = Handle(db: db)
            try h.run("PRAGMA journal_mode = WAL")
            try h.run("PRAGMA synchronous = NORMAL")
            try h.run("PRAGMA foreign_keys = ON")
            try Catalog.migrate(h)
            try h.run("INSERT OR IGNORE INTO stores (name, root) VALUES ('local', ?)", [Config.sessionsDir.path])
        } catch {
            Log.line("catalog: \(error.localizedDescription)")
        }
    }

    /// Run `body` on the catalog's queue and wait for it.
    func sync<T>(_ body: (Handle) throws -> T) throws -> T {
        try queue.sync {
            guard let db else { throw Failure("the catalog is not open") }
            return try body(Handle(db: db))
        }
    }

    /// Run `body` on the catalog's queue without waiting. A failure is logged.
    func async(_ body: @escaping (Handle) throws -> Void) {
        queue.async {
            guard let db = self.db else { return }
            do { try body(Handle(db: db)) } catch { Log.line("catalog: \(error.localizedDescription)") }
        }
    }

    // MARK: - the schema

    private static let schema = [
        """
        CREATE TABLE sessions (
            id TEXT PRIMARY KEY,
            started_at TEXT NOT NULL,          -- ISO 8601 with the offset
            time_zone TEXT NOT NULL,
            state TEXT NOT NULL,               -- recording, transcribing, done, failed
            length_ms INTEGER,                 -- on the session clock, once it stopped
            input TEXT,                        -- the microphone
            error TEXT                         -- why it failed
        )
        """,
        """
        CREATE TABLE stores (
            name TEXT PRIMARY KEY,             -- 'local' is this Mac's sessions folder
            root TEXT NOT NULL
        )
        """,
        """
        CREATE TABLE files (
            id INTEGER PRIMARY KEY,
            session TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
            kind TEXT NOT NULL,                -- audio, shot
            t INTEGER NOT NULL,                -- session ms it belongs to
            store TEXT NOT NULL REFERENCES stores(name),
            path TEXT NOT NULL,                -- under the store's root
            bytes INTEGER
        )
        """,
        "CREATE INDEX files_session ON files(session, kind, t)",
        """
        CREATE TABLE chunks (
            session TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
            n INTEGER NOT NULL,
            start_ms INTEGER NOT NULL,         -- session clock, first sample
            end_ms INTEGER,                    -- session clock, last sample
            sound_seconds REAL,
            peak_db REAL,
            state TEXT NOT NULL,               -- recording, recorded, transcribed, silent, failed, lost
            text_model TEXT,                   -- remote_model since version 2
            time_source TEXT,                  -- local_model since version 2
            note TEXT,
            error TEXT,
            file INTEGER REFERENCES files(id),
            PRIMARY KEY (session, n)
        )
        """,
        """
        CREATE TABLE words (
            session TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
            chunk INTEGER NOT NULL,
            i INTEGER NOT NULL,
            text TEXT NOT NULL,
            start_ms INTEGER NOT NULL,         -- session clock
            end_ms INTEGER NOT NULL,
            s REAL NOT NULL,                   -- seconds into the chunk's audio
            e REAL NOT NULL,
            how TEXT NOT NULL,                 -- matched, interpolated, +onset
            PRIMARY KEY (session, chunk, i)
        )
        """,
        "CREATE INDEX words_time ON words(session, start_ms)",
        """
        CREATE TABLE events (
            id INTEGER PRIMARY KEY,
            session TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
            t INTEGER NOT NULL,                -- session clock
            kind TEXT NOT NULL,
            data TEXT NOT NULL                 -- the event's fields, JSON
        )
        """,
        "CREATE INDEX events_time ON events(session, t)",
        """
        CREATE TABLE markers (
            session TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
            n INTEGER NOT NULL,
            t INTEGER NOT NULL,                -- session clock
            at TEXT NOT NULL,                  -- the wall time, ISO 8601
            PRIMARY KEY (session, n)
        )
        """,
        """
        CREATE TABLE usage (
            id INTEGER PRIMARY KEY,
            at TEXT NOT NULL,                  -- when the call was made, ISO 8601 UTC
            session TEXT,
            chunk INTEGER,
            purpose TEXT NOT NULL,             -- words, times, bench
            model TEXT NOT NULL,
            audio_seconds REAL,
            cost REAL NOT NULL                 -- dollars, as OpenRouter reported them
        )
        """,
        "CREATE INDEX usage_at ON usage(at)",
    ]

    /// Versions of the schema, in order; `user_version` says how many ran.
    private static let versions: [[String]] = [
        schema,
        // A chunk's words come from the remote model and its times from the
        // local one.
        ["ALTER TABLE chunks RENAME COLUMN text_model TO remote_model",
         "ALTER TABLE chunks RENAME COLUMN time_source TO local_model"],
        // The sessions window shows what each session cost.
        ["CREATE INDEX usage_session ON usage(session)"],
    ]

    private static func migrate(_ h: Handle) throws {
        let have = h.rows("PRAGMA user_version").first?.int("user_version") ?? 0
        guard have < versions.count else { return }
        try h.transaction {
            for v in versions[have...] { for sql in v { try h.run(sql) } }
            try h.run("PRAGMA user_version = \(versions.count)")
        }
    }
}

/// The connection, inside one of the catalog's blocks.
struct Handle {
    let db: OpaquePointer

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    func run(_ sql: String, _ args: [Any?] = []) throws {
        let stmt = try prepare(sql, args)
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw error(sql) }
    }

    func rows(_ sql: String, _ args: [Any?] = []) -> [Row] {
        guard let stmt = try? prepare(sql, args) else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [Row] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            var values: [String: Any] = [:]
            for c in 0..<sqlite3_column_count(stmt) {
                let name = String(cString: sqlite3_column_name(stmt, c))
                switch sqlite3_column_type(stmt, c) {
                case SQLITE_INTEGER: values[name] = Int(sqlite3_column_int64(stmt, c))
                case SQLITE_FLOAT: values[name] = sqlite3_column_double(stmt, c)
                case SQLITE_TEXT: values[name] = String(cString: sqlite3_column_text(stmt, c))
                default: break
                }
            }
            out.append(Row(values: values))
        }
        return out
    }

    var lastID: Int { Int(sqlite3_last_insert_rowid(db)) }

    func transaction(_ body: () throws -> Void) throws {
        try run("BEGIN IMMEDIATE")
        do {
            try body()
            try run("COMMIT")
        } catch {
            try? run("ROLLBACK")
            throw error
        }
    }

    private func prepare(_ sql: String, _ args: [Any?]) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw error(sql) }
        for (i, a) in args.enumerated() {
            let at = Int32(i + 1)
            switch a {
            case nil: sqlite3_bind_null(stmt, at)
            case let v as Int: sqlite3_bind_int64(stmt, at, Int64(v))
            case let v as Double: sqlite3_bind_double(stmt, at, v)
            case let v as Bool: sqlite3_bind_int64(stmt, at, v ? 1 : 0)
            case let v as String: sqlite3_bind_text(stmt, at, v, -1, Handle.transient)
            default: sqlite3_bind_text(stmt, at, "\(a!)", -1, Handle.transient)
            }
        }
        return stmt
    }

    private func error(_ sql: String) -> Failure {
        Failure("sqlite: \(String(cString: sqlite3_errmsg(db))) in \(sql.prefix(60))")
    }
}

struct Row {
    let values: [String: Any]
    func int(_ k: String) -> Int? { values[k] as? Int }
    func real(_ k: String) -> Double? { values[k] as? Double ?? (values[k] as? Int).map(Double.init) }
    func text(_ k: String) -> String? { values[k] as? String }
}
