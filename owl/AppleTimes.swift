import AVFoundation
import Foundation
import Speech

// Word times from the on-device recognizer.
//
// Apple's SpeechAnalyzer stamps every run of its transcript with the audio
// time range it was heard in. Its words are not always the words (it misses
// names and mangles fillers), but its clock is real: each time comes from the
// sound, not from a model's guess about where in a file a sentence sits. So
// it is the default source of times, and the text model's words are laid onto
// it (see Align.swift).
enum AppleTimes {
    struct Word: Codable {
        let text: String
        /// Seconds into the audio.
        var start: Double
        var end: Double
    }

    static func words(url: URL) async throws -> [Word] {
        let transcriber = SpeechTranscriber(locale: Locale(identifier: "en_US"),
                                            transcriptionOptions: [],
                                            reportingOptions: [],
                                            attributeOptions: [.audioTimeRange])
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
