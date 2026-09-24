import AppKit
import AVFoundation
import CoreAudio
import CarKit

// The microphone, for as long as a session runs, as a run of chunks: mono
// files of about three minutes at the session's sound quality (CarKit's
// Sound.swift), each cut at a pause, so one is transcribed while the next
// records and a crash loses at most the one being written. A marker cuts the chunk on the spot. Each chunk's first sample is
// stamped on the session clock from the host time of the buffer it arrived
// in, so chunks line up with the events to the millisecond however long the
// session runs.
//
// It keeps itself going. A microphone that disappears or changes (headphones
// connecting), and the Mac going to sleep and waking, close the chunk and
// reopen the input: the chosen device, or the system default while that one
// is gone. So does a microphone that is open and sends nothing (another app
// took the camera it is part of): after `stall` seconds without a buffer it
// is reopened, and after two such tries the system default is used for the
// rest of the session, with a word to the person each time. The engine is
// started and stopped on the mic's own queue, since a Bluetooth input can
// take a second to open; nothing here waits on the main thread.
//
// AVAudioEngine rather than AVAudioRecorder so the input device can be chosen:
// on a Mac with headphones, a webcam and an interface plugged in, the system
// default is regularly not the one being talked into.
final class Mic: @unchecked Sendable {
    struct Chunk: Sendable {
        let n: Int
        let url: URL
        let rate: Double
        /// On `Clock`: the first sample, and the end of the last.
        let start: Double
        var end: Double
        var frames: Int64 = 0
        var peak: Float = -160
        var seconds: Double { Double(frames) / rate }
        var file: String { "audio/\(url.lastPathComponent)" }
    }

    /// A chunk is cut at the first pause after `length` seconds, and at
    /// `longest` whatever is being said. A pause is `pause` seconds under
    /// `quietDb`.
    static let length = 180.0
    static let longest = 240.0
    static let pause = 0.35
    static let quietDb: Float = -38
    /// Seconds an open input may go without sending sound.
    static let stall = 4.0

    private let onOpen: @Sendable (Chunk) -> Void
    private let onClose: @Sendable (Chunk) -> Void
    private let onTrouble: @Sendable (String) -> Void
    private let control = DispatchQueue(label: "car.mic")

    // Under `lock`, touched from the tap's thread.
    private let lock = NSLock()
    private var accepting = false
    private var current: (chunk: Chunk, file: AVAudioFile)?
    private var next = 1
    private var quiet = 0.0
    private var cutPending = false
    private var _level: Float = -160
    private var writeFailed = false
    /// When the last buffer arrived (system uptime).
    private var lastSound: TimeInterval = 0

    // On `control`.
    private var dir: URL?
    private var uid: String?
    private var quality = SoundQuality.low
    private var running = false
    private var engine: AVAudioEngine?
    private var engineWatch: NSObjectProtocol?
    private var sleepWatch: [NSObjectProtocol] = []
    private var lastOpen: TimeInterval = 0
    private var reopening = false
    private var watchdog: DispatchSourceTimer?
    /// Reopens because nothing arrived, since sound last did.
    private var stalls = 0
    /// The chosen device sent nothing: the system default from here on.
    private var fallBack = false

    init(onOpen: @escaping @Sendable (Chunk) -> Void, onClose: @escaping @Sendable (Chunk) -> Void,
         onTrouble: @escaping @Sendable (String) -> Void) {
        self.onOpen = onOpen
        self.onClose = onClose
        self.onTrouble = onTrouble
    }

    /// Latest level in dBFS.
    var level: Float { lock.withLock { _level } }

    static func requestPermission() async -> Bool {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized { return true }
        return await AVCaptureDevice.requestAccess(for: .audio)
    }

