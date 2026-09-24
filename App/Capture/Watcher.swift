import AppKit
import ApplicationServices
import Foundation
import CarKit

// Watches what the person does while a session records and writes it to the
// session as events. Five sources, all read-only:
//
//   - the workspace: which app came to the front
//   - an accessibility observer on that app: its focused window, focused
//     element and selection changing
//   - global event monitors: clicks, scrolls and keys, each read together
//     with the element under the pointer or in focus
//   - a one-second poll of the whole reading, which catches what the
//     notifications miss (a browser changing tabs, Finder changing selection)
//   - the drawing layer: every mark drawn, fading, or wiped
//
// Everything that asks another app a question goes through the reader queue
// (Adapters.swift) and comes back to the main thread to be compared and
// written. One reading is in flight at a time; a tick that arrives meanwhile
// asks for one more after it, so readings never interleave. An event carries
// the time it happened, not the time its reading came back.
//
// Keys are never logged as keystrokes. A shortcut (anything with ⌘ or ⌃) and
// the keys that act rather than type (return, tab, escape, the arrows) are
// logged as the chord. Every other key, anywhere (a text field, a terminal, a
// game), is typing: counted, and when it pauses, logged as how many keys went
// into which element, with what that element then held, never for a password
// field. Where the focus is does not decide this: a terminal does not look like
// a text field, and naming its keys would have written down what was typed.
@MainActor
final class Watcher {
    private let session: Session
    private let shots = Screenshot()
    /// Taking input (monitors, poll, observer) / writing events.
    private var listening = false
    private var writing = false
    /// Reads and pictures started and not yet written.
    private var inFlight = 0
    private var monitors: [Any] = []
    private var activation: NSObjectProtocol?
    private var observer: AXObserver?
    private var observedPid: pid_t = 0
    private var last = Reading()
    private var reading = false
    private var again = false
    private var poll: Timer?
    private var coalesce: Timer?
    private var typingCount = 0
    private var typingTimer: Timer?
    private var scrollDelta = 0.0
    private var scrollTimer: Timer?
    /// The marks on the screen, drawn into every picture they fall on.
    private var marks: [Mark] = []

    init(session: Session) { self.session = session }

