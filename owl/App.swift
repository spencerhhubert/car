import AppKit
import Foundation

// The menu bar app: the owl in the menu bar, the gesture, the sessions.
//
// At most one session records at a time; any number can be transcribing
// behind it, so a new session starts the moment the last one stops. When one
// stops, the clipboard gets a note for an agent pointing at it (Pointer.swift),
// not its words. A session left unfinished by a crash or a quit is finished at
// the next launch; quitting (the menu, or a plain `kill`) closes the session
// being recorded properly first.
@MainActor
final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var status: NSStatusItem!
    private let menu = NSMenu()
    private var config = Config.load()
    private var gesture: Gesture!
    private let drawing = Drawing()
    private lazy var pill = Pill(drawing: drawing,
                                 onStop: { [weak self] in self?.gesture.abandon(); self?.stop() },
                                 onDiscard: { [weak self] in self?.discard() })
    private var recording: Recording?
    private var latched = false
    /// A start is waiting on the microphone.
    private var starting = false
    /// The gesture let go while the start was still waiting.
    private var stopWhenStarted = false
    /// Sessions being transcribed, oldest first.
    private var transcribing: [String] = []
    /// How the last transcription went, shown for a moment when nothing else is.
    private var outcome: (phase: Pill.Phase, until: Date)?
    private var ticker: Timer?
    private var terminate: DispatchSourceSignal?
    private var models: [OpenRouter.Model] = []
    private var inputs: [AudioInputs.Device] = []

    private var idleTitle: String { Config.isDev ? "🦉dev" : "🦉" }

    func applicationDidFinishLaunching(_ note: Notification) {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.title = idleTitle
        menu.delegate = self
        status.menu = menu
        gesture = Gesture(onStart: { [weak self] latched in self?.start(latched: latched) },
                          onStop: { [weak self] in self?.stop() },
                          onLatch: { [weak self] in self?.latch() })
        gesture.doubleClickEnabled = config.doubleClick
        if config.enabled {
            if !Gesture.trusted { Gesture.requestTrust() }
            gesture.start()
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
        Log.line("\(Config.name) up (accessibility \(Gesture.trusted), mic \(Mic.permissionGranted), " +
                 "screen \(Screenshot.hasPermission))")
        finishOrphans()
    }

    func applicationWillTerminate(_ note: Notification) {
        guard let r = recording else { return }
        recording = nil
        r.stopNow()
        Log.line("session \(r.session.id) closed at quit; the next launch transcribes it")
    }

    // MARK: - sessions

    private func start(latched: Bool) {
        guard recording == nil, !starting else { return }
        starting = true
        stopWhenStarted = false
        self.latched = latched
        Task { @MainActor in
            let allowed = await Mic.requestPermission()
            starting = false
            guard allowed else {
                gesture.abandon()
                flash(.failed("microphone denied"))
                return
            }
            do {
                let r = try Recording(config: config, drawing: drawing)
                recording = r
                status.button?.title = "🦉●"
                startTicker()
                refreshPill()
                Log.line("session \(r.session.id) started")
            } catch {
                Log.line("session did not start: \(error.localizedDescription)")
                gesture.abandon()
                flash(.failed(error.localizedDescription))
                return
            }
            if stopWhenStarted { stop() }
        }
    }

    private func latch() {
        latched = true
        refreshPill()
    }

    private func stop() {
        if starting {
            stopWhenStarted = true
            return
        }
        guard let r = recording else { return }
        recording = nil
        latched = false
        stopTicker()
        status.button?.title = idleTitle
        let s = r.session
        Pointer.copy(Pointer.text(id: s.id, started: s.startedAt, seconds: Double(s.now) / 1000))
        finish(s.id) {
            let s = await r.stop()
            Log.line("session \(s.id) ended, \(s.count) events")
            return s.lock
        }
    }

    /// The X on the pill: throw the session away.
    private func discard() {
        guard let r = recording else { return }
        recording = nil
        latched = false
        stopTicker()
        status.button?.title = idleTitle
        gesture.abandon()
        r.discard()
        Log.line("session \(r.session.id) discarded")
        refreshPill()
    }

    /// Transcribe a session, alongside whatever else is, and say how it went.
    /// `hold` gets it ready and returns its lock, which this keeps until the
    /// session is done or failed.
    private func finish(_ id: String, _ hold: @escaping @MainActor () async -> SessionLock) {
        transcribing.append(id)
        refreshPill()
        Task { @MainActor in
            let lock = await hold()
            let phase: Pill.Phase
            do {
                let sum = try await Transcribe.run(id: id)
                phase = .done("\(sum.words) words · \(Session.meta(id)?.events ?? 0) events")
            } catch {
                Log.line("transcribe \(id) failed: \(error.localizedDescription)")
                phase = .failed(error.localizedDescription)
            }
            lock.release()
            transcribing.removeAll { $0 == id }
            flash(phase)
        }
    }

    /// Sessions a crash or a quit left recording or transcribing, that no one
    /// is at: finish them now.
    private func finishOrphans() {
        for id in Session.list() {
            guard let m = Session.meta(id), m.status == .recording || m.status == .transcribing,
                  let lock = SessionLock(Session.dir(id)) else { continue }
            Log.line("session \(id) was left \(m.status.rawValue); finishing it")
            finish(id) { lock }
        }
    }

    private func flash(_ phase: Pill.Phase) {
        outcome = (phase, Date().addingTimeInterval(2.5))
        refreshPill()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.6))
            refreshPill()
        }
    }

    private func refreshPill() {
        pill.model.behind = transcribing.count
        if recording != nil {
            pill.show(.recording(latched: latched))
        } else if !transcribing.isEmpty {
            pill.show(.transcribing(transcribing.count))
        } else if let o = outcome, o.until > Date() {
            pill.show(o.phase)
        } else {
            outcome = nil
            pill.hide()
        }
    }

    private func startTicker() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let r = self.recording else { return }
                self.pill.meter.elapsed = r.elapsed
                self.pill.meter.level = r.level
                self.pill.follow()
            }
        }
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    // MARK: - the menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        config = Config.load()
        if let r = recording {
            menu.addItem(item("Stop session (\(Render.clock(r.session.now)))", #selector(menuStop)))
            menu.addItem(item("Discard session", #selector(menuDiscard)))
        } else {
            menu.addItem(item("Start session", #selector(menuStart)))
        }
        if !transcribing.isEmpty {
            let busy = NSMenuItem(title: transcribing.count == 1 ? "Transcribing \(transcribing[0])…"
                                                                 : "Transcribing \(transcribing.count) sessions…",
                                  action: nil, keyEquivalent: "")
            busy.isEnabled = false
            menu.addItem(busy)
        }
        menu.addItem(.separator())
        menu.addItem(item("Last session", #selector(openLast)))
        menu.addItem(item("Copy last session for an agent", #selector(copyLast)))
        menu.addItem(item("Sessions folder", #selector(openSessions)))
        menu.addItem(.separator())

        let text = NSMenu()
        for m in models.isEmpty ? [OpenRouter.Model(id: config.textModel, name: config.textModel)] : models {
            let i = NSMenuItem(title: m.id, action: #selector(pickTextModel(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = m.id
            i.state = m.id == config.textModel ? .on : .off
            text.addItem(i)
        }
        text.addItem(.separator())
        text.addItem(item("Refresh list", #selector(refreshModels)))
        let textItem = NSMenuItem(title: "Words: \(config.textModel)", action: nil, keyEquivalent: "")
        textItem.submenu = text
        menu.addItem(textItem)

        let times = NSMenu()
        for (title, value) in [("on this Mac (Apple)", "apple"),
                               ("\(config.textModel) keeps time", "openrouter:\(config.textModel)")] {
            let i = NSMenuItem(title: title, action: #selector(pickTimeSource(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = value
            i.state = value == config.timeSource ? .on : .off
            times.addItem(i)
        }
        let timesItem = NSMenuItem(title: "Times: \(config.timeSource)", action: nil, keyEquivalent: "")
        timesItem.submenu = times
        menu.addItem(timesItem)

        let mics = NSMenu()
        inputs = AudioInputs.all()
        let def = NSMenuItem(title: "system default", action: #selector(pickInput(_:)), keyEquivalent: "")
        def.target = self
        def.state = config.inputUID == nil ? .on : .off
        mics.addItem(def)
        for d in inputs {
            let i = NSMenuItem(title: d.name, action: #selector(pickInput(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = d.uid
            i.state = d.uid == config.inputUID ? .on : .off
            mics.addItem(i)
        }
        let micItem = NSMenuItem(title: "Microphone: \(config.inputName ?? "system default")", action: nil,
                                 keyEquivalent: "")
        micItem.submenu = mics
        menu.addItem(micItem)

        menu.addItem(.separator())
        let dc = item("Double-click in a text field starts a session", #selector(toggleDoubleClick))
        dc.state = config.doubleClick ? .on : .off
        menu.addItem(dc)
        let en = item("Hold ⌥ to start a session", #selector(toggleEnabled))
        en.state = config.enabled ? .on : .off
        menu.addItem(en)

        let perms = NSMenu()
        perms.addItem(item("Accessibility \(Gesture.trusted ? "✓" : "— grant")", #selector(permAX)))
        perms.addItem(item("Microphone \(Mic.permissionGranted ? "✓" : "— grant")", #selector(permMic)))
        perms.addItem(item("Screen Recording \(Screenshot.hasPermission ? "✓" : "— grant")", #selector(permScreen)))
        perms.addItem(item("Automation (Finder, browsers) — ask", #selector(permAutomation)))
        let permItem = NSMenuItem(title: "Permissions", action: nil, keyEquivalent: "")
        permItem.submenu = perms
        menu.addItem(permItem)
        menu.addItem(item("Open log", #selector(openLog)))
        menu.addItem(.separator())
        menu.addItem(item("Quit \(Config.name)", #selector(quit)))
    }

    private func item(_ title: String, _ sel: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        i.target = self
        return i
    }

    /// The newest session that is not the one recording.
    private var lastSession: String? {
        Session.list().last { $0 != recording?.session.id }
    }

    @objc private func menuStart() { start(latched: true) }
    @objc private func menuStop() { gesture.abandon(); stop() }
    @objc private func menuDiscard() { discard() }
    @objc private func openSessions() {
        try? FileManager.default.createDirectory(at: Config.sessionsDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Config.sessionsDir)
    }
    @objc private func openLast() {
        guard let id = lastSession else { return }
        try? Render.write(id: id)
        NSWorkspace.shared.open(Session.dir(id).appending(path: "session.md"))
    }
    @objc private func copyLast() {
        guard let id = lastSession else { return }
        Pointer.copy(Pointer.text(id: id))
    }
    @objc private func openLog() {
        NSWorkspace.shared.open(FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appending(path: "Logs/\(Config.name).log"))
    }
    @objc private func pickTextModel(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        config.textModel = id
        if config.timeSource.hasPrefix("openrouter:") { config.timeSource = "openrouter:\(id)" }
        config.save()
    }
    @objc private func pickTimeSource(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? String else { return }
        config.timeSource = v
        config.save()
    }
    @objc private func pickInput(_ sender: NSMenuItem) {
        if let uid = sender.representedObject as? String {
            config.inputUID = uid
            config.inputName = inputs.first { $0.uid == uid }?.name
        } else {
            config.inputUID = nil
            config.inputName = nil
        }
        config.save()
    }
    @objc private func refreshModels() {
        guard let key = Config.openRouterKey else { flash(.failed("no OpenRouter key")); return }
        Task { @MainActor in
            do {
                models = try await OpenRouter.audioModels(key: key)
                try JSONEncoder().encode(models).write(to: Config.root.appending(path: "models.json"))
            } catch { flash(.failed(error.localizedDescription)) }
        }
    }
    @objc private func toggleDoubleClick() {
        config.doubleClick.toggle()
        config.save()
        gesture.doubleClickEnabled = config.doubleClick
    }
    @objc private func toggleEnabled() {
        config.enabled.toggle()
        config.save()
        if config.enabled {
            if !Gesture.trusted { Gesture.requestTrust() }
            gesture.start()
        } else {
            gesture.stop()
        }
    }
    @objc private func permAX() { Gesture.requestTrust() }
    @objc private func permMic() { Task { _ = await Mic.requestPermission() } }
    @objc private func permScreen() { Screenshot.requestPermission() }
    @objc private func permAutomation() { Adapters.requestAutomation() }
    @objc private func quit() { NSApp.terminate(nil) }
}
