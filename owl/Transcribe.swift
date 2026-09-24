import AVFoundation
import Foundation

// The pipeline that turns a finished session's sound into timed words.
//
//   1. the text model (OpenRouter) writes the words           -> transcript.txt
//   2. the time source stamps its own words with times
//   3. Align lays 1 onto 2; Refine snaps starts to onsets     -> words.json
//   4. Render writes the timeline                              -> session.md
//
// Times in words.json are milliseconds on the session clock, the same clock
// the events carry, so "the word 'here' at 01:23.417" and "the click at
// 01:23.400" are comparable without arithmetic. The audio's own clock is
// kept too (seconds into audio.m4a) for pulling a frame of the recording.
enum Transcribe {
    struct Options {
        var textModel: String
        var timeSource: String
        init(_ c: Config = .load()) { textModel = c.textModel; timeSource = c.timeSource }
    }

    struct Summary {
        var words = 0, matched = 0, onsets = 0
        var textModel = "", timeSource = ""
        var cost = 0.0
        var note = ""
    }

    /// Transcribe a session and record how it went in its state: done, or
    /// failed with the reason. The caller holds the session's lock.
    static func run(id: String, options: Options = Options()) async throws -> Summary {
        do {
            return try await transcribe(id: id, options: options)
        } catch {
            if var meta = Session.meta(id) {
                meta.state = .failed
                meta.error = error.localizedDescription
                try? Session.save(meta)
            }
            try? Render.write(id: id)
            throw error
        }
    }

