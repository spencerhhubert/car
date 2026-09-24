import AVFoundation
import Foundation
import Testing
@testable import CarKit

/// Chunks written the way the microphone writes them, at each quality, heard
/// the way transcription hears them and joined the way `car audio` joins them.
@Suite(.serialized) struct SoundTests {
    init() { _ = testRoot }

    /// `seconds` of the voice-like test sound at `rate`, written as a chunk
    /// at `quality`.
    static func chunk(_ url: URL, _ quality: SoundQuality, seconds: Double, voice: [(Double, Double)]) throws {
        let rate = quality.rate
        // VoiceTests' sound is made at 16 kHz; make it at this rate instead.
        var g = SystemRandomNumberGenerator()
        let samples: [Float] = (0..<Int(seconds * rate)).map { i in
            let t = Double(i) / rate
            var x = Float.random(in: -1...1, using: &g) * 0.003
            if voice.contains(where: { t >= $0.0 && t < $0.1 }) {
                let f0 = 140 * (1 + 0.05 * sin(2 * .pi * 3 * t))
                var v = 0.0
                for h in 1...8 { v += sin(2 * .pi * f0 * Double(h) * t) / Double(h) }
                x += Float(v) * 0.05
            }
            return x
        }
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false))
        let buf = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let file = try AVAudioFile(forWriting: url, settings: quality.fileSettings, commonFormat: .pcmFormatFloat32,
                                   interleaved: false)
        try file.write(from: buf)
    }

    @Test(arguments: SoundQuality.allCases)
    func everyQualityIsHeardAtSixteenKilohertz(_ q: SoundQuality) throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "car-sound-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        try Self.chunk(url, q, seconds: 6, voice: [(2, 3.5)])
        #expect(try AVAudioFile(forReading: url).fileFormat.sampleRate == q.rate)

        let (segments, samples, rate) = try Voice.segments(url: url)
        #expect(rate == Sound.heardRate)
        #expect(abs(Double(samples.count) / rate - 6) < 0.1)
        #expect(segments.count == 1)
        if let s = segments.first {
            #expect(abs(s.start - (2 - Voice.pad)) < 0.12 && abs(s.end - (3.5 + Voice.pad)) < 0.12)
        }
    }

    @Test func higherQualitiesKeepMore() throws {
        var bytes: [SoundQuality: Int] = [:]
        for q in SoundQuality.allCases {
            let url = FileManager.default.temporaryDirectory.appending(path: "car-sound-\(UUID().uuidString).m4a")
            defer { try? FileManager.default.removeItem(at: url) }
            try Self.chunk(url, q, seconds: 4, voice: [(0.5, 3.5)])
            bytes[q] = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int
        }
        #expect(bytes[.low]! < bytes[.medium]! && bytes[.medium]! < bytes[.high]!)
    }

    @Test func aStretchIsJoinedAtItsPlacesOnTheClock() throws {
        let s = try Session(input: "test mic")
        defer { s.remove() }
        // Two chunks at 1 s and at 6 s on the session clock, 3 s each: the
        // gap between them is silence in the file.
        try Self.chunk(s.dir.appending(path: "audio/0001.m4a"), .high, seconds: 3, voice: [(0, 3)])
        try Self.chunk(s.dir.appending(path: "audio/0002.m4a"), .high, seconds: 3, voice: [(0, 3)])
        s.chunkOpened(1, file: "audio/0001.m4a", start: s.t0 + 1)
        s.chunkClosed(1, file: "audio/0001.m4a", end: s.t0 + 4, seconds: 3, peakDb: -12)
        s.chunkOpened(2, file: "audio/0002.m4a", start: s.t0 + 6)
        s.chunkClosed(2, file: "audio/0002.m4a", end: s.t0 + 9, seconds: 3, peakDb: -12)
        Session.flush()

        let out = FileManager.default.temporaryDirectory.appending(path: "car-export-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: out) }
        let e = try Sound.export(s.id, from: 2000, to: 8000, into: out)
        #expect(e.chunks == 2 && e.unreadable.isEmpty && e.rate == 48000)
        #expect(abs(e.seconds - 6) < 0.001)

        let file = try AVAudioFile(forReading: out)
        #expect(file.fileFormat.sampleRate == 48000 && file.length == 6 * 48000)
        let buf = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buf)
        let x = buf.floatChannelData![0]
        func loud(_ from: Double, _ to: Double) -> Float {
            var peak: Float = 0
            for i in Int(from * 48000)..<Int(to * 48000) { peak = max(peak, abs(x[i])) }
            return peak
        }
        // 2–4 s of the session is the first chunk, 4–6 s nothing, 6–8 s the second.
        #expect(loud(0.1, 1.9) > 0.01)
        #expect(loud(2.1, 3.9) == 0)
        #expect(loud(4.1, 5.9) > 0.01)
    }
}
