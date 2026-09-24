import AppKit
import OwlKit

// The owl's menu: the session (start, stop, marker, discard), the last one,
// the models and microphone, the OpenRouter key and what it has cost, the
// keys, the permissions.
extension App {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        config = Config.load()
        if let r = recording {
            menu.addItem(item("Stop session  ⌘⇧R  (\(Render.clock(r.session.now).dropLast(4)))", #selector(menuStop)))
            menu.addItem(item("Set marker  ⌥ ⌥", #selector(menuMarker)))
            menu.addItem(item("Discard session…", #selector(menuDiscard)))
        } else {
            menu.addItem(item("Start session  ⌘⇧R", #selector(menuStart)))
        }
        if !finishing.isEmpty {
            menu.addItem(disabled(finishing.count == 1 ? "Transcribing the last of \(finishing[0])…"
                                                       : "Transcribing \(finishing.count) sessions…"))
        }
        menu.addItem(.separator())
        menu.addItem(item("Last session", #selector(openLast)))
        menu.addItem(item("Copy last session for an agent", #selector(copyLast)))
        menu.addItem(item("Sessions folder", #selector(openSessions)))
        menu.addItem(.separator())

        let text = NSMenu()
        for m in models.isEmpty ? [OpenRouter.Model(id: config.textModel, name: config.textModel)] : models {
            let i = item(m.id, #selector(pickTextModel(_:)))
            i.representedObject = m.id
            i.state = m.id == config.textModel ? .on : .off
            text.addItem(i)
        }
        text.addItem(.separator())
        text.addItem(item("Refresh list", #selector(refreshModels)))
        menu.addItem(submenu("Words: \(config.textModel)", text))

        let times = NSMenu()
        for (title, value) in [("on this Mac (Apple)", "apple"),
                               ("\(config.textModel) keeps time", "openrouter:\(config.textModel)")] {
            let i = item(title, #selector(pickTimeSource(_:)))
            i.representedObject = value
            i.state = value == config.timeSource ? .on : .off
            times.addItem(i)
        }
        menu.addItem(submenu("Times: \(config.timeSource)", times))

        let mics = NSMenu()
        inputs = AudioInputs.all()
        let def = item("system default", #selector(pickInput(_:)))
        def.state = config.inputUID == nil ? .on : .off
        mics.addItem(def)
        for d in inputs {
            let i = item(d.name, #selector(pickInput(_:)))
            i.representedObject = d.uid
            i.state = d.uid == config.inputUID ? .on : .off
            mics.addItem(i)
        }
        menu.addItem(submenu("Microphone: \(config.inputName ?? "system default")", mics))

        let spent = NSMenu()
        for span in Usage.spans {
            let t = Usage.total(since: span.since)
            spent.addItem(disabled("\(span.name): \(Usage.dollars(t.cost)) · \(Int(t.audioSeconds / 60)) min sent"))
        }
        let byModel = Usage.byModel(since: Usage.spans[2].since)
        if !byModel.isEmpty {
            spent.addItem(.separator())
            spent.addItem(disabled("last 30 days, by model:"))
            for (model, t) in byModel { spent.addItem(disabled("  \(model): \(Usage.dollars(t.cost))")) }
        }
        let today = Usage.total(since: Usage.spans[0].since).cost
        let month = Usage.total(since: Usage.spans[2].since).cost
        menu.addItem(submenu("Spent: \(Usage.dollars(today)) today · \(Usage.dollars(month)) in 30 days", spent))
        menu.addItem(item("OpenRouter key: \(Config.openRouterKey == nil ? "none" : "set") — change…", #selector(setKey)))

        menu.addItem(.separator())
        let k = item("⌘⇧R starts and stops, ⌥ ⌥ sets a marker", #selector(toggleKeys))
        k.state = config.keys ? .on : .off
        menu.addItem(k)
        let perms = NSMenu()
        perms.addItem(item("Accessibility \(Keys.trusted ? "✓" : "— grant")", #selector(permAX)))
        perms.addItem(item("Microphone \(Mic.permissionGranted ? "✓" : "— grant")", #selector(permMic)))
        perms.addItem(item("Screen Recording \(Screenshot.hasPermission ? "✓" : "— grant")", #selector(permScreen)))
        perms.addItem(item("Automation (Finder, browsers) — ask", #selector(permAutomation)))
        menu.addItem(submenu("Permissions", perms))
        menu.addItem(item("Open log", #selector(openLog)))
        menu.addItem(.separator())
        menu.addItem(item("Quit \(Config.name)", #selector(quit)))
    }

    private func item(_ title: String, _ sel: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        i.target = self
        return i
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    private func submenu(_ title: String, _ sub: NSMenu) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.submenu = sub
        return i
    }

    /// The newest session that is not the one recording.
    private var lastSession: String? {
        Session.list().last { $0.id != recording?.session.id }?.id
    }

    @objc private func menuStart() { start() }
    @objc private func menuStop() { stop() }
    @objc private func menuMarker() { marker() }
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
        copy(Pointer.session(id))
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
        guard let key = Config.openRouterKey else { flash(.said("no OpenRouter key", ok: false)); return }
        Task { @MainActor in
            do {
                models = try await OpenRouter.audioModels(key: key)
                try JSONEncoder().encode(models).write(to: Config.root.appending(path: "models.json"))
            } catch { flash(.said(error.localizedDescription, ok: false)) }
        }
    }
    /// Paste a new key. It is kept in the key file, readable by this user
    /// only, and never shown.
    @objc private func setKey() {
        let ask = NSAlert()
        ask.messageText = "OpenRouter key"
        ask.informativeText = "Paste the key owl uses for words. It is kept in \(Config.root.path)/openrouter.key, readable by you only."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        ask.accessoryView = field
        ask.addButton(withTitle: "Save")
        ask.addButton(withTitle: "Cancel")
        NSApp.activate()
        ask.window.initialFirstResponder = field
        guard ask.runModal() == .alertFirstButtonReturn else { return }
        do {
            try Config.saveKey(field.stringValue)
            flash(.said("key saved", ok: true))
        } catch {
            flash(.said(error.localizedDescription, ok: false))
        }
    }
    @objc private func toggleKeys() {
        config.keys.toggle()
        config.save()
        if config.keys {
            if !Keys.trusted { Keys.requestTrust() }
            keys.start()
        } else {
            keys.stop()
        }
    }
    @objc private func permAX() { Keys.requestTrust() }
    @objc private func permMic() { Task { _ = await Mic.requestPermission() } }
    @objc private func permScreen() { Screenshot.requestPermission() }
    @objc private func permAutomation() { Adapters.requestAutomation() }
    @objc private func quit() { NSApp.terminate(nil) }
}
