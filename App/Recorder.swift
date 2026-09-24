import AppKit
import Foundation
import CarKit

// Sessions, from the app's side. A session is meant to run for hours: ⌘ ⌥ ⌥
// starts it and ⌘ ⌥ ⌥ stops it; nothing else does. While it runs:
//
//   ⌥ ⌥      sets a marker: the chunk of sound is cut there so its words
//            come at once, and the clipboard gets a line naming the marker
//            for pasting into an agent (Pointer.swift), which reads what was
//            said up to it with `car marker`.
//   ⇧ ⌥ ⌥    quick dictation: the sound is cut the same way, and once its
//            words are in, what was said since the last long pause goes on
//            the clipboard as text (Dictation.swift). The session carries on.
//
// At most one session records; any number can be finishing their last chunks
// behind it. A session a crash or a quit left unfinished is finished at the
// next launch. The pill says what is happening; `changed` is posted whenever
// a session starts, stops or settles, for the sessions window.
@MainActor
final class Recorder {
    static let changed = Notification.Name("car.sessions.changed")

    let drawing = Drawing()
    private(set) lazy var pill = Pill(drawing: drawing)
    private(set) var recording: Recording?
    /// A start is waiting on the microphone.
    private var starting = false
    /// A dictation is waiting on its words.
    private var dictating = false
    /// Sessions finishing their last chunks, oldest first.
    private(set) var finishing: [String] = []
    private var outcome: (phase: Pill.Phase, until: Date)?

    func toggle() {
        if recording != nil { stop() } else { start() }
    }

    func start() {
        guard recording == nil, !starting else { return }
        let config = Config.load()
        // No key ships with car. With a remote model chosen, a session needs
        // one; with none, the local model's words are enough.
        if !config.remoteModel.isEmpty, Config.openRouterKey == nil {
            guard askForKey(because: "car sends the voice it hears to \(config.remoteModel) for its words, and that needs an OpenRouter key.") else {
                flash(.said("no OpenRouter key: set one, or choose no remote model in Settings", ok: false))
                return
            }
        }
        starting = true
        Task { @MainActor in
            defer { starting = false }
            guard await Mic.requestPermission() else {
                flash(.said("microphone denied", ok: false))
                return
            }
            do {
                let r = try await Recording.begin(config: config, drawing: drawing) { [weak self] what in
                    self?.pill.say(what, for: 6)
                }
                recording = r
                let started = r.session.startedAt
                pill.reading = { [weak r] in (Date().timeIntervalSince(started), r?.level ?? -160) }
                refreshPill()
                changed()
                Log.line("session \(r.session.id) started")
            } catch {
                Log.line("session did not start: \(error.localizedDescription)")
                flash(.said(error.localizedDescription, ok: false))
            }
        }
    }

    func marker() {
        guard let r = recording else {
            flash(.said("no session is recording: ⌘ ⌥ ⌥ starts one", ok: false))
            return
        }
        do {
            let m = try r.marker()
            copy(Pointer.marker(m.n, at: m.at, in: r.session.id))
            pill.say("marker \(m.n) · copied")
            changed()
            Log.line("session \(r.session.id): marker \(m.n)")
        } catch {
            pill.say("marker not set")
            Log.line("marker failed: \(error.localizedDescription)")
        }
    }

    /// What was just said, as text on the clipboard, as soon as its words
    /// are in.
    func dictate() {
        guard let r = recording else {
            flash(.said("no session is recording: ⌘ ⌥ ⌥ starts one", ok: false))
            return
        }
        guard !dictating else { return }
        dictating = true
        let t = r.cut()
        pill.say("transcribing what you just said…", for: 60)
        Task { @MainActor in
            defer { dictating = false }
            let id = r.session.id
            let giveUp = Date().addingTimeInterval(60)
            while !Session.unsettled(id, before: t).isEmpty, Date() < giveUp {
                try? await Task.sleep(for: .milliseconds(150))
            }
            guard Session.unsettled(id, before: t).isEmpty else {
                pill.say("the words did not come in time")
                return
            }
            let pause = Int(Config.load().dictationPause * 1000)
            let words = Session.words(id, from: max(0, t - 30 * 60_000), to: t)
            guard let said = Dictation.last(words, pause: pause) else {
                pill.say("nothing said since the last pause")
                return
            }
            copy(said.text)
            let n = said.text.split(separator: " ").count
            r.session.event("dictation", ["from": said.from, "to": said.to, "words": n], at: t)
            pill.say("\(n) word\(n == 1 ? "" : "s") · copied")
            Log.line("session \(id): dictation, \(n) words")
        }
    }

