import Foundation
import Testing
@testable import CarKit

/// The script the sessions window shows, built from rows the way the catalog
/// hands them over.
@Suite struct ScriptTests {
    private let record = SessionRecord(Row(values: ["id": "20260924-140000", "started_at": "2026-09-24T14:00:00.000-04:00",
                                                    "time_zone": "America/New_York", "state": "recording"]))

    private func chunk(_ n: Int, _ start: Int, _ end: Int?, _ state: String) -> ChunkRecord {
        var v: [String: Any] = ["n": n, "start_ms": start, "state": state]
        v["end_ms"] = end
        return ChunkRecord(Row(values: v))
    }

    private func words(_ spec: [(String, Int, Int)]) -> [Word] {
        spec.enumerated().map { i, s in
            Word(Row(values: ["chunk": 1, "i": i, "text": s.0, "start_ms": s.1, "end_ms": s.2, "how": "matched"]))
        }
    }

    private func event(_ id: Int, _ t: Int, _ kind: String, _ data: [String: Any] = [:]) -> Event {
        Event(id: id, t: t, kind: kind, data: data)
    }

    private func click(_ id: Int, _ t: Int, _ title: String) -> Event {
        event(id, t, "click", ["app": "Safari", "button": "left", "count": 1,
                               "element": ["role": "AXButton", "title": title]])
    }

    private func build(chunks: [ChunkRecord], words: [Word] = [], events: [Event] = [],
                       markers: [MarkerRecord] = [], files: [Int: URL] = [:]) -> Script {
        Script.build(record, chunks: chunks, words: words, events: events, markers: markers, files: files, cost: 0)
    }

    @Test func aRemarkGathersWhatWasDoneNearIt() {
        let s = build(chunks: [chunk(1, 0, 60_000, "transcribed")],
                      words: words([("open", 1000, 1300), ("the", 1350, 1500), ("settings", 1550, 2000)]),
                      events: [click(1, 800, "Settings"), event(2, 4000, "key", ["app": "Safari", "chord": "⌘,"]),
                               event(3, 1500, "shot", ["file": 7, "why": "click"]),
                               event(4, 9000, "app", ["app": "Notes"])],
                      files: [7: URL(fileURLWithPath: "/tmp/7.jpg")])
        #expect(s.rows.count == 2)
        #expect(s.rows[0].speech == .said("open the settings"))
        #expect(s.rows[0].actions.map(\.text) == ["Clicked “Settings”", "⌘,"])
        #expect(s.rows[0].actions[0].detail == "button in Safari")
        #expect(s.rows[0].pictures.map(\.id) == [7])
        #expect(s.rows[1].speech == .quiet && s.rows[1].actions.map(\.text) == ["Switched to Notes"])
        #expect(s.pictures.map(\.reason) == ["after a click"])
    }

    @Test func wordsStillToComeHoldTheirPlace() {
        let s = build(chunks: [chunk(1, 0, 10_000, "transcribed"), chunk(2, 10_000, nil, "recording")],
                      words: words([("hello", 1000, 1500)]),
                      events: [click(1, 12_000, "Save"), click(2, 40_000, "Open")])
        #expect(s.rows.map(\.speech) == [.said("hello"), .recording(first: true), .recording(first: false)])
        #expect(s.rows[1].start == 10_000 && s.rows[1].actions.map(\.text) == ["Clicked “Save”"])

        // A chunk waiting for its words has a row even with nothing done in it.
        let waiting = build(chunks: [chunk(1, 0, 10_000, "recorded")])
        #expect(waiting.rows.map(\.speech) == [.transcribing(first: true)])
    }

    @Test func aMarkerStandsBetweenWhatCameBeforeAndAfter() {
        let m = MarkerRecord(Row(values: ["n": 1, "t": 2500, "at": "2026-09-24T14:00:02-04:00"]))
        let s = build(chunks: [chunk(1, 0, 60_000, "transcribed")],
                      words: words([("fix", 1000, 1300), ("this", 1350, 2000)]),
                      events: [click(1, 3000, "Save")], markers: [m])
        #expect(s.rows.map(\.id) == ["s1000", "m1", "q3000"])
        #expect(s.rows[0].actions.isEmpty)
        #expect(s.rows[1].marker?.n == 1 && s.rows[1].marker?.at != nil)
    }

    @Test func repeatsFoldAndAnAppSwitchTakesItsWindow() {
        let s = build(chunks: [chunk(1, 0, 60_000, "silent")],
                      events: [event(1, 1000, "app", ["app": "Notes"]),
                               event(2, 1010, "window", ["app": "Notes", "title": "Groceries"]),
                               click(3, 2000, "Save"), click(4, 2500, "Save"),
                               event(5, 3000, "focus", ["app": "Notes"])])
        #expect(s.rows.count == 1)
        let a = s.rows[0].actions
        #expect(a.map(\.text) == ["Switched to Notes", "Clicked “Save”"])
        #expect(a[0].detail == "Groceries" && a[1].count == 2)
    }

    @Test func aLongQuietStretchIsMarked() {
        let s = build(chunks: [chunk(1, 0, 600_000, "silent")],
                      events: [click(1, 1000, "A"), click(2, 400_000, "B")])
        #expect(s.rows.count == 2 && s.rows[0].gapBefore == nil && s.rows[1].gapBefore == 399_000)
    }

    @Test func dictationTakesWhatWasSaidSinceTheLastLongPause() {
        let w = words([("earlier", 0, 500), ("thought", 600, 1000),
                       ("sounds", 30_000, 30_400), ("good", 30_450, 30_800), ("to", 32_000, 32_100), ("me", 32_150, 32_400)])
        let d = Dictation.last(w, pause: 15_000)
        #expect(d?.text == "sounds good to me" && d?.from == 30_000 && d?.to == 32_400)
        #expect(Dictation.last(w, pause: 60_000)?.text == "earlier thought sounds good to me")
        #expect(Dictation.last([], pause: 15_000) == nil)
    }
}