    func start(sound: SoundQuality) {
        listening = true
        writing = true
        session.event("session", ["phase": "start", "accessibility": AXIsProcessTrusted(),
                                  "screen": Screenshot.hasPermission, "sound": sound.rawValue])
        activation = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        let mask: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] e in
            MainActor.assumeIsolated { self?.handle(e) }
        }) { monitors.append(g) }
        poll = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        tick()
    }

    /// Stop listening, write what is still on its way (the typing not yet
    /// flushed, the last click's picture), then the end. Waits at most two
    /// seconds for stragglers.
    func finish() async {
        guard listening else { return }
        let end = session.now
        flushTyping()
        stopListening()
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while inFlight > 0, ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(for: .milliseconds(25))
        }
        if inFlight > 0 { Log.line("session \(session.id): \(inFlight) reads or pictures still out at the end; dropped") }
        session.event("session", ["phase": "end"], at: end)
        writing = false
    }

    /// Stop at once, writing nothing more: the app is quitting.
    func halt() {
        guard listening || writing else { return }
        let end = session.now
        stopListening()
        session.event("session", ["phase": "end"], at: end)
        writing = false
    }

    private func stopListening() {
        listening = false
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors = []
        if let activation { NSWorkspace.shared.notificationCenter.removeObserver(activation) }
        activation = nil
        for t in [poll, coalesce, typingTimer, scrollTimer] { t?.invalidate() }
        poll = nil; coalesce = nil; typingTimer = nil; scrollTimer = nil
        detach()
    }

    /// Read something off the main thread and write what it says back on it.
    private func read<T>(_ work: @escaping () -> T, then: @escaping @MainActor (T) -> Void) {
        inFlight += 1
        Reader.run(work) { [weak self] value in
            guard let self else { return }
            self.inFlight -= 1
            guard self.writing else { return }
            then(value)
        }
    }

    // MARK: - the reading

    private func tick() {
        guard listening else { return }
        if reading {
            again = true
            return
        }
        guard let front = Front.now() else { return }
        if front.pid != observedPid { attach(front.pid) }
        reading = true
        let t = session.now
        read({ Adapters.read(front) }) { [weak self] r in self?.apply(r, at: t) }
    }

    /// Log whatever changed since the last reading.
    private func apply(_ r: Reading, at t: Int) {
        reading = false
        var shot: String?
        if r.app != last.app || r.bundle != last.bundle {
            session.event("app", ["app": r.app, "bundle": r.bundle], at: t)
            shot = "app"
        }
        if r.windowTitle != last.windowTitle || r.document != last.document || shot != nil {
            var f: [String: Any] = ["app": r.app, "title": r.windowTitle]
            if !r.document.isEmpty { f["document"] = r.document }
            session.event("window", f, at: t)
            shot = shot ?? "window"
        }
        if Self.focusKey(r.focus) != Self.focusKey(last.focus) {
            // Focus on nothing describable (a browser between pages) says nothing.
            if !(r.focus["role"] ?? "").isEmpty { session.event("focus", ["app": r.app, "element": r.focus], at: t) }
        } else if let sel = r.focus["selectedText"], sel != last.focus["selectedText"] ?? "" {
            session.event("select", ["app": r.app, "text": sel], at: t)
        }
        if let a = r.adapter, !a.fields.isEmpty,
           last.adapter.map({ !NSDictionary(dictionary: $0.fields).isEqual(to: a.fields) }) ?? true {
            var f = a.fields
            f["app"] = r.app
            session.event(a.kind, f, at: t)
            if shot == nil, a.kind == "page" { shot = "page" }
        }
        last = r
        if let shot { take(shot) }
        if again {
            again = false
            tick()
        }
    }

    /// The parts of a focus reading that mean "a different thing is focused",
    /// as opposed to the same field with more typed into it.
    private static func focusKey(_ f: [String: String]) -> [String: String] {
        var k = f
        k["value"] = nil
        k["selectedText"] = nil
        return k
    }

    private func scheduleTick() {
        coalesce?.invalidate()
        coalesce = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    // MARK: - pictures

    /// A picture of the focused window, or of `target`. `force` keeps it
    /// however little the screen changed.
    private func take(_ why: String, of target: Screenshot.Target? = nil, delay: Double = 0.25, force: Bool = false) {
        guard let target = target ?? frontWindow() else { return }
        let (app, title) = (last.app, last.windowTitle)
        inFlight += 1
        Task { @MainActor [weak self] in
            defer { self?.inFlight -= 1 }
            try? await Task.sleep(for: .seconds(delay))
            guard let self, self.writing else { return }
            let t = self.session.now
            guard let file = await self.shots.take(target, marks: self.marks,
                                                   into: self.session.dir.appending(path: "shots"),
                                                   name: String(format: "%08d", t), force: force)
            else { return }
            var f: [String: Any] = ["why": why]
            if case .window = target {
                f["app"] = app
                f["title"] = title
            }
            self.session.shot(file, at: t, f)
        }
    }

    private func frontWindow() -> Screenshot.Target? {
        guard let front = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = front.processIdentifier
        return .window(pid: pid, frame: last.pid == pid ? last.windowFrame : nil)
    }

    // MARK: - marks

    /// A mark was drawn: what it was drawn on, and a picture of the whole
    /// screen it is on, since a drawing is often about more than one window.
    func mark(_ m: Mark) {
        guard listening else { return }
        marks.append(m)
        let at = m.anchor
        read({ Adapters.under(at) }) { [weak self] under in
            self?.session.event("mark", m.fields.merging(under) { mine, _ in mine }, at: m.end)
        }
        if let display = Space.display(at: at) {
            take(m.name, of: .display(display), delay: 0.05, force: true)
        }
    }

    /// A mark started to fade: from now on it is not in a picture.
    func faded(_ m: Mark, _ why: Fade) {
        guard listening else { return }
        marks.removeAll { $0.n == m.n }
        session.event("fade", ["marks": [m.n], "names": [m.name], "why": why.rawValue])
    }

    /// The screen was wiped.
    func cleared(_ gone: [Mark]) {
        guard listening else { return }
        let numbers = Set(gone.map(\.n))
        marks.removeAll { numbers.contains($0.n) }
        session.event("clear", ["marks": gone.map(\.n), "names": gone.map(\.name)])
    }

    // MARK: - input events

    private func handle(_ e: NSEvent) {
        guard listening else { return }
        switch e.type {
        case .leftMouseDown, .rightMouseDown:
            let t = session.now
            let p = Space.fromCocoa(NSEvent.mouseLocation)
            let head: [String: Any] = ["button": e.type == .leftMouseDown ? "left" : "right",
                                       "count": e.clickCount, "x": Int(p.x), "y": Int(p.y)]
            read({ Adapters.under(p) }) { [weak self] under in
                self?.session.event("click", head.merging(under) { mine, _ in mine }, at: t)
            }
            // A picture after a click, when the screen changed: a session
            // runs for hours, and most clicks change nothing worth keeping.
            take("click", delay: 0.35)
            scheduleTick()
        case .scrollWheel:
            scrollDelta += Double(e.scrollingDeltaY)
            scrollTimer?.invalidate()
            scrollTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.scrollSettled() }
            }
        case .keyDown:
            key(e)
        default:
            break
        }
    }

    private func scrollSettled() {
        let t = session.now
        let p = Space.fromCocoa(NSEvent.mouseLocation)
        let dy = Int(scrollDelta)
        scrollDelta = 0
        let app = last.app
        read({ Adapters.under(p) }) { [weak self] under in
            var f: [String: Any] = ["dy": dy, "app": under["app"] ?? app]
            if let el = under["element"] { f["element"] = el }
            self?.session.event("scroll", f, at: t)
        }
        take("scroll", delay: 0.1)
    }

    /// The keys that act rather than type.
    private static let specialKeys: [UInt16: String] = [
        36: "return", 48: "tab", 53: "esc", 76: "enter", 123: "←", 124: "→", 125: "↓", 126: "↑",
    ]

    private func key(_ e: NSEvent) {
        let mods = e.modifierFlags.intersection([.command, .control, .option, .shift])
        let special = Self.specialKeys[e.keyCode]
        let named = mods.contains(.command) || mods.contains(.control) || special != nil
        if !named {
            typingCount += 1
            typingTimer?.invalidate()
            typingTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.flushTyping() }
            }
            return
        }
        var chord = ""
        if mods.contains(.control) { chord += "⌃" }
        if mods.contains(.option) { chord += "⌥" }
        if mods.contains(.shift) { chord += "⇧" }
        if mods.contains(.command) { chord += "⌘" }
        chord += special ?? (e.charactersIgnoringModifiers ?? "").uppercased()
        flushTyping()
        session.event("key", ["chord": chord, "app": last.app])
        if e.keyCode == 36 || e.keyCode == 76 || mods.contains(.command) { scheduleTick() }
    }

    private func flushTyping() {
        guard typingCount > 0 else { return }
        let n = typingCount
        typingCount = 0
        typingTimer?.invalidate()
        typingTimer = nil
        let (t, app) = (session.now, last.app)
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
        read({ Adapters.focused(pid) }) { [weak self] field in
            var f: [String: Any] = ["keys": n, "app": app]
            if let field { f["field"] = field }
            self?.session.event("typed", f, at: t)
        }
    }

    // MARK: - the accessibility observer on the front app

    /// Registering for an app's notifications is itself a message to that
    /// app, so it is done on the reader; only the run loop source lives here.
    private func attach(_ pid: pid_t) {
        detach()
        observedPid = pid
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        read({ () -> AXObserver? in
            var obs: AXObserver?
            guard AXObserverCreate(pid, Watcher.callback, &obs) == .success, let obs else { return nil }
            let app = AX.app(pid)
            for n in [kAXFocusedWindowChangedNotification, kAXFocusedUIElementChangedNotification,
                      kAXSelectedTextChangedNotification, kAXTitleChangedNotification,
                      kAXMainWindowChangedNotification, kAXWindowCreatedNotification] {
                AXObserverAddNotification(obs, app, n as CFString, refcon)
            }
            return obs
        }) { [weak self] obs in
            guard let self, let obs, self.listening, self.observedPid == pid, self.observer == nil else { return }
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
            self.observer = obs
        }
    }

    private func detach() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        observedPid = 0
    }

    private static let callback: AXObserverCallback = { _, _, _, refcon in
        guard let refcon else { return }
        let me = Unmanaged<Watcher>.fromOpaque(refcon).takeUnretainedValue()
        MainActor.assumeIsolated { me.scheduleTick() }
    }
}
