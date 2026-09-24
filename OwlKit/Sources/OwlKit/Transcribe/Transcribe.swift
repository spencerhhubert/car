import AVFoundation
import Foundation

// One chunk of a session's sound into timed words.
//
//   1. the on-device recognizer hears the chunk and stamps its own words
//      with times. It is free and local, so it goes first: a chunk it hears
//      no words in is silent, and nothing is sent anywhere.
//   2. the text model (OpenRouter) writes the words
//   3. Align lays 2 onto 1; Refine snaps starts to onsets
//   4. the words go into the catalog on the session clock
//
// Times are milliseconds on the session clock, the clock the events carry, so
// "the word 'here' at 01:23.417" and "the click at 01:23.400" compare without
// arithmetic. Each word also keeps its place in its chunk's file (s, e) for
// pulling that moment of sound. Chunks are transcribed by a Transcriber
// (Transcriber.swift), which holds the order and the session's state.
public enum Transcribe {
    public struct Options: Sendable {
        public var textModel: String
        public var timeSource: String
        public init(_ c: Config = .load()) {
            textModel = c.textModel
            timeSource = c.timeSource
        }
    }

    /// Transcribe chunk `n` of session `id` and store what came of it. Never
    /// throws: a chunk that cannot be transcribed is marked failed (or lost,
    /// when its file was never finished) with the reason. The caller holds
    /// the session's lock.
    @discardableResult
    static func chunk(_ id: String, _ n: Int, options: Options = Options()) async -> ChunkRecord.State {
        guard let c = Session.chunks(id).first(where: { $0.n == n }),
              let url = c.file.flatMap({ Session.path(file: $0) }) else {
            Log.line("\(id) chunk \(n): not in the catalog")
            return .failed
        }
        do {
            let state = try await words(id, c, url, options)
            return state
        } catch {
            store(id, n, state: .failed, error: error.localizedDescription)
            Log.line("\(id) chunk \(n) failed: \(error.localizedDescription)")
            return .failed
        }
    }

    private static func words(_ id: String, _ c: ChunkRecord, _ url: URL, _ options: Options) async throws
        -> ChunkRecord.State {
        // A chunk the recorder never closed (owl stopped mid-chunk) has no
        // index at the end of its file and cannot be read at all.
        guard let sound = try? AVAudioFile(forReading: url), sound.length > 0 else {
            store(id, c.n, state: .lost, note: "the recording stopped before this chunk was finished")
            return .lost
        }
        let duration = Double(sound.length) / sound.fileFormat.sampleRate

        // 1: the timed words, and whether anyone spoke.
        var cost = 0.0
        let timed: [AppleTimes.Word]
        if options.timeSource.hasPrefix("openrouter:") {
            let model = String(options.timeSource.dropFirst("openrouter:".count))
            guard let key = Config.openRouterKey else { throw Failure("no OpenRouter key") }
            let (segs, spent) = try await OpenRouter.timedSegments(audio: upload(url), model: model, key: key)
            Usage.record(session: id, chunk: c.n, purpose: "times", model: model, audioSeconds: duration, cost: spent ?? 0)
            cost += spent ?? 0
            timed = segmentsToWords(segs)
        } else {
            timed = try await AppleTimes.words(url: url)
        }
        guard !timed.isEmpty else {
            store(id, c.n, state: .silent, timeSource: options.timeSource, note: "no speech heard")
            return .silent
        }

        // 2: the words. An answer with more words than a person can say in
        // the time is a chat model inventing, and is thrown away.
        var text: String
        var textModel = "apple"
        var note: String?
        if let key = Config.openRouterKey {
            let (t, spent) = try await OpenRouter.transcribe(audio: upload(url), model: options.textModel, key: key)
            Usage.record(session: id, chunk: c.n, purpose: "words", model: options.textModel, audioSeconds: duration,
                         cost: spent ?? 0)
            cost += spent ?? 0
            text = t == "[no speech]" ? "" : t
            textModel = options.textModel
            let count = text.split(whereSeparator: { $0.isWhitespace }).count
            if Double(count) > 4.5 * max(duration, 1) + 5 {
                note = "\(options.textModel) returned \(count) words for \(Int(duration)) s; the on-device words were used"
                text = timed.map(\.text).joined(separator: " ")
                textModel = "apple"
            }
        } else {
            text = timed.map(\.text).joined(separator: " ")
            note = "no OpenRouter key; the on-device recognizer's words were used"
        }

        // 3: align and refine.
        let tokens = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var words = Align.merge(text: tokens, timed: timed, duration: duration)
        if let env = try? Refine.envelope(url: url) { Refine.onsets(&words, env: env) }
        Refine.monotonic(&words)
        if words.count > 10, !words.contains(where: { $0.how.hasPrefix("matched") }) {
            note = "no word of the transcript lines up with what the recognizer heard; treat it as unverified"
        }

        // 4: onto the session clock. The microphone's clock and the
        // machine's drift apart by parts per million; the ratio of the
        // chunk's span on the session clock to its sound corrects it.
        var scale = 1.0
        if let end = c.endMs, duration > 0 {
            let s = Double(end - c.startMs) / 1000 / duration
            if (0.98...1.02).contains(s) { scale = s }
        }
        let start = Double(c.startMs)
        let rows: [[Any?]] = words.enumerated().map { i, w in
            [id, c.n, i, w.text, Int((start + w.start * 1000 * scale).rounded()),
             Int((start + w.end * 1000 * scale).rounded()), w.start, w.end, w.how]
        }
        try Catalog.shared.sync { h in
            try h.transaction {
                try h.run("DELETE FROM words WHERE session = ? AND chunk = ?", [id, c.n])
                for r in rows {
                    try h.run("INSERT INTO words (session, chunk, i, text, start_ms, end_ms, s, e, how) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)", r)
                }
            }
        }
        store(id, c.n, state: .transcribed, textModel: textModel, timeSource: options.timeSource, note: note)
        Log.line("\(id) chunk \(c.n): \(words.count) words, $\(String(format: "%.4f", cost))")
        return .transcribed
    }

