import Foundation

// One session is one folder:
//
//   sessions/<id>/
//     meta.json        what the session is: when, how long, its state, which
//                      models read it (`Meta`)
//     events.jsonl     what happened, one event per line, `t` in ms from the
//                      session start on a monotonic clock
//     audio.m4a        the microphone, 16 kHz mono AAC
//     shots/<t>.jpg    what the screen looked like at that moment
//     transcript.txt   the words, from the text model
//     words.json       every word with its start and end in ms on the session
//                      clock, and how that time was found
//     session.md       the timeline, words and events interleaved, for a
//                      person or an agent to read
//     .lock            held by the process recording or transcribing it
//
// A session is recording, then transcribing, then done or failed. The state
// is in meta.json and the lock says whether anyone is still at it: a session
// left recording or transcribing with its lock free was orphaned by a crash or
// a quit, and whoever finds it (the app at launch, `owl session` asked for
// it) finishes it. The lock is an flock, so the kernel lets go of it when its
// holder dies, however it dies.
//
// The id is the local start time, so `ls` sorts sessions chronologically.
final class Session: @unchecked Sendable {
    let id: String
    let dir: URL
    let startedAt: Date
    /// Uptime at start; every `t` is measured from it.
    let t0: TimeInterval
    let lock: SessionLock
    /// Changed only on the main thread, through `update`.
    private(set) var meta: Meta
    private let events: FileHandle
    private let mutex = NSLock()
    private var open = true
    private var written = 0

    init() throws {
        startedAt = Date()
        t0 = ProcessInfo.processInfo.systemUptime
        (id, dir) = try Session.makeFolder(for: startedAt)
        guard let lock = SessionLock(dir) else { throw Failure("could not lock \(dir.path)") }
        self.lock = lock
        try FileManager.default.createDirectory(at: dir.appending(path: "shots"), withIntermediateDirectories: true)
        let path = dir.appending(path: "events.jsonl")
        FileManager.default.createFile(atPath: path.path, contents: nil)
        events = try FileHandle(forWritingTo: path)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        iso.timeZone = .current
        meta = Meta(id: id, startedAt: iso.string(from: startedAt), timeZone: TimeZone.current.identifier,
                    state: .recording)
        try Session.save(meta)
    }

    /// Milliseconds since the session started, now.
    var now: Int { Int((ProcessInfo.processInfo.systemUptime - t0) * 1000) }

    var count: Int { mutex.withLock { written } }

    /// Append one event. `fields` must be JSON-encodable. An event that
    /// arrives after the session closed (a picture still being taken when
    /// the key went up) is dropped.
    func event(_ kind: String, _ fields: [String: Any] = [:], at t: Int? = nil) {
        var obj = fields
        obj["t"] = t ?? now
        obj["kind"] = kind
        guard var data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes])
        else { Log.line("event \(kind) is not JSON; dropped"); return }
        data.append(0x0A)
        mutex.withLock {
            guard open else { return }
            do {
                try events.write(contentsOf: data)
                written += 1
            } catch {
                Log.line("events.jsonl write failed: \(error.localizedDescription)")
            }
        }
    }

    func update(_ change: (inout Meta) -> Void) {
        change(&meta)
        do { try Session.save(meta) } catch { Log.line("meta.json write failed: \(error.localizedDescription)") }
    }

    /// No more events: the session is over and waiting to be transcribed.
    func close() {
        let n = shut()
        update {
            $0.events = n
            $0.seconds = Double(now) / 1000
            $0.state = .transcribing
        }
    }

    /// Throw the session away: the X on the pill.
    func remove() {
        shut()
        try? FileManager.default.removeItem(at: dir)
        lock.release()
    }

    @discardableResult
    private func shut() -> Int {
        mutex.withLock {
            if open { try? events.close() }
            open = false
            return written
        }
    }

    private static func makeFolder(for date: Date) throws -> (String, URL) {
        try FileManager.default.createDirectory(at: Config.sessionsDir, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let base = f.string(from: date)
        // Two sessions can start inside one second now that a new one does
        // not wait for the last to be transcribed.
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

    static func list() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: Config.sessionsDir.path)) ?? [])
            .filter { !$0.hasPrefix(".") }.sorted()
    }

    static func dir(_ id: String) -> URL { Config.sessionsDir.appending(path: id) }

    static func meta(_ id: String) -> Meta? {
        guard let data = try? Data(contentsOf: dir(id).appending(path: "meta.json")) else { return nil }
        do {
            return try JSONDecoder().decode(Meta.self, from: data)
        } catch {
            Log.line("\(id)/meta.json unreadable: \(error.localizedDescription)")
            return nil
        }
    }

    static func save(_ meta: Meta) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try enc.encode(meta).write(to: dir(meta.id).appending(path: "meta.json"), options: .atomic)
    }

    /// Every event, in the order of the clock. The file is in the order the
    /// events were written, which is not quite the same: a picture is written
    /// when it has been taken, a click once what was clicked has been read.
    static func events(_ id: String) -> [[String: Any]] {
        guard let text = try? String(contentsOf: dir(id).appending(path: "events.jsonl"), encoding: .utf8)
        else { return [] }
        let all = text.split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
        return all.enumerated().sorted {
            let (a, b) = ($0.element["t"] as? Int ?? 0, $1.element["t"] as? Int ?? 0)
            return a != b ? a < b : $0.offset < $1.offset
        }.map(\.element)
    }
}

/// meta.json. Everything past the id is optional: a session is written a
/// piece at a time, and a crash can stop it anywhere.
struct Meta: Codable {
    enum State: String, Codable { case recording, transcribing, done, failed }

    var id: String
    var startedAt: String?
    var timeZone: String?
    /// Missing in sessions from before there were states; those are done.
    var state: State?
    /// Length on the session clock.
    var seconds: Double?
    var events: Int?
    var marks: Int?
    var input: String?
    /// Where sample 0 of audio.m4a falls on the session clock.
    var audioStartMs: Double?
    var wallSeconds: Double?
    var soundSeconds: Double?
    var peakDb: Double?
    var textModel: String?
    var timeSource: String?
    var cost: Double?
    var note: String?
    var unverified: Bool?
    /// Why the transcription failed, when it did.
    var error: String?

    var status: State { state ?? .done }

    var started: Date? {
        guard let startedAt else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: startedAt) { return d }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: startedAt)
    }
}

/// The advisory lock on a session folder. Whoever holds it is recording or
/// transcribing the session; the kernel releases it if the holder dies.
final class SessionLock: @unchecked Sendable {
    private var fd: Int32
    private let mutex = NSLock()

    /// Takes the lock, or nil when someone else has it.
    init?(_ dir: URL) {
        let fd = Darwin.open(dir.appending(path: ".lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(fd)
            return nil
        }
        self.fd = fd
    }

    func release() {
        mutex.withLock {
            guard fd >= 0 else { return }
            Darwin.close(fd)
            fd = -1
        }
    }

    deinit { release() }

    /// Whether someone is at the session now.
    static func isHeld(_ dir: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: dir.path) else { return false }
        guard let probe = SessionLock(dir) else { return true }
        probe.release()
        return false
    }
}
