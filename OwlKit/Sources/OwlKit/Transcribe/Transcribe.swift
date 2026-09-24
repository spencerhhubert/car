import AVFoundation
import Foundation

// One chunk of a session's sound into timed words.
//
//   1. Voice (Voice.swift) finds where someone is talking, with no model. A
//      chunk with none is silent: nothing more runs and nothing is sent.
//   2. The voice alone is cut into one short clip, a moment of silence
//      between stretches, and the models only ever hear that.
//   3. The local model (LocalModel.swift, on this Mac, with a deadline) times
//      the words it hears.
//   4. The remote model (OpenRouter) writes the words, billed for the voice,
//      not the chunk, and capped at what a person could say in the time.
//   5. Align lays the remote words onto the local ones; without local times,
//      the words are spread over the voice by length. Refine snaps starts to
//      the onsets heard in the sound.
//   6. The words go into the catalog on the session clock.
//
// Either model can be missing ("none", or no key): the local model's words
// stand in for the remote's, and spreading stands in for the local times.
// Times are milliseconds on the session clock, the clock the events carry, so
// "the word 'here' at 01:23.417" and "the click at 01:23.400" compare without
// arithmetic. Each word keeps its place in its chunk's file too (s, e).
public enum Transcribe {
    public struct Options: Sendable {
        public var remoteModel: String
        public var localModel: String
        public init(_ c: Config = .load()) {
            remoteModel = c.remoteModel
            localModel = c.localModel
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
            return try await words(id, c, url, options)
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
        guard let (segments, samples, rate) = try? Voice.segments(url: url), !samples.isEmpty else {
            store(id, c.n, state: .lost, note: "the recording stopped before this chunk was finished")
            return .lost
        }
        // 1.
        guard !segments.isEmpty else {
            store(id, c.n, state: .silent, note: "no voice")
            return .silent
        }
        // 2.
        let clip = try Clip(segments, samples, rate)
        defer { clip.remove() }

        // 3.
        var timed: [LocalModel.Word] = []
        var notes: [String] = []
        if options.localModel == "apple" {
            do {
                timed = try await LocalModel.words(url: clip.url, deadline: 30 + clip.seconds).map(clip.onChunk)
            } catch {
                notes.append("no local times: \(error.localizedDescription)")
            }
        }

        // 4.
        var text = ""
        var remote: String?
        if !options.remoteModel.isEmpty, let key = Config.openRouterKey {
            let (t, spent) = try await OpenRouter.transcribe(audio: upload(clip.url), seconds: clip.seconds,
                                                             model: options.remoteModel, key: key)
            Usage.record(session: id, chunk: c.n, purpose: "words", model: options.remoteModel,
                         audioSeconds: clip.seconds, cost: spent ?? 0)
            let count = t.split(whereSeparator: { $0.isWhitespace }).count
            if Double(count) > 4.5 * max(clip.seconds, 1) + 5 {
                notes.append("\(options.remoteModel) returned \(count) words for \(Int(clip.seconds)) s of voice; discarded")
            } else {
                text = t == "[no speech]" ? "" : t
                remote = options.remoteModel
            }
        } else if !options.remoteModel.isEmpty {
            notes.append("no OpenRouter key")
        }
        if remote == nil { text = timed.map(\.text).joined(separator: " ") }
        let tokens = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !tokens.isEmpty else {
            // Voice, but no words in it: humming, a laugh, a cough.
            store(id, c.n, state: .silent, remoteModel: remote, localModel: timed.isEmpty ? nil : "apple",
                  note: (["voice, but no words"] + notes).joined(separator: "; "))
            return .silent
        }

        // 5.
        let duration = Double(samples.count) / rate
        var words = timed.isEmpty ? spread(tokens, over: segments)
                                  : Align.merge(text: tokens, timed: timed, duration: duration)
        Refine.onsets(&words, env: Refine.envelope(samples, rate: rate))
        Refine.monotonic(&words)
        if !timed.isEmpty, words.count > 10, !words.contains(where: { $0.how.hasPrefix("matched") }) {
            notes.append("no word lines up with what the local model heard; treat it as unverified")
        }

        // 6. Onto the session clock. The microphone's clock and the
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
        store(id, c.n, state: .transcribed, remoteModel: remote ?? "none",
              localModel: timed.isEmpty ? "none" : "apple", note: notes.isEmpty ? nil : notes.joined(separator: "; "))
        Log.line(String(format: "%@ chunk %d: %d words from %.0f of %.0f s of voice", id, c.n, words.count,
                        clip.seconds, duration))
        return .transcribed
    }

    /// Words with no local times, laid over the voice: each takes a share of
    /// the voiced time by its length, in order.
    static func spread(_ tokens: [String], over segments: [Voice.Segment]) -> [Align.Timed] {
        let voice = segments.reduce(0) { $0 + $1.length }
        let chars = tokens.reduce(0) { $0 + max($1.count, 1) }
        guard voice > 0, chars > 0 else { return [] }
        func at(_ v: Double) -> Double {
            var left = v
            for s in segments {
                if left <= s.length { return s.start + left }
                left -= s.length
            }
            return segments.last!.end
        }
        var done = 0
        return tokens.map { t in
            let a = voice * Double(done) / Double(chars)
            done += max(t.count, 1)
            let b = voice * Double(done) / Double(chars)
            return Align.Timed(text: t, start: at(a), end: at(b), how: "spread")
        }
    }