    private static func store(_ id: String, _ n: Int, state: ChunkRecord.State, textModel: String? = nil,
                              timeSource: String? = nil, note: String? = nil, error: String? = nil) {
        _ = try? Catalog.shared.sync { h in
            try h.run("""
                UPDATE chunks SET state = ?, text_model = COALESCE(?, text_model), time_source = COALESCE(?, time_source),
                    note = ?, error = ? WHERE session = ? AND n = ?
                """, [state.rawValue, textModel, timeSource, note, error, id, n])
        }
    }

    // MARK: - judging a time source

    /// Compare a model's own sense of time against the on-device recognizer
    /// on one chunk: for every word both placed, the difference in start
    /// time. The methodology for judging a time source.
    public static func bench(_ id: String, chunk n: Int, model: String) async throws -> String {
        guard let c = Session.chunks(id).first(where: { $0.n == n }), let url = c.file.flatMap({ Session.path(file: $0) })
        else { throw Failure("session \(id) has no chunk \(n)") }
        guard let key = Config.openRouterKey else { throw Failure("no OpenRouter key") }
        let tokens = Session.words(id).filter { $0.chunk == n }.map(\.text)
        guard !tokens.isEmpty else { throw Failure("transcribe the chunk first") }
        let duration = c.soundSeconds ?? 0
        let apple = try await AppleTimes.words(url: url)
        let (segs, cost) = try await OpenRouter.timedSegments(audio: upload(url), model: model, key: key)
        Usage.record(session: id, chunk: n, purpose: "bench", model: model, audioSeconds: duration, cost: cost ?? 0)
        let a = Align.merge(text: tokens, timed: apple, duration: duration)
        let b = Align.merge(text: tokens, timed: segmentsToWords(segs), duration: duration)
        var deltas: [Double] = []
        for (x, y) in zip(a, b) where x.how == "matched" && y.how == "matched" {
            deltas.append(abs(x.start - y.start) * 1000)
        }
        deltas.sort()
        func pct(_ p: Double) -> Double { deltas.isEmpty ? 0 : deltas[min(deltas.count - 1, Int(Double(deltas.count) * p))] }
        func within(_ ms: Double) -> Double {
            deltas.isEmpty ? 0 : Double(deltas.filter { $0 <= ms }.count) / Double(deltas.count) * 100
        }
        return """
        bench \(id) chunk \(n): \(model) vs apple, \(tokens.count) words, \(deltas.count) placed by both
          apple matched \(a.filter { $0.how == "matched" }.count), \(model) matched \(b.filter { $0.how == "matched" }.count)
          |Δ start|  median \(Int(pct(0.5))) ms   p90 \(Int(pct(0.9))) ms   max \(Int(deltas.last ?? 0)) ms
          within one frame (33 ms) \(String(format: "%.0f", within(33)))%   within 100 ms \(String(format: "%.0f", within(100)))%   within 500 ms \(String(format: "%.0f", within(500)))%
          segments \(segs.count), cost $\(String(format: "%.4f", cost ?? 0))
        """
    }

    /// A model's segments, cut into words that share each segment's time by
    /// length.
    static func segmentsToWords(_ segs: [OpenRouter.Segment]) -> [AppleTimes.Word] {
        var out: [AppleTimes.Word] = []
        for s in segs {
            let words = s.text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard !words.isEmpty else { continue }
            let total = max(s.end - s.start, 0.05)
            let chars = words.reduce(0) { $0 + max($1.count, 1) }
            var at = s.start
            for w in words {
                let share = total * Double(max(w.count, 1)) / Double(chars)
                out.append(AppleTimes.Word(text: w, start: at, end: at + share))
                at += share
            }
        }
        return out
    }

    /// The bytes to send: a small mp3 when ffmpeg is installed (made in a
    /// temporary file, not kept), else the AAC chunk as recorded.
    static func upload(_ audio: URL) throws -> OpenRouter.Audio {
        for ff in ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"] where FileManager.default.isExecutableFile(atPath: ff) {
            let mp3 = FileManager.default.temporaryDirectory.appending(path: "owl-\(UUID().uuidString).mp3")
            defer { try? FileManager.default.removeItem(at: mp3) }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: ff)
            p.arguments = ["-y", "-loglevel", "error", "-i", audio.path, "-ac", "1", "-ar", "16000", "-b:a", "24k", mp3.path]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
            if p.terminationStatus == 0, let data = try? Data(contentsOf: mp3), !data.isEmpty {
                return OpenRouter.Audio(data: data, format: "mp3")
            }
            break
        }
        return OpenRouter.Audio(data: try Data(contentsOf: audio), format: "m4a")
    }
}