    private static func transcribe(id: String, options: Options) async throws -> Summary {
        let dir = Session.dir(id)
        guard var meta = Session.meta(id) else { throw Failure("session \(id) has no meta.json") }
        let wasRecording = meta.status == .recording
        meta.state = .transcribing
        meta.error = nil
        try Session.save(meta)
        let audio = dir.appending(path: "audio.m4a")
        guard FileManager.default.fileExists(atPath: audio.path) else { throw Failure("session \(id) has no audio") }
        // A take owl never got to close (it stopped mid-recording) has no
        // index at the end of the file and cannot be read at all.
        guard let sound = try? AVAudioFile(forReading: audio) else {
            throw Failure(wasRecording ? "owl stopped while this session was recording; its sound was never finished"
                                       : "audio.m4a cannot be read")
        }
        let duration = meta.soundSeconds ?? Double(sound.length) / sound.fileFormat.sampleRate
        var summary = Summary()

        // 2, first: the timed words are needed whether or not a text model runs.
        let timed: [AppleTimes.Word]
        if options.timeSource.hasPrefix("openrouter:") {
            let model = String(options.timeSource.dropFirst("openrouter:".count))
            guard let key = Config.openRouterKey else { throw Failure("no OpenRouter key") }
            let (data, format) = try upload(audio)
            let (segs, cost) = try await OpenRouter.timedSegments(audio: data, format: format, model: model, key: key)
            timed = segmentsToWords(segs)
            summary.cost += cost ?? 0
        } else {
            timed = try await AppleTimes.words(url: audio)
        }
        summary.timeSource = options.timeSource

        // 1: the words. A chat model handed silence does not say so; it
        // writes a paragraph. So a take whose microphone never rose above
        // the floor is not sent, and an answer with more words than a person
        // can say in the time is thrown away.
        var text: String
        let peak = meta.peakDb ?? 0
        if peak < -60 {
            text = ""
            summary.textModel = "none"
            summary.note = String(format: "nothing heard (peak %.0f dB); the text model was not asked", peak)
        } else if let key = Config.openRouterKey {
            let (data, format) = try upload(audio)
            let (t, cost) = try await OpenRouter.transcribe(audio: data, format: format,
                                                            model: options.textModel, key: key)
            text = t
            summary.cost += cost ?? 0
            summary.textModel = options.textModel
            let n = t.split(whereSeparator: { $0.isWhitespace }).count
            if Double(n) > 4.5 * max(duration, 1) + 5 {
                text = ""
                summary.note = "\(options.textModel) returned \(n) words for \(Int(duration)) s of audio; discarded as invented"
            }
        } else {
            text = timed.map(\.text).joined(separator: " ")
            summary.textModel = "apple"
            summary.note = "no OpenRouter key; the on-device recognizer's words were used"
        }
        if text == "[no speech]" { text = "" }
        try text.write(to: dir.appending(path: "transcript.txt"), atomically: true, encoding: .utf8)

        // 3: align and refine.
        let tokens = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var words = Align.merge(text: tokens, timed: timed, duration: duration)
        if let env = try? Refine.envelope(url: audio) { Refine.onsets(&words, env: env) }
        Refine.monotonic(&words)
        summary.words = words.count
        summary.matched = words.filter { $0.how.hasPrefix("matched") }.count
        summary.onsets = words.filter { $0.how.hasSuffix("+onset") }.count
        // Words that line up with nothing the recognizer heard are not
        // verified by anything; say so rather than time them anyway.
        let unverified = summary.matched == 0 && words.count > 10 && !timed.isEmpty
        if unverified {
            summary.note = "no word of the transcript lines up with what the recognizer heard; treat it as unverified"
        }

        // Onto the session clock. The microphone's clock and the machine's
        // drift apart by parts per million; the ratio of wall time to sound
        // time over the take corrects it.
        let audioStart = meta.audioStartMs ?? 0
        let wall = meta.wallSeconds ?? duration
        var scale = duration > 0 ? wall / duration : 1
        if !(0.98...1.02).contains(scale) { scale = 1 }
        let out: [[String: Any]] = words.map {
            ["text": $0.text,
             "start": Int((audioStart + $0.start * 1000 * scale).rounded()),
             "end": Int((audioStart + $0.end * 1000 * scale).rounded()),
             "s": ($0.start * 1000).rounded() / 1000, "e": ($0.end * 1000).rounded() / 1000,
             "how": $0.how]
        }
        let doc: [String: Any] = ["session": id, "textModel": summary.textModel,
                                  "timeSource": summary.timeSource, "words": out,
                                  "matched": summary.matched, "onsets": summary.onsets,
                                  "clockScale": scale]
        try JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys])
            .write(to: dir.appending(path: "words.json"))
        meta.textModel = summary.textModel
        meta.timeSource = summary.timeSource
        meta.note = summary.note.isEmpty ? nil : summary.note
        meta.unverified = unverified ? true : nil
        meta.cost = (meta.cost ?? 0) + summary.cost
        meta.state = .done
        try Session.save(meta)

        // 4: the timeline.
        try Render.write(id: id)
        Log.line("transcribed \(id): \(summary.words) words, \(summary.matched) matched, \(summary.onsets) onsets, $\(summary.cost)")
        return summary
    }

    /// Compare a model's own sense of time against the on-device recognizer
    /// on one session: for every word both sources placed, the difference in
    /// start time. The methodology for judging a time source.
    static func bench(id: String, model: String) async throws -> String {
        let dir = Session.dir(id)
        let audio = dir.appending(path: "audio.m4a")
        guard let key = Config.openRouterKey else { throw Failure("no OpenRouter key") }
        let duration = Session.meta(id)?.soundSeconds ?? 0
        let text = (try? String(contentsOf: dir.appending(path: "transcript.txt"), encoding: .utf8)) ?? ""
        let tokens = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !tokens.isEmpty else { throw Failure("transcribe the session first") }
        let apple = try await AppleTimes.words(url: audio)
        let (data, format) = try upload(audio)
        let (segs, cost) = try await OpenRouter.timedSegments(audio: data, format: format, model: model, key: key)
        let theirs = segmentsToWords(segs)
        let a = Align.merge(text: tokens, timed: apple, duration: duration)
        let b = Align.merge(text: tokens, timed: theirs, duration: duration)
        var deltas: [Double] = []
        for (x, y) in zip(a, b) where x.how == "matched" && y.how == "matched" {
            deltas.append(abs(x.start - y.start) * 1000)
        }
        deltas.sort()
        func pct(_ p: Double) -> Double { deltas.isEmpty ? 0 : deltas[min(deltas.count - 1, Int(Double(deltas.count) * p))] }
        func within(_ ms: Double) -> Double { deltas.isEmpty ? 0 : Double(deltas.filter { $0 <= ms }.count) / Double(deltas.count) * 100 }
        return """
        bench \(id): \(model) vs apple, \(tokens.count) words, \(deltas.count) placed by both
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

    /// The bytes to send: a small mp3 when ffmpeg is installed, else the AAC
    /// file as recorded.
    static func upload(_ audio: URL) throws -> (Data, String) {
        let mp3 = audio.deletingLastPathComponent().appending(path: "audio.mp3")
        if !FileManager.default.fileExists(atPath: mp3.path) {
            for ff in ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
            where FileManager.default.isExecutableFile(atPath: ff) {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: ff)
                p.arguments = ["-y", "-loglevel", "error", "-i", audio.path, "-ac", "1", "-ar", "16000",
                               "-b:a", "24k", mp3.path]
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                try p.run()
                p.waitUntilExit()
                break
            }
        }
        if let data = try? Data(contentsOf: mp3), !data.isEmpty { return (data, "mp3") }
        return (try Data(contentsOf: audio), "m4a")
    }
}
