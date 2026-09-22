import AppKit
import ApplicationServices
import Foundation

// Watches what he does while a session runs and writes it to the session as
// events. Four sources, all read-only:
//
//   - the workspace: which app came to the front
//   - an accessibility observer on that app: its focused window, focused
//     element and selection changing
//   - global event monitors: clicks, scrolls and keys, each read together
//     with the element under the pointer or in focus
//   - a one-second poll of the whole reading, which catches what the
//     notifications miss (a browser changing tabs, Finder changing selection)
//
// Keys are never logged as keystrokes. A shortcut (anything with ⌘ or ⌃, and
// return, tab, escape) is logged as the chord; plain typing is counted and,
// when it pauses, logged as the field it went into with that field's value,
// and never for a password field.
@MainActor
final class Watcher {
    private let session: Session
    private let shots = Screenshot()
    private var monitors: [Any] = []
    private var observer: AXObserver?
    private var observedPid: pid_t = 0
    private var last = Reading()
    private var poll: Timer?
    private var coalesce: Timer?
    private var typingCount = 0
    private var typingTimer: Timer?
    private var scrollDelta = 0.0
    private var scrollTimer: Timer?
    private var activation: NSObjectProtocol?

    init(session: Session) { self.session = session }

    func start() {
        session.event("session", ["phase": "start", "accessibility": Gesture.trusted,
                                  "screen": Screenshot.hasPermission])
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

    func stop() {
        session.event("session", ["phase": "end"])
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors = []
        if let activation { NSWorkspace.shared.notificationCenter.removeObserver(activation) }
        activation = nil
        poll?.invalidate(); poll = nil
        coalesce?.invalidate(); coalesce = nil
        typingTimer?.invalidate(); typingTimer = nil
        scrollTimer?.invalidate(); scrollTimer = nil
        detach()
    }

    // MARK: - the reading

    /// Read the front app and log whatever changed since the last reading.
    private func tick() {
        let t = session.now
        let r = Adapters.read()
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != observedPid {
            attach(front.processIdentifier)
        }
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
            session.event("focus", ["app": r.app, "element": r.focus], at: t)
        } else if let sel = r.focus["selectedText"], sel != last.focus["selectedText"] ?? "" {
            session.event("select", ["app": r.app, "text": sel], at: t)
        }
        if !(NSDictionary(dictionary: r.extra).isEqual(to: last.extra)) {
            var f = r.extra
            f["app"] = r.app
            let kind = r.bundle == "com.apple.finder" ? "finder" : "page"
            session.event(kind, f, at: t)
            if shot == nil, kind == "page" { shot = "page" }
        }
        last = r
        if let shot { take(reason: shot) }
    }

    /// The parts of a focus reading that mean "a different thing is focused",
    /// as opposed to the same field with more typed into it.
    private static func focusKey(_ f: [String: String]) -> [String: String] {
        var k = f
        k["value"] = nil
        k["selectedText"] = nil
        return k
    }

    private func take(reason: String, delay: Double = 0.25) {
        guard let front = NSWorkspace.shared.frontmostApplication else { return }
        let pid = front.processIdentifier
        let app = front.localizedName ?? ""
        let title = last.windowTitle
        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(delay))
            let t = self.session.now
            let name = String(format: "%08d", t)
            if let file = await self.shots.take(pid: pid, to: self.session.dir.appending(path: "shots"), name: name) {
                self.session.event("shot", ["file": "shots/\(file)", "why": reason, "app": app, "title": title], at: t)
            }
        }
    }

    // MARK: - input events

    private func handle(_ e: NSEvent) {
        switch e.type {
        case .leftMouseDown, .rightMouseDown:
            let t = session.now
            let p = NSEvent.mouseLocation
            var f: [String: Any] = ["button": e.type == .leftMouseDown ? "left" : "right",
                                    "count": e.clickCount, "x": Int(p.x), "y": Int(p.y)]
            if let el = AX.elementAt(p) {
                f["element"] = AX.describe(el, valueLimit: 120)
                if let pid = AX.pid(el), let app = NSRunningApplication(processIdentifier: pid) {
                    f["app"] = app.localizedName ?? ""
                }
            }
            session.event("click", f, at: t)
            take(reason: "click", delay: 0.35)
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
        let p = NSEvent.mouseLocation
        var f: [String: Any] = ["dy": Int(scrollDelta), "app": last.app]
        if let el = AX.elementAt(p) { f["element"] = AX.describe(el, valueLimit: 80) }
        scrollDelta = 0
        session.event("scroll", f, at: t)
        take(reason: "scroll", delay: 0.1)
    }

    private func key(_ e: NSEvent) {
        let mods = e.modifierFlags.intersection([.command, .control, .option, .shift])
        let special: [UInt16: String] = [36: "return", 48: "tab", 53: "esc", 76: "enter",
                                         123: "←", 124: "→", 125: "↓", 126: "↑"]
        if mods.contains(.command) || mods.contains(.control) || special[e.keyCode] != nil {
            var chord = ""
            if mods.contains(.control) { chord += "⌃" }
            if mods.contains(.option) { chord += "⌥" }
            if mods.contains(.shift) { chord += "⇧" }
            if mods.contains(.command) { chord += "⌘" }
            chord += special[e.keyCode] ?? (e.charactersIgnoringModifiers ?? "").uppercased()
            flushTyping()
            session.event("key", ["chord": chord, "app": last.app])
            if e.keyCode == 36 || e.keyCode == 76 || mods.contains(.command) { scheduleTick() }
            return
        }
        typingCount += 1
        typingTimer?.invalidate()
        typingTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushTyping() }
        }
    }

    private func flushTyping() {
        guard typingCount > 0 else { return }
        let n = typingCount
        typingCount = 0
        typingTimer?.invalidate(); typingTimer = nil
        var f: [String: Any] = ["keys": n, "app": last.app]
        if let front = NSWorkspace.shared.frontmostApplication,
           let el = AX.element(AX.app(front.processIdentifier), kAXFocusedUIElementAttribute) {
            f["field"] = AX.describe(el, valueLimit: 400)
        }
        session.event("typed", f)
    }

    private func scheduleTick() {
        coalesce?.invalidate()
        coalesce = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    // MARK: - the accessibility observer on the front app

    private func attach(_ pid: pid_t) {
        detach()
        var obs: AXObserver?
        guard AXObserverCreate(pid, Watcher.callback, &obs) == .success, let obs else { return }
        let app = AX.app(pid)
        let me = Unmanaged.passUnretained(self).toOpaque()
        for n in [kAXFocusedWindowChangedNotification, kAXFocusedUIElementChangedNotification,
                  kAXSelectedTextChangedNotification, kAXTitleChangedNotification,
                  kAXMainWindowChangedNotification, kAXWindowCreatedNotification] {
            AXObserverAddNotification(obs, app, n as CFString, me)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        observer = obs
        observedPid = pid
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
