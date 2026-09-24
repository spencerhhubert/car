import AVFoundation
import CoreAudio
import Foundation

// The microphone, recorded to one 16 kHz mono AAC file per session.
//
// AVAudioEngine rather than AVAudioRecorder so the input device can be chosen:
// on a Mac with headphones, a webcam and an interface plugged in, the system
// default is regularly not the one being talked into, and the symptom is a
// file of silence with no error. The engine also hands the samples past on
// the way to disk, which is how the pill shows a live level.
final class Mic: @unchecked Sendable {
    struct Recording {
        let url: URL
        /// Wall seconds from engine start to stop.
        let wallSeconds: Double
        /// Seconds of sound written, by frame count.
        let soundSeconds: Double
        let peak: Float
        /// Uptime when the engine started, i.e. when sample 0 was heard, give
        /// or take the input's latency.
        let startedUptime: TimeInterval
    }

    private var engine: AVAudioEngine?
    private let lock = NSLock()
    private var file: AVAudioFile?
    /// Uptime when the engine started: sample 0, give or take the input's latency.
    private(set) var startedUptime: TimeInterval = 0
    private var startedAt: Date?
    private var peak: Float = -160
    private var wroteFrames: AVAudioFrameCount = 0
    private var running = false
    private var _level: Float = -160

    /// Latest level in dBFS.
    var level: Float { lock.lock(); defer { lock.unlock() }; return _level }
    var isRecording: Bool { lock.lock(); defer { lock.unlock() }; return running }
    var elapsed: Double {
        lock.lock(); defer { lock.unlock() }
        return startedAt.map { Date().timeIntervalSince($0) } ?? 0
    }

    static func requestPermission() async -> Bool {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized { return true }
        return await AVCaptureDevice.requestAccess(for: .audio)
    }

    static var permissionGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    func start(to dest: URL, deviceID: AudioDeviceID?) throws {
        guard !isRecording else { return }
        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode
        // Set before the format is read: choosing the device changes the
        // format the node reports.
        if let unit = input.audioUnit, var id = deviceID ?? AudioInputs.systemDefault() {
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                              kAudioUnitScope_Global, 0, &id,
                                              UInt32(MemoryLayout<AudioDeviceID>.size))
            if status != noErr { Log.line("could not select input \(id): OSStatus \(status)") }
        }
        let inputFormat = input.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            self.engine = nil
            throw Err.noInput
        }
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000,
                                         channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: target) else {
            self.engine = nil
            throw Err.noConverter
        }
        let f = try AVAudioFile(forWriting: dest,
                                settings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
                                           AVSampleRateKey: 16000.0,
                                           AVNumberOfChannelsKey: 1,
                                           AVEncoderBitRateKey: 32000],
                                commonFormat: .pcmFormatFloat32, interleaved: false)
        lock.lock()
        file = f
        peak = -160
        _level = -160
        wroteFrames = 0
        running = true
        lock.unlock()

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buf, _ in
            self?.consume(buf, converter: converter, target: target)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            lock.lock(); running = false; file = nil; lock.unlock()
            self.engine = nil
            try? FileManager.default.removeItem(at: dest)
            throw error
        }
        lock.lock()
        startedUptime = ProcessInfo.processInfo.systemUptime
        startedAt = Date()
        lock.unlock()
        Log.line("mic start device=\(deviceID.map(String.init) ?? "default") " +
                 "in=\(Int(inputFormat.sampleRate))Hz/\(inputFormat.channelCount)ch")
    }

    private func consume(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter,
                         target: AVAudioFormat) {
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 128
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var handed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if handed { status.pointee = .noDataNow; return nil }
            handed = true
            status.pointee = .haveData
            return buffer
        }
        guard err == nil, out.frameLength > 0, let samples = out.floatChannelData?[0] else { return }
        var loudest: Float = 0
        for i in 0..<Int(out.frameLength) { loudest = max(loudest, abs(samples[i])) }
        let db = loudest > 0 ? 20 * log10(loudest) : -160
        lock.lock()
        _level = db
        peak = max(peak, db)
        wroteFrames += out.frameLength
        let f = file
        lock.unlock()
        try? f?.write(from: out)
    }

    func stop() -> Recording? {
        lock.lock()
        guard running, let started = startedAt else { lock.unlock(); return nil }
        running = false
        let wall = Date().timeIntervalSince(started)
        let hitPeak = peak
        let frames = wroteFrames
        let url = file?.url
        let up = startedUptime
        file = nil
        startedAt = nil
        _level = -160
        lock.unlock()
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        // Releasing the engine is what releases the device: a live claim on a
        // Bluetooth microphone keeps every app's sound in hands-free quality.
        engine = nil
        guard let url else { return nil }
        Log.line(String(format: "mic stop %.2fs peak=%.1fdB frames=%u", wall, hitPeak, frames))
        return Recording(url: url, wallSeconds: wall, soundSeconds: Double(frames) / 16000,
                         peak: hitPeak, startedUptime: up)
    }

    enum Err: LocalizedError {
        case noInput, noConverter
        var errorDescription: String? {
            switch self {
            case .noInput: "that input reports no channels"
            case .noConverter: "could not resample that input"
            }
        }
    }
}

// Input devices by CoreAudio, with the UID that survives a reboot or replug.
enum AudioInputs {
    struct Device { let id: AudioDeviceID; let uid: String; let name: String }

    static func all() -> [Device] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr
        else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids.compactMap { id in
            guard inputChannels(id) > 0, let uid = string(id, kAudioDevicePropertyDeviceUID),
                  let name = string(id, kAudioObjectPropertyName) else { return nil }
            return Device(id: id, uid: uid, name: name)
        }
    }

    static func device(withUID uid: String) -> Device? { all().first { $0.uid == uid } }

    static func systemDefault() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr,
              id != 0 else { return nil }
        return id
    }

    private static func inputChannels(_ id: AudioDeviceID) -> Int {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                              mScope: kAudioObjectPropertyScopeInput,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = raw.assumingMemoryBound(to: AudioBufferList.self)
        return UnsafeMutableAudioBufferListPointer(list).reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: selector,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr,
              let s = value?.takeRetainedValue() else { return nil }
        return s as String
    }
}