    func stop() {
        guard let r = recording else { return }
        recording = nil
        pill.reading = nil
        finish(r.session.id) {
            await r.stop()
            Log.line("session \(r.session.id) stopped")
            return (r.session.lock, r.transcriber)
        }
    }

    /// Discard the session being recorded, after asking: hours of sound and
    /// everything with it.
    func discard() {
        guard let r = recording else { return }
        let ask = NSAlert()
        ask.messageText = "Discard this session?"
        ask.informativeText = "\(Render.clock(r.session.now).dropLast(4)) of recording, with every word, picture and marker in it, is deleted."
        ask.addButton(withTitle: "Discard")
        ask.addButton(withTitle: "Keep Recording")
        ask.buttons.first?.hasDestructiveAction = true
        NSApp.activate()
        guard ask.runModal() == .alertFirstButtonReturn, recording === r else { return }
        recording = nil
        pill.reading = nil
        Task { @MainActor in
            await r.discard()
            Log.line("session \(r.session.id) discarded")
            refreshPill()
            changed()
        }
    }

    /// The app is quitting: close the session being recorded at once; the
    /// next launch transcribes what is left.
    func stopNow() {
        guard let r = recording else { return }
        recording = nil
        r.stopNow()
        Log.line("session \(r.session.id) closed at quit; the next launch transcribes what is left")
    }

    /// Sessions a crash or a quit left recording or transcribing, that no one
    /// is at: finish them now.
    func finishOrphans() {
        for s in Session.list() where s.isLive {
            guard let lock = SessionLock(Session.dir(s.id)) else { continue }
            Log.line("session \(s.id) was left \(s.state.rawValue); finishing it")
            Session.setState(s.id, .transcribing)
            finish(s.id) {
                let t = Transcriber(id: s.id)
                await t.addUnsettled()
                return (lock, t)
            }
        }
    }

    /// Bring a session to done or failed, alongside whatever else is, and say
    /// how it went. `hold` gets it ready and returns its lock, which is kept
    /// until the session is settled, and its transcriber.
    private func finish(_ id: String, _ hold: @escaping @MainActor () async -> (SessionLock, Transcriber)) {
        finishing.append(id)
        refreshPill()
        changed()
        Task { @MainActor in
            let (lock, transcriber) = await hold()
            let o = await transcriber.finish()
            lock.release()
            finishing.removeAll { $0 == id }
            flash(o.state == .done ? .said("\(o.words) words", ok: true)
                                   : .said(o.error ?? "some chunks failed", ok: false))
            changed()
        }
    }

    /// Ask for the OpenRouter key and keep it (Config.saveKey). Whether one
    /// was saved.
    func askForKey(because why: String) -> Bool {
        let ask = NSAlert()
        ask.messageText = "OpenRouter Key"
        ask.informativeText = why + "\n\nPaste a key from openrouter.ai/keys. It is kept in \(Config.root.path)/openrouter.key, readable by you only."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        ask.accessoryView = field
        ask.addButton(withTitle: "Save")
        ask.addButton(withTitle: "Cancel")
        NSApp.activate()
        ask.window.initialFirstResponder = field
        guard ask.runModal() == .alertFirstButtonReturn else { return false }
        do {
            try Config.saveKey(field.stringValue)
            return true
        } catch {
            flash(.said(error.localizedDescription, ok: false))
            return false
        }
    }

    func flash(_ phase: Pill.Phase) {
        outcome = (phase, Date().addingTimeInterval(2.5))
        refreshPill()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.6))
            refreshPill()
        }
    }

    private func refreshPill() {
        if recording != nil {
            pill.show(.recording)
        } else if !finishing.isEmpty {
            pill.show(.working(finishing.count == 1 ? "transcribing the last of it…"
                                                    : "transcribing \(finishing.count) sessions…"))
        } else if let o = outcome, o.until > Date() {
            pill.show(o.phase)
        } else {
            outcome = nil
            pill.hide()
        }
    }

    private func changed() {
        NotificationCenter.default.post(name: Recorder.changed, object: nil)
    }

    func copy(_ text: String) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
    }
}
