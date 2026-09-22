import AppKit
import CoreAudio
import Foundation

// The menu bar app: the owl in the menu bar, the gesture, the session.
@MainActor
final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var status: NSStatusItem!
    private let menu = NSMenu()
    private var config = Config.load()
    private let mic = Mic()
    private let overlay = Overlay()
    private var gesture: Gesture!
    private var session: Session?
    private var watcher: Watcher?
    private var ticker: Timer?
    private var latched = false
    private var models: [OpenRouter.Model] = []
    private var inputs: [AudioInputs.Device] = []

    func applicationDidFinishLaunching(_ note: Notification) {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.title = "🦉"
        menu.delegate = self
        status.menu = menu
        gesture = Gesture(onStart: { [weak self] latched in self?.start(latched: latched) },
                          onStop: { [weak self] in self?.stop() },
                          onLatch: { [weak self] in self?.latched = true })
        gesture.doubleClickEnabled = config.doubleClick
        if !Gesture.trusted { Gesture.requestTrust() }
        if config.enabled { gesture.start() }
        if let data = try? Data(contentsOf: Config.root.appending(path: "models.json")),
           let m = try? JSONDecoder().decode([OpenRouter.Model].self, from: data) { models = m }
        Log.line("owl up (accessibility \(Gesture.trusted), mic \(Mic.permissionGranted), screen \(Screenshot.hasPermission))")
    }

    func applicationWillTerminate(_ note: Notification) {
        if session != nil { stop() }
    }

    // MARK: - a session

    private func start(latched: Bool) {
        guard session == nil else { return }
        self.latched = latched
        Task { @MainActor in
            guard await Mic.requestPermission() else {
                failed("microphone denied")
                gesture.abandon()
                return
            }
            do {
                let s = try Session()
                let device = config.inputUID.flatMap { AudioInputs.device(withUID: $0)?.id }
                try mic.start(to: s.dir.appending(path: "audio.m4a"), deviceID: device)
                s.meta["audioStartMs"] = (mic.elapsedSinceStart(s.t0)) * 1000
                s.meta["input"] = config.inputName ?? "system default"
                s.saveMeta()
                session = s
                let w = Watcher(session: s)
                watcher = w
                w.start()
                status.button?.title = "🦉●"
                startTicker()
                Log.line("session \(s.id) started")
            } catch {
                failed(error.localizedDescription)
                gesture.abandon()
            }
        }
    }

    private func stop() {
        guard let s = session else { return }
        session = nil
        ticker?.invalidate(); ticker = nil
        watcher?.stop(); watcher = nil
        if let rec = mic.stop() {
            s.meta["wallSeconds"] = rec.wallSeconds
            s.meta["soundSeconds"] = rec.soundSeconds
            s.meta["peakDb"] = Double(rec.peak)
            s.meta["audioStartMs"] = (rec.startedUptime - s.t0) * 1000
        }
        s.close()
        status.button?.title = "🦉"
        latched = false
        overlay.show(PillView(state: .finishing("transcribing…")))
        Log.line("session \(s.id) ended, \(s.count) events")
        Task { @MainActor in
            do {
                let sum = try await Transcribe.run(id: s.id)
                overlay.show(PillView(state: .finishing("\(sum.words) words · \(s.count) events")))
            } catch {
                Log.line("transcribe failed: \(error.localizedDescription)")
                try? Render.write(id: s.id)
                overlay.show(PillView(state: .failed(error.localizedDescription)))
            }
            try? await Task.sleep(for: .seconds(2.5))
            if session == nil { overlay.hide() }
        }
    }

    /// The X on the pill: throw the session away.
    private func cancel() {
        guard let s = session else { return }
        session = nil
        ticker?.invalidate(); ticker = nil
        watcher?.stop(); watcher = nil
        _ = mic.stop()
        s.close()
        try? FileManager.default.removeItem(at: s.dir)
        gesture.abandon()
        status.button?.title = "🦉"
        latched = false
        overlay.hide()
        Log.line("session \(s.id) discarded")
    }

    private func failed(_ why: String) {
        overlay.show(PillView(state: .failed(why)))
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            if session == nil { overlay.hide() }
        }
    }

    private func startTicker() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.session != nil else { return }
                self.overlay.show(PillView(state: .recording(self.mic.elapsed, self.mic.level, latched: self.latched),
                                           onCancel: { [weak self] in self?.cancel() }))
            }
        }
    }

    // MARK: - the menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        config = Config.load()
        if let s = session {
            menu.addItem(item("Stop session (\(Render.clock(s.now)))", #selector(menuStop)))
            menu.addItem(item("Discard session", #selector(menuCancel)))
        } else {
            menu.addItem(item("Start session", #selector(menuStart)))
        }
        menu.addItem(.separator())
        menu.addItem(item("Last session", #selector(openLast)))
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
        let micItem = NSMenuItem(title: "Microphone: \(config.inputName ?? "system default")", action: nil, keyEquivalent: "")
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
        menu.addItem(item("Quit owl", #selector(quit)))
    }

    private func item(_ title: String, _ sel: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        i.target = self
        return i
    }

    @objc private func menuStart() { latched = true; start(latched: true) }
    @objc private func menuStop() { gesture.abandon(); stop() }
    @objc private func menuCancel() { cancel() }
    @objc private func openSessions() {
        try? FileManager.default.createDirectory(at: Config.sessionsDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Config.sessionsDir)
    }
    @objc private func openLast() {
        guard let id = Session.list().last else { return }
        let md = Session.dir(id).appending(path: "session.md")
        if !FileManager.default.fileExists(atPath: md.path) { try? Render.write(id: id) }
        NSWorkspace.shared.open(md)
    }
    @objc private func openLog() {
        NSWorkspace.shared.open(FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appending(path: "Logs/owl.log"))
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
        guard let key = Config.openRouterKey else { failed("no OpenRouter key"); return }
        Task { @MainActor in
            do {
                models = try await OpenRouter.audioModels(key: key)
                try? JSONEncoder().encode(models).write(to: Config.root.appending(path: "models.json"))
            } catch { failed(error.localizedDescription) }
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
        config.enabled ? gesture.start() : gesture.stop()
    }
    @objc private func permAX() { Gesture.requestTrust() }
    @objc private func permMic() { Task { _ = await Mic.requestPermission() } }
    @objc private func permScreen() { Screenshot.requestPermission() }
    @objc private func permAutomation() { Adapters.requestAutomation() }
    @objc private func quit() { NSApp.terminate(nil) }
}

extension Mic {
    /// Seconds from a session's start uptime to the microphone's.
    func elapsedSinceStart(_ t0: TimeInterval) -> Double {
        ProcessInfo.processInfo.systemUptime - t0
    }
}