    static var permissionGranted: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }

    /// Start recording into `dir`, from the device with `uid` (nil: the
    /// system default), at `quality`.
    func start(into dir: URL, uid: String?, quality: SoundQuality) async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            control.async {
                self.dir = dir
                self.uid = uid
                self.quality = quality
                do {
                    try self.open()
                    self.running = true
                    self.watchSleep()
                    self.watchForSound()
                    done.resume()
                } catch {
                    done.resume(throwing: error)
                }
            }
        }
    }

    /// Close the chunk being written now; the next begins with the next sound.
    func cut() {
        lock.withLock { if current != nil { cutPending = true } }
    }

    /// Stop, closing the last chunk.
    func stop() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            control.async {
                self.running = false
                self.watchdog?.cancel()
                self.watchdog = nil
                for o in self.sleepWatch { NSWorkspace.shared.notificationCenter.removeObserver(o) }
                self.sleepWatch = []
                self.shut()
                done.resume()
            }
        }
    }

    // MARK: - the engine, on `control`

    private func open() throws {
        guard let dir else { return }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        // Set before the format is read: choosing the device changes the
        // format the node reports.
        let chosen = (fallBack ? nil : uid.flatMap { AudioInputs.device(withUID: $0)?.id }) ?? AudioInputs.systemDefault()
        if let unit = input.audioUnit, var id = chosen {
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                              &id, UInt32(MemoryLayout<AudioDeviceID>.size))
            if status != noErr { Log.line("could not select input \(id): OSStatus \(status)") }
        }
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw Failure("that microphone reports no channels") }
        let quality = quality
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: quality.rate, channels: 1,
                                         interleaved: false),
              let converter = AVAudioConverter(from: format, to: target) else {
            throw Failure("could not resample that microphone")
        }
        lock.withLock {
            accepting = true
            lastSound = ProcessInfo.processInfo.systemUptime
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, when in
            self?.consume(buffer, when, converter, target, quality, into: dir)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            lock.withLock { accepting = false }
            throw error
        }
        self.engine = engine
        // The engine says its input changed more often than it did: starting
        // on a Bluetooth microphone says so while the device settles. So a
        // change is looked at half a second later, and only an engine that
        // actually stopped is reopened.
        engineWatch = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                             object: engine, queue: nil) { [weak self] _ in
            self?.control.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, self.running, let e = self.engine, !e.isRunning else { return }
                self.reopen("the input changed")
            }
        }
        lastOpen = ProcessInfo.processInfo.systemUptime
        Log.line("mic open device=\(chosen.map(String.init) ?? "default") in=\(Int(format.sampleRate))Hz/\(format.channelCount)ch " +
                 "kept=\(quality.rawValue)")
    }

    /// Stop the engine and close the chunk. Releasing the engine is what
    /// releases the device: a live claim on a Bluetooth microphone keeps
    /// every app's sound in hands-free quality.
    private func shut() {
        if let engineWatch { NotificationCenter.default.removeObserver(engineWatch) }
        engineWatch = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        let closed = lock.withLock { () -> Chunk? in
            accepting = false
            return closeLocked()
        }
        if let closed { onClose(closed) }
    }

    private func reopen(_ why: String) {
        guard running, !reopening else { return }
        // Never more than once a second, and one waiting at a time, whatever
        // keeps asking.
        let wait = lastOpen + 1 - ProcessInfo.processInfo.systemUptime
        if wait > 0 {
            reopening = true
            control.asyncAfter(deadline: .now() + wait) { [weak self] in
                self?.reopening = false
                self?.reopen(why)
            }
            return
        }
        Log.line("mic reopening: \(why)")
        shut()
        do {
            try open()
        } catch {
            Log.line("mic did not reopen (\(error.localizedDescription)); trying again in 2 s")
            control.asyncAfter(deadline: .now() + 2) { [weak self] in self?.reopen("retry") }
        }
    }

    /// Sleep closes the chunk (the sound so far is safe and can be
    /// transcribed); waking opens the input again.
    private func watchSleep() {
        let center = NSWorkspace.shared.notificationCenter
        sleepWatch = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { [weak self] _ in
                self?.control.async { if self?.running == true { self?.shut() } }
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [weak self] _ in
                self?.control.async { self?.reopen("woke") }
            },
        ]
    }

    /// Every second or two, while open: has any sound come in lately?
    private func watchForSound() {
        let t = DispatchSource.makeTimerSource(queue: control)
        t.schedule(deadline: .now() + 2, repeating: 2, leeway: .milliseconds(500))
        t.setEventHandler { [weak self] in self?.checkForSound() }
        t.resume()
        watchdog = t
    }

    private func checkForSound() {
        guard running, engine != nil, !reopening else { return }
        let silent = ProcessInfo.processInfo.systemUptime - lock.withLock { lastSound }
        guard silent > Mic.stall else {
            if silent < 1 { stalls = 0 }
            return
        }
        stalls += 1
        // A microphone that stays dead is tried again twice a minute, not
        // every few seconds all day.
        guard stalls < 6 || stalls % 15 == 0 else { return }
        if stalls > 2, uid != nil, !fallBack {
            fallBack = true
            onTrouble("the microphone sends no sound; recording from the system default")
        } else if stalls == 1 {
            onTrouble("the microphone sends no sound; opening it again")
        }
        reopen("no sound for \(Int(silent)) s")
    }

    // MARK: - the sound, on the tap's thread

    private func consume(_ buffer: AVAudioPCMBuffer, _ when: AVAudioTime, _ converter: AVAudioConverter,
                         _ target: AVAudioFormat, _ quality: SoundQuality, into dir: URL) {
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate) + 128
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
        let arrived = when.isHostTimeValid ? Clock.fromHost(when.hostTime) : Clock.now
        let seconds = Double(out.frameLength) / target.sampleRate

        var opened: Chunk?
        var closed: Chunk?
        lock.withLock {
            _level = db
            lastSound = ProcessInfo.processInfo.systemUptime
            guard accepting else { return }
            if current == nil {
                let c = Chunk(n: next, url: dir.appending(path: String(format: "audio/%04d.m4a", next)),
                              rate: target.sampleRate, start: arrived, end: arrived)
                do {
                    let file = try AVAudioFile(forWriting: c.url, settings: quality.fileSettings,
                                               commonFormat: .pcmFormatFloat32, interleaved: false)
                    current = (c, file)
                    next += 1
                    quiet = 0
                    opened = c
                } catch {
                    if !writeFailed { Log.line("cannot write \(c.url.lastPathComponent): \(error.localizedDescription)") }
                    writeFailed = true
                    return
                }
            }
            guard let (chunk, file) = current else { return }
            var c = chunk
            do {
                try file.write(from: out)
            } catch {
                if !writeFailed { Log.line("audio write failed: \(error.localizedDescription)") }
                writeFailed = true
            }
            c.frames += Int64(out.frameLength)
            c.end = arrived + seconds
            c.peak = max(c.peak, db)
            current = (c, file)
            quiet = db < Mic.quietDb ? quiet + seconds : 0
            if cutPending || c.seconds >= Mic.longest || (c.seconds >= Mic.length && quiet >= Mic.pause) {
                closed = closeLocked()
            }
        }
        if let opened { onOpen(opened) }
        if let closed { onClose(closed) }
    }

    private func closeLocked() -> Chunk? {
        guard let (c, file) = current else { return nil }
        file.close()
        current = nil
        cutPending = false
        return c
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
