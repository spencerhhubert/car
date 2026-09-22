import Foundation

// One session is one folder:
//
//   sessions/<id>/
//     meta.json        when it ran, how long, where the sound starts on the
//                      session clock, which models read it
//     events.jsonl     what happened, one event per line, `t` in ms from the
//                      session start on a monotonic clock
//     audio.m4a        the microphone, 16 kHz mono AAC
//     shots/<t>.jpg    what the focused window looked like at that moment
//     transcript.txt   the words, from the text model
//     words.json       every word with its start and end in ms on the session
//                      clock, and how that time was found
//     session.md       the timeline, words and events interleaved, for a
//                      person or an agent to read
//
// The id is the local start time, so `ls` sorts sessions chronologically.
final class Session {
    let id: String
    let dir: URL
    let startedAt: Date
    /// Uptime at start; every `t` is measured from it.
    let t0: TimeInterval
    private let events: FileHandle
    private let lock = NSLock()
    private(set) var count = 0
    var meta: [String: Any]

    static func newID(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: date)
    }

    init() throws {
        startedAt = Date()
        id = Session.newID(startedAt)
        dir = Config.sessionsDir.appending(path: id)
        t0 = ProcessInfo.processInfo.systemUptime
        try FileManager.default.createDirectory(at: dir.appending(path: "shots"),
                                                withIntermediateDirectories: true)
        let path = dir.appending(path: "events.jsonl")
        FileManager.default.createFile(atPath: path.path, contents: nil)
        events = try FileHandle(forWritingTo: path)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds, .withTimeZone]
        iso.timeZone = .current
        meta = ["id": id, "startedAt": iso.string(from: startedAt),
                "timeZone": TimeZone.current.identifier]
        saveMeta()
    }

    /// Milliseconds since the session started, now.
    var now: Int { Int((ProcessInfo.processInfo.systemUptime - t0) * 1000) }

    /// Append one event. `fields` must be JSON-encodable.
    func event(_ kind: String, _ fields: [String: Any] = [:], at t: Int? = nil) {
        var obj = fields
        obj["t"] = t ?? now
        obj["kind"] = kind
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              var line = String(data: data, encoding: .utf8) else { return }
        line.append("\n")
        lock.lock()
        defer { lock.unlock() }
        events.write(line.data(using: .utf8)!)
        count += 1
    }

    func saveMeta() {
        guard let data = try? JSONSerialization.data(withJSONObject: meta,
                                                     options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? data.write(to: dir.appending(path: "meta.json"))
    }

    func close() {
        meta["events"] = count
        meta["seconds"] = Double(now) / 1000
        saveMeta()
        try? events.close()
    }

    // MARK: - reading a finished session back

    static func list() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: Config.sessionsDir.path)) ?? [])
            .filter { !$0.hasPrefix(".") }.sorted()
    }

    static func dir(_ id: String) -> URL { Config.sessionsDir.appending(path: id) }

    static func meta(_ id: String) -> [String: Any] {
        guard let data = try? Data(contentsOf: dir(id).appending(path: "meta.json")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }

    static func events(_ id: String) -> [[String: Any]] {
        guard let text = try? String(contentsOf: dir(id).appending(path: "events.jsonl"), encoding: .utf8)
        else { return [] }
        return text.split(separator: "\n").compactMap {
            guard let d = $0.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
        }
    }
}
