import Foundation

// The session being recorded and what feeds it: the microphone, the watcher,
// and the drawing layer's marks. There is at most one. Stopping it hands the
// session on to be transcribed and frees everything else at once, so the next
// session can start while this one is still being written up.
@MainActor
final class Recording {
    let session: Session
    private let mic: Mic
    private let watcher: Watcher
    private let drawing: Drawing

    init(config: Config, drawing: Drawing) throws {
        let session = try Session()
        let mic = Mic()
        let device = config.inputUID.flatMap { AudioInputs.device(withUID: $0)?.id }
        do {
            try mic.start(to: session.dir.appending(path: "audio.m4a"), deviceID: device)
        } catch {
            session.remove()
            throw error
        }
        session.update {
            $0.input = config.inputName ?? "system default"
            $0.audioStartMs = (mic.startedUptime - session.t0) * 1000
        }
        let watcher = Watcher(session: session)
        self.session = session
        self.mic = mic
        self.watcher = watcher
        self.drawing = drawing
        watcher.start()
        drawing.begin(session, onMark: { [weak watcher] in watcher?.mark($0) },
                      onFade: { [weak watcher] in watcher?.faded($0, $1) },
                      onClear: { [weak watcher] in watcher?.cleared($0) })
    }

    var elapsed: Double { mic.elapsed }
    var level: Float { mic.level }

    /// Stop. The sound ends now; the watcher writes what is still on its way;
    /// then the session is closed and waiting to be transcribed.
    func stop() async -> Session {
        let rec = end()
        await watcher.finish()
        close(rec)
        return session
    }

    /// Stop at once, for the app quitting: whatever is still on its way is
    /// dropped. The session is left waiting to be transcribed, and the next
    /// launch does it.
    func stopNow() {
        let rec = end()
        watcher.halt()
        close(rec)
    }

    /// The X: nothing is kept.
    func discard() {
        drawing.end()
        watcher.halt()
        _ = mic.stop()
        session.remove()
    }

    private func end() -> Mic.Recording? {
        let drawn = drawing.drawn
        drawing.end()
        session.update { $0.marks = drawn }
        return mic.stop()
    }

    private func close(_ rec: Mic.Recording?) {
        if let rec {
            session.update {
                $0.wallSeconds = rec.wallSeconds
                $0.soundSeconds = rec.soundSeconds
                $0.peakDb = Double(rec.peak)
            }
        }
        session.close()
    }
}
