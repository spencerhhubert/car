import AppKit
import Foundation
import OwlKit

// The menu bar app: the owl in the menu bar, the keys, the sessions.
//
// A session is meant to run for hours. ⌘⇧R starts it and ⌘⇧R stops it;
// nothing else does. While it runs, two taps of ⌥ set a marker: the chunk of
// sound is cut there so its words come at once, and the clipboard gets a line
// naming the marker for pasting into an agent (Pointer.swift), which reads
// what was said up to it with `owl marker`. At most one session records; any
// number can be finishing their last chunks behind it. A session a crash or a
// quit left unfinished is finished at the next launch; quitting (the menu, or
// a plain `kill`) closes the session being recorded properly first.
@MainActor
final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var status: NSStatusItem!
    let menu = NSMenu()
    var config = Config.load()
    let drawing = Drawing()
    lazy var keys = Keys(onToggle: { [weak self] in self?.toggle() }, onMarker: { [weak self] in self?.marker() })
    lazy var pill = Pill(drawing: drawing)
    lazy var updater = Updater(isBusy: { [weak self] in self.map { $0.recording != nil || $0.starting || !$0.finishing.isEmpty } ?? false })
    private(set) var recording: Recording?
    /// A start is waiting on the microphone.
    private(set) var starting = false
    /// Sessions finishing their last chunks, oldest first.
    private(set) var finishing: [String] = []
    private var outcome: (phase: Pill.Phase, until: Date)?
    private var terminate: DispatchSourceSignal?
    var models: [OpenRouter.Model] = []
    var inputs: [AudioInputs.Device] = []

    var idleTitle: String { Config.isDev ? "🦉dev" : "🦉" }

    func applicationDidFinishLaunching(_ note: Notification) {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.title = idleTitle
        menu.delegate = self
        status.menu = menu
        if config.keys {
            if !Keys.trusted { Keys.requestTrust() }
            keys.start()
        }
        if let data = try? Data(contentsOf: Config.root.appending(path: "models.json")),
           let m = try? JSONDecoder().decode([OpenRouter.Model].self, from: data) { models = m }
        // `kill` is a quit like any other: the session being recorded is
        // closed, not cut off.
        signal(SIGTERM, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        term.setEventHandler { NSApp.terminate(nil) }
        term.resume()
        terminate = term
        Log.line("\(Config.name) \(Updater.version) up (accessibility \(Keys.trusted), mic \(Mic.permissionGranted), " +
                 "screen \(Screenshot.hasPermission))")
        linkCommand()
        finishOrphans()
        updater.start()
    }

    func applicationWillTerminate(_ note: Notification) {
        guard let r = recording else { return }
        recording = nil
        r.stopNow()
        Log.line("session \(r.session.id) closed at quit; the next launch transcribes what is left")
    }

    // MARK: - sessions

    /// ⌘⇧R.
    func toggle() {
        if recording != nil { stop() } else { start() }
    }

    func start() {
        guard recording == nil, !starting else { return }
        // No key ships with owl. With a remote model chosen, a session needs
        // one; with none, the local model's words are enough.
        if !config.remoteModel.isEmpty, Config.openRouterKey == nil {
            guard askForKey(because: "owl sends the voice it hears to \(config.remoteModel) for its words, and that needs an OpenRouter key.") else {
                flash(.said("no OpenRouter key: set one, or Remote model → none", ok: false))
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
                let r = try await Recording.begin(config: config, drawing: drawing)
                recording = r
                status.button?.title = "🦉●"
                let started = r.session.startedAt
                pill.reading = { [weak r] in (Date().timeIntervalSince(started), r?.level ?? -160) }
                refreshPill()
                Log.line("session \(r.session.id) started")
            } catch {
                Log.line("session did not start: \(error.localizedDescription)")
                flash(.said(error.localizedDescription, ok: false))
            }
        }
    }

    /// ⌥ ⌥.
    func marker() {
        guard let r = recording else {
            flash(.said("no session is recording: ⌘⇧R starts one", ok: false))
            return
        }
        do {
            let m = try r.marker()
            copy(Pointer.marker(m.n, at: m.at, in: r.session.id))
            pill.say("marker \(m.n) · copied")
            Log.line("session \(r.session.id): marker \(m.n)")
        } catch {
            pill.say("marker not set")
            Log.line("marker failed: \(error.localizedDescription)")
        }
    }

    func stop() {
        guard let r = recording else { return }
        recording = nil
        status.button?.title = idleTitle
        pill.reading = nil
        finish(r.session.id) {
            await r.stop()
            Log.line("session \(r.session.id) stopped")
            return (r.session.lock, r.transcriber)
        }
    }

    /// The menu's discard, after asking: hours of sound and everything with it.
    func discard() {
        guard let r = recording else { return }
        let ask = NSAlert()
        ask.messageText = "Discard this session?"
        ask.informativeText = "\(Render.clock(r.session.now).dropLast(4)) of recording, with every word, picture and marker in it, is deleted."
        ask.addButton(withTitle: "Discard")
        ask.addButton(withTitle: "Keep recording")
        ask.buttons.first?.hasDestructiveAction = true
        NSApp.activate()
        guard ask.runModal() == .alertFirstButtonReturn, recording === r else { return }
        recording = nil
        status.button?.title = idleTitle
        pill.reading = nil
        Task { @MainActor in
            await r.discard()
            Log.line("session \(r.session.id) discarded")
            refreshPill()
        }
    }

    /// Bring a session to done or failed, alongside whatever else is, and say
    /// how it went. `hold` gets it ready and returns its lock, which is kept
    /// until the session is settled, and its transcriber.
    private func finish(_ id: String, _ hold: @escaping @MainActor () async -> (SessionLock, Transcriber)) {
        finishing.append(id)
        refreshPill()
        Task { @MainActor in
            let (lock, transcriber) = await hold()
            let o = await transcriber.finish()
            lock.release()
            finishing.removeAll { $0 == id }
            flash(o.state == .done ? .said("\(o.words) words", ok: true)
                                   : .said(o.error ?? "some chunks failed", ok: false))
            updater.installIfIdle()
        }
    }

    /// Sessions a crash or a quit left recording or transcribing, that no one
    /// is at: finish them now.
    private func finishOrphans() {
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

    /// `owl` (or `owl-dev`) on the command line: a link in ~/.local/bin to
    /// this app's binary, made or mended at launch.
    private func linkCommand() {
        let bin = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin")
        let link = bin.appending(path: Config.name)
        guard let target = Config.bundle.executableURL?.path else { return }
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == target { return }
        do {
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: link)
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target)
        } catch {
            Log.line("could not link \(link.path): \(error.localizedDescription)")
        }
    }

    func copy(_ text: String) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
    }
}
