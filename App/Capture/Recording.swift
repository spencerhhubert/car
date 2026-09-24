import Foundation
import OwlKit

// The session being recorded and what feeds it: the microphone, a chunk at a
// time; the watcher; the drawing layer's marks; and the transcriber, which
// works through the chunks as they close, so by the time a marker is set
// most of what came before it already has its words. There is at most one.
@MainActor
final class Recording {
    let session: Session
    let transcriber: Transcriber
    private let mic: Mic
    private let watcher: Watcher
    private let drawing: Drawing

    private init(session: Session, mic: Mic, transcriber: Transcriber, drawing: Drawing) {
        self.session = session
        self.mic = mic
        self.transcriber = transcriber
        self.drawing = drawing
        watcher = Watcher(session: session)
    }

    static func begin(config: Config, drawing: Drawing) async throws -> Recording {
        let session = try Session(input: config.inputName ?? "system default")
        let transcriber = Transcriber(id: session.id)
        let mic = Mic(onOpen: { c in session.chunkOpened(c.n, file: c.file, start: c.start) },
                      onClose: { c in
                          session.chunkClosed(c.n, file: c.file, end: c.end, seconds: c.seconds, peakDb: Double(c.peak))
                          Task { await transcriber.add(c.n) }
                      })
        do {
            try await mic.start(into: session.dir, uid: config.inputUID)
        } catch {
            session.remove()
            throw error
        }
        let r = Recording(session: session, mic: mic, transcriber: transcriber, drawing: drawing)
        r.watcher.start()
        drawing.begin(session, onMark: { [weak r] in r?.watcher.mark($0) },
                      onFade: { [weak r] in r?.watcher.faded($0, $1) },
                      onClear: { [weak r] in r?.watcher.cleared($0) })
        return r
    }

    var level: Float { mic.level }

    /// Set a marker now and cut the chunk there, so the words up to it are
    /// transcribed straight away.
    func marker() throws -> (n: Int, at: Date) {
        let m = try session.marker()
        mic.cut()
        return (m.n, m.at)
    }

    /// Stop. The sound ends now; the watcher writes what is still on its way;
    /// then the session is closed and its last chunks are transcribed.
    func stop() async {
        drawing.end()
        await mic.stop()
        await watcher.finish()
        session.close()
    }

    /// Stop at once, for the app quitting: the last chunk is closed, anything
    /// still on its way is dropped, and the next launch transcribes what is
    /// left.
    func stopNow() {
        drawing.end()
        watcher.halt()
        session.close()
        let done = DispatchSemaphore(value: 0)
        Task.detached { [mic] in
            await mic.stop()
            done.signal()
        }
        _ = done.wait(timeout: .now() + 2)
        Session.flush()
    }

    /// The menu's discard: nothing is kept.
    func discard() async {
        drawing.end()
        watcher.halt()
        await mic.stop()
        session.remove()
    }
}
