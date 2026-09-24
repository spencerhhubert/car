import Foundation

// A session's chunks, transcribed one at a time, oldest first: each as it
// closes while the session records, whatever is left when it stops, and
// whatever a crash left behind when someone picks the session up. `finish`
// waits for the last one and settles the session: done, or failed naming the
// chunks that failed. Only the holder of the session's lock runs one.
//
// One at a time keeps the order (a marker waits on everything before it, and
// gets it soonest this way) and keeps a long session from sending a burst of
// requests after a stretch offline.
public actor Transcriber {
    public let id: String
    private let options: Transcribe.Options
    private var waiting: [Int] = []
    private var working: Int?
    private var worker: Task<Void, Never>?

    public init(id: String, options: Transcribe.Options = Transcribe.Options()) {
        self.id = id
        self.options = options
    }

    /// Chunk `n` has closed.
    public func add(_ n: Int) {
        guard !waiting.contains(n), working != n else { return }
        waiting.append(n)
        if worker == nil { worker = Task { await self.work() } }
    }

    /// Every chunk not settled yet, and with `again`, the failed ones (or,
    /// with `all`, every chunk) too. Only for a session that is not
    /// recording: a chunk still being written reads as lost.
    public func addUnsettled(again: Bool = false, all: Bool = false) {
        for c in Session.chunks(id) where all || !c.state.settled || (again && c.state == .failed) { add(c.n) }
    }

    private func work() async {
        while !waiting.isEmpty {
            let n = waiting.removeFirst()
            working = n
            await Transcribe.chunk(id, n, options: options)
            working = nil
        }
        worker = nil
    }

    public struct Outcome: Sendable {
        public let state: SessionRecord.State
        public let words: Int
        public let failed: [Int]
        public let error: String?
    }

    /// The session has stopped: transcribe every chunk not settled yet
    /// (the last one's close can still be on its way here), then settle the
    /// session and write its timeline out.
    public func finish() async -> Outcome {
        addUnsettled()
        while let w = worker { await w.value }
        let chunks = Session.chunks(id)
        let failed = chunks.filter { $0.state == .failed }
        let error = failed.isEmpty ? nil
            : "chunk\(failed.count == 1 ? "" : "s") \(failed.map { String($0.n) }.joined(separator: ", ")): "
                + (failed.first?.error ?? "no reason recorded")
        Session.setState(id, failed.isEmpty ? .done : .failed, error: error)
        do { try Render.write(id: id) } catch { Log.line("\(id): session.md not written: \(error.localizedDescription)") }
        return Outcome(state: failed.isEmpty ? .done : .failed, words: Session.wordCount(id),
                       failed: failed.map(\.n), error: error)
    }
}
