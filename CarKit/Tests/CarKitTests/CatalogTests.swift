import Foundation
import Testing
@testable import CarKit

/// A session written the way the app writes one, read back the way the
/// command reads one.
@Suite(.serialized) struct CatalogTests {
    init() { _ = testRoot }

    @Test func aSessionGoesInAndComesBackOut() throws {
        let s = try Session(input: "test mic")
        defer { s.remove() }
        s.event("app", ["app": "Safari", "bundle": "com.apple.Safari"], at: 100)
        s.chunkOpened(1, url: s.dir.appending(path: "audio/0001.m4a"), store: "local", start: s.t0 + 0.2)
        s.chunkClosed(1, url: s.dir.appending(path: "audio/0001.m4a"), end: s.t0 + 5.2, seconds: 5, peakDb: -12)
        let m = try s.marker()
        Session.flush()

        let record = try #require(Session.record(s.id))
        #expect(record.state == .recording && record.input == "test mic")
        let chunks = Session.chunks(s.id)
        #expect(chunks.count == 1 && chunks[0].state == .recorded && chunks[0].startMs == 200 && chunks[0].endMs == 5200)
        #expect(Session.path(file: chunks[0].file!)?.path == s.dir.appending(path: "audio/0001.m4a").path)
        #expect(Session.markers(s.id).map(\.n) == [m.n])
        #expect(Session.events(s.id).first?["app"] as? String == "Safari")
        #expect(Render.text(id: s.id).contains("▶ marker 1, set at"))

        s.close()
        Session.flush()
        #expect(Session.record(s.id)?.state == .transcribing)
        #expect(SessionLock.isHeld(s.dir))
    }

    @Test func filesGoToTheRecordingsFolderWhileItIsThere() throws {
        let drive = FileManager.default.temporaryDirectory.appending(path: "car-drive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: drive) }
        let s = try Session(input: "test mic", recordings: drive)
        defer { s.remove() }
        let moves = Moves()
        s.onMove = { moves.add($0) }

        // There: the sound goes to the drive, and the catalog finds it there.
        let there = s.place("audio")
        #expect(there.store == drive.path && there.dir.path == drive.appending(path: "\(s.id)/audio").path)
        let url = there.dir.appending(path: "0001.m4a")
        try Data(count: 10).write(to: url)
        s.chunkOpened(1, url: url, store: there.store, start: s.t0)
        Session.flush()
        let file = try #require(Session.chunks(s.id).first?.file)
        #expect(Session.path(file: file)?.path == url.path)
        #expect(Session.folders(s.id).map(\.path).contains(drive.appending(path: s.id).path))

        // Unplugged: this Mac, and never a folder made where the drive was.
        try FileManager.default.removeItem(at: drive)
        let here = s.place("shots")
        #expect(here.store == "local" && here.dir.path == s.dir.appending(path: "shots").path)
        #expect(!FileManager.default.fileExists(atPath: drive.path))

        // Back: the drive again.
        try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
        #expect(s.place("shots").store == drive.path)
        #expect(moves.all == [true, false, true])
    }

    @Test func aRecordingsFolderThatIsNotThereIsNeverMade() throws {
        let drive = FileManager.default.temporaryDirectory.appending(path: "car-absent-\(UUID().uuidString)")
        let s = try Session(input: "test mic", recordings: drive)
        defer { s.remove() }
        #expect(s.place("audio").store == "local")
        #expect(!FileManager.default.fileExists(atPath: drive.path))
    }

    @Test func removingASessionTakesEverythingWithIt() throws {
        let s = try Session(input: "test mic")
        s.event("key", ["chord": "⌘S"])
        s.chunkOpened(1, url: s.dir.appending(path: "audio/0001.m4a"), store: "local", start: s.t0)
        Session.flush()
        s.remove()
        #expect(Session.record(s.id) == nil)
        #expect(Session.chunks(s.id).isEmpty && Session.events(s.id).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: s.dir.path))
    }

    @Test func diskUseCountsWhatIsThere() throws {
        let s = try Session(input: "test mic")
        defer { s.remove() }
        let before = Storage.use()
        try Data(count: 64 * 1024).write(to: s.dir.appending(path: "shots/00001000.jpg"))
        try Data(count: 32 * 1024).write(to: s.dir.appending(path: "audio/0001.m4a"))
        let after = Storage.use()
        #expect(after.pictures - before.pictures >= 64 * 1024)
        #expect(after.sound - before.sound >= 32 * 1024)
        #expect(after.catalog > 0 && after.free != nil)
    }

    @Test func usageAddsUp() {
        Usage.record(session: nil, chunk: nil, purpose: "words", model: "m", audioSeconds: 60, cost: 0.01)
        Usage.record(session: nil, chunk: nil, purpose: "words", model: "m", audioSeconds: 30, cost: 0.02)
        Session.flush()
        let t = Usage.total()
        #expect(abs(t.cost - 0.03) < 1e-9 && t.audioSeconds == 90 && t.calls == 2)
    }
}

/// What a session's `onMove` heard, in order.
final class Moves: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [Bool] = []
    func add(_ b: Bool) { lock.withLock { seen.append(b) } }
    var all: [Bool] { lock.withLock { seen } }
}
