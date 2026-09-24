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
        s.chunkOpened(1, file: "audio/0001.m4a", start: s.t0 + 0.2)
        s.chunkClosed(1, file: "audio/0001.m4a", end: s.t0 + 5.2, seconds: 5, peakDb: -12)
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

    @Test func removingASessionTakesEverythingWithIt() throws {
        let s = try Session(input: "test mic")
        s.event("key", ["chord": "⌘S"])
        s.chunkOpened(1, file: "audio/0001.m4a", start: s.t0)
        Session.flush()
        s.remove()
        #expect(Session.record(s.id) == nil)
        #expect(Session.chunks(s.id).isEmpty && Session.events(s.id).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: s.dir.path))
    }

    @Test func usageAddsUp() {
        Usage.record(session: nil, chunk: nil, purpose: "words", model: "m", audioSeconds: 60, cost: 0.01)
        Usage.record(session: nil, chunk: nil, purpose: "words", model: "m", audioSeconds: 30, cost: 0.02)
        Session.flush()
        let t = Usage.total()
        #expect(abs(t.cost - 0.03) < 1e-9 && t.audioSeconds == 90 && t.calls == 2)
    }
}