    private static func store(_ id: String, _ n: Int, state: ChunkRecord.State, remoteModel: String? = nil,
                              localModel: String? = nil, note: String? = nil, error: String? = nil) {
        _ = try? Catalog.shared.sync { h in
            try h.run("""
                UPDATE chunks SET state = ?, remote_model = ?, local_model = ?, note = ?, error = ?
                WHERE session = ? AND n = ?
                """, [state.rawValue, remoteModel, localModel, note, error, id, n])
        }
    }

    // MARK: - judging a remote model's clock

    /// Compare a remote model's own sense of time against the local model on
    /// one chunk: for every word both placed, the difference in start time.
    public static func bench(_ id: String, chunk n: Int, model: String) async throws -> String {
        guard let c = Session.chunks(id).first(where: { $0.n == n }), let url = c.file.flatMap({ Session.path(file: $0) })
        else { throw Failure("session \(id) has no chunk \(n)") }
        guard let key = Config.openRouterKey else { throw Failure("no OpenRouter key") }
        let tokens = Session.words(id).filter { $0.chunk == n }.map(\.text)
        guard !tokens.isEmpty else { throw Failure("transcribe the chunk first") }
        let duration = c.soundSeconds ?? 0
        let local = try await LocalModel.words(url: url, deadline: 60 + duration)
        let (segs, cost) = try await OpenRouter.timedSegments(audio: upload(url), seconds: duration, model: model, key: key)
        Usage.record(session: id, chunk: n, purpose: "bench", model: model, audioSeconds: duration, cost: cost ?? 0)
        let a = Align.merge(text: tokens, timed: local, duration: duration)
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
        bench \(id) chunk \(n): \(model) vs the local model, \(tokens.count) words, \(deltas.count) placed by both
          local matched \(a.filter { $0.how == "matched" }.count), \(model) matched \(b.filter { $0.how == "matched" }.count)
          |Δ start|  median \(Int(pct(0.5))) ms   p90 \(Int(pct(0.9))) ms   max \(Int(deltas.last ?? 0)) ms
          within one frame (33 ms) \(String(format: "%.0f", within(33)))%   within 100 ms \(String(format: "%.0f", within(100)))%   within 500 ms \(String(format: "%.0f", within(500)))%
          segments \(segs.count), cost $\(String(format: "%.4f", cost ?? 0))
        """
    }

    /// A model's segments, cut into words that share each segment's time by
    /// length.
    static func segmentsToWords(_ segs: [OpenRouter.Segment]) -> [LocalModel.Word] {
        var out: [LocalModel.Word] = []
        for s in segs {
            let words = s.text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard !words.isEmpty else { continue }
            let total = max(s.end - s.start, 0.05)
            let chars = words.reduce(0) { $0 + max($1.count, 1) }
            var at = s.start
            for w in words {
                let share = total * Double(max(w.count, 1)) / Double(chars)
                out.append(LocalModel.Word(text: w, start: at, end: at + share))
                at += share
            }
        }
        return out
    }

    /// The bytes to send: a small mp3 when ffmpeg is installed (made in a
    /// temporary file, not kept), else the file as it is.
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
        return OpenRouter.Audio(data: try Data(contentsOf: audio), format: audio.pathExtension == "wav" ? "wav" : "m4a")
    }
}

/// The voice of a chunk alone, as one short file: its segments one after
/// another with a moment of silence between, and the way back from a time in
/// the clip to a time in the chunk.
struct Clip {
    static let gap = 0.3
    let url: URL
    let seconds: Double
    /// Where each segment starts in the clip, and the segment.
    private let placed: [(at: Double, segment: Voice.Segment)]

    init(_ segments: [Voice.Segment], _ samples: [Float], _ rate: Double) throws {
        var out: [Float] = []
        var placed: [(Double, Voice.Segment)] = []
        let silence = [Float](repeating: 0, count: Int(Clip.gap * rate))
        for s in segments {
            if !out.isEmpty { out += silence }
            placed.append((Double(out.count) / rate, s))
            let a = max(0, Int(s.start * rate)), b = min(samples.count, Int(s.end * rate))
            if b > a { out += samples[a..<b] }
        }
        self.placed = placed
        seconds = Double(out.count) / rate
        url = FileManager.default.temporaryDirectory.appending(path: "owl-voice-\(UUID().uuidString).wav")
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(out.count))
        else { throw Failure("cannot make the voice clip") }
        buf.frameLength = AVAudioFrameCount(out.count)
        out.withUnsafeBufferPointer { src in buf.floatChannelData![0].update(from: src.baseAddress!, count: out.count) }
        let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM,
                                                              AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
                                                              AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false],
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buf)
    }

    /// A time in the clip, as a time in the chunk.
    func chunkTime(_ t: Double) -> Double {
        guard let p = placed.last(where: { $0.at <= t }) ?? placed.first else { return t }
        return p.segment.start + min(max(0, t - p.at), p.segment.length)
    }

    func onChunk(_ w: LocalModel.Word) -> LocalModel.Word {
        LocalModel.Word(text: w.text, start: chunkTime(w.start), end: chunkTime(w.end))
    }

    func remove() { try? FileManager.default.removeItem(at: url) }
}
