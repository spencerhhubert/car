import AVFoundation
import Foundation
import Speech

// The local model: Apple's on-device recognizer. Middling words, but a real
// clock (each run of its transcript carries the audio range it was heard in),
// free, and nothing leaves the Mac. It times the remote model's words, and
// writes the words itself when there is no remote model.
//
// It is the one piece owl does not control, and it can stall: fetching its
// language model has hung for minutes. So it is asked with a deadline, and a
// chunk whose local model did not answer still gets its words (spread over
// the voice, see Transcribe.swift) rather than waiting on it.
enum LocalModel {
    struct Word: Codable {
        let text: String
        /// Seconds into the audio.
        var start: Double
        var end: Double
    }

    /// Timed words for the file, or a Failure once `deadline` seconds pass.
    static func words(url: URL, deadline: TimeInterval) async throws -> [Word] {
        try await within(deadline, "the on-device recognizer") { try await recognize(url) }
    }

    private static func recognize(_ url: URL) async throws -> [Word] {
        let transcriber = SpeechTranscriber(locale: Locale(identifier: "en_US"), transcriptionOptions: [],
                                            reportingOptions: [], attributeOptions: [.audioTimeRange])
        if let req = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await req.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let file = try AVAudioFile(forReading: url)
        let collector = Task {
            var out: [Word] = []
            for try await result in transcriber.results where result.isFinal {
                out.append(contentsOf: split(result.text))
            }
            return out
        }
        if let last = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await collector.value.sorted { $0.start < $1.start }
    }

    /// One attributed run may hold several words; each word takes a share of
    /// the run's time by its length.
    private static func split(_ text: AttributedString) -> [Word] {
        var out: [Word] = []
        for run in text.runs {
            guard let range = run[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self] else { continue }
            let s = String(text[run.range].characters)
            let words = s.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard !words.isEmpty else { continue }
            let start = range.start.seconds
            let total = max(range.duration.seconds, 0.02)
            let chars = words.reduce(0) { $0 + max($1.count, 1) }
            var at = start
            for w in words {
                let share = total * Double(max(w.count, 1)) / Double(chars)
                out.append(Word(text: w, start: at, end: at + share))
                at += share
            }
        }
        return out
    }
}

/// Run `work`, or give up on it after `seconds`. The work is left to finish
/// on its own if it ever does: something stuck in a system framework cannot
/// be cancelled, only stopped being waited on.
func within<T: Sendable>(_ seconds: TimeInterval, _ what: String,
                         _ work: @escaping @Sendable () async throws -> T) async throws -> T {
    let once = Once<T>()
    return try await withCheckedThrowingContinuation { (c: CheckedContinuation<T, Error>) in
        once.set(c)
        Task {
            do { once.resume(.success(try await work())) } catch { once.resume(.failure(error)) }
        }
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            once.resume(.failure(Failure("\(what) did not answer in \(Int(seconds)) s")))
        }
    }
}

private final class Once<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var c: CheckedContinuation<T, Error>?
    func set(_ c: CheckedContinuation<T, Error>) { lock.withLock { self.c = c } }
    func resume(_ r: Result<T, Error>) {
        let c = lock.withLock { () -> CheckedContinuation<T, Error>? in
            defer { self.c = nil }
            return self.c
        }
        c?.resume(with: r)
    }
}
