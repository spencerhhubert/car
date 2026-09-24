import AVFoundation
import Foundation

// The sound a session keeps: one file per chunk (the app's Mic.swift writes
// them), in the quality chosen in Settings, fixed for a session when it
// starts.
//
//   low      16 kHz mono AAC, 32 kbps: about 14 MB an hour. Enough for the
//            words, which is all transcription ever needs.
//   medium   48 kHz mono AAC, 160 kbps: about 70 MB an hour. As good as the
//            sound of most videos: good enough to publish.
//   high     48 kHz mono Apple Lossless, 24-bit: about 300 MB an hour, less
//            in a quiet room. The microphone exactly as it came.
//
// Transcription hears every quality at 16 kHz (`heard`), so a better one
// costs disk and nothing else. `export` joins a stretch of a session's
// chunks back into one file at the quality it was kept at, for using the
// sound somewhere else (the narration of a video).
public enum SoundQuality: String, Codable, CaseIterable, Sendable {
    case low, medium, high

    /// The rate it is kept at.
    public var rate: Double { self == .low ? 16000 : 48000 }

    /// What a chunk's file is written as (an `.m4a` either way).
    public var fileSettings: [String: Any] {
        switch self {
        case .low:
            [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
             AVEncoderBitRateKey: 32000]
        case .medium:
            [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
             AVEncoderBitRateKey: 160_000, AVEncoderAudioQualityKey: AVAudioQuality.max.rawValue]
        case .high:
            [AVFormatIDKey: kAudioFormatAppleLossless, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
             AVEncoderBitDepthHintKey: 24]
        }
    }

    /// "48 kHz, lossless"
    public var summary: String {
        switch self {
        case .low: "16 kHz, compressed"
        case .medium: "48 kHz, compressed"
        case .high: "48 kHz, lossless"
        }
    }

    /// "Low", "Medium", "High"
    public var name: String { rawValue.capitalized }

    /// What it is for, and what it costs: "good enough to publish, as in a
    /// video; about 70 MB an hour".
    public var purpose: String {
        switch self {
        case .low: "enough for the words, and small; about 14 MB an hour"
        case .medium: "good enough to publish, as in a video; about 70 MB an hour"
        case .high: "lossless, the microphone exactly as it came; about 300 MB an hour"
        }
    }
}

public enum Sound {
    /// The rate transcription hears sound at, whatever it was kept at.
    public static let heardRate = 16000.0

    /// A sound file as mono floats at `heardRate`. A file whose recording
    /// never finished (car stopped mid-chunk) cannot be read and throws.
    static func heard(_ url: URL) throws -> [Float] {
        let buf = try read(url)
        guard buf.format.sampleRate != heardRate || buf.format.channelCount != 1 else { return samples(buf) }
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: heardRate, channels: 1,
                                         interleaved: false),
              let converter = AVAudioConverter(from: buf.format, to: target),
              let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(
                  Double(buf.frameLength) * heardRate / buf.format.sampleRate) + 1024)
        else { throw Failure("cannot resample \(url.lastPathComponent)") }
        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        var handed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if handed { status.pointee = .endOfStream; return nil }
            handed = true
            status.pointee = .haveData
            return buf
        }
        if let err { throw err }
        return samples(out)
    }

    /// The whole file, at its own rate.
    private static func read(_ url: URL) throws -> AVAudioPCMBuffer {
        let file = try AVAudioFile(forReading: url)
        guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
        else { throw Failure("cannot read \(url.lastPathComponent)") }
        try file.read(into: buf)
        return buf
    }

    private static func samples(_ buf: AVAudioPCMBuffer) -> [Float] {
        guard let ch = buf.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: ch, count: Int(buf.frameLength)))
    }

    public struct Exported: Sendable {
        public let seconds: Double
        public let rate: Double
        /// Chunks whose sound is in the file, and chunks that could not be
        /// read (lost when car stopped mid-chunk, or still being recorded).
        public let chunks: Int
        public let unreadable: [Int]
    }

    /// Session `id`'s sound from `from` to `to` (session ms) as one file
    /// (WAV, AIFF or CAF, by its extension; 24-bit), each chunk at its place
    /// on the session clock and silence where nothing was recorded, at the
    /// rate the session kept its sound at.
    public static func export(_ id: String, from: Int, to: Int, into url: URL) throws -> Exported {
        let chunks = Session.chunks(id).filter { $0.startMs < to && ($0.endMs ?? .max) > from }
        guard !chunks.isEmpty else { throw Failure("no sound in \(id) between those moments") }
        var unreadable: [Int] = []
        var parts: [(n: Int, start: Int, buf: AVAudioPCMBuffer)] = []
        for c in chunks {
            guard let path = c.file.flatMap({ Session.path(file: $0) }), let buf = try? read(path) else {
                unreadable.append(c.n)
                continue
            }
            parts.append((c.n, c.startMs, buf))
        }
        guard let rate = parts.map({ $0.buf.format.sampleRate }).max() else {
            throw Failure("none of the sound between those moments can be read")
        }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)
        else { throw Failure("cannot make a \(Int(rate)) Hz file") }
        let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate,
                                                               AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 24,
                                                               AVLinearPCMIsFloatKey: false],
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let total = Int(Double(to - from) * rate / 1000)
        var written = 0
        /// Append `n` samples from `src` (nil: silence), a buffer at a time.
        func append(_ src: UnsafePointer<Float>?, _ n: Int) throws {
            var done = 0
            while done < n {
                let m = min(n - done, 1 << 16)
                guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(m)),
                      let dst = out.floatChannelData?[0] else { throw Failure("out of memory writing \(url.lastPathComponent)") }
                out.frameLength = AVAudioFrameCount(m)
                if let src { dst.update(from: src + done, count: m) } else { dst.update(repeating: 0, count: m) }
                try file.write(from: out)
                done += m
            }
            written += n
        }
        var used = 0
        for (n, start, buf) in parts {
            // A session keeps all its chunks at one quality.
            guard buf.format.sampleRate == rate, let ch = buf.floatChannelData?[0] else {
                unreadable.append(n)
                continue
            }
            used += 1
            let at = Int(Double(start - from) * rate / 1000)
            let skip = max(0, written - at)
            let n = min(Int(buf.frameLength) - skip, total - max(at, written))
            guard n > 0 else { continue }
            if at > written { try append(nil, at - written) }
            try append(ch + skip, n)
        }
        if written < total { try append(nil, total - written) }
        return Exported(seconds: Double(written) / rate, rate: rate, chunks: used, unreadable: unreadable.sorted())
    }
}
