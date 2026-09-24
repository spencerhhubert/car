import AppKit
import ApplicationServices

// The global gesture that starts and stops a session.
//
// Hold Option by itself: half a second in, the session starts, and letting go
// ends it. A hold that lasts past `latchSeconds` latches, so a long session
// does not need a thumb pinned on the key: the release is then inert and the
// next distinct press of Option is the stop.
//
// A bare modifier is the right key because it has to work from inside every
// other app, and a modifier held alone is the one chord nothing else claims.
// So the gesture arms when Option goes down by itself and disarms the moment
// anything joins it: a key, a click, a scroll, another modifier.
//
// The second way in is a double-click inside a text field, which starts a
// latched session on the spot. Everything else claims double-clicks (a word,
// a file, a row), so it is refused anywhere that is not editable text, which
// `TextProbe` decides. The same double-click in a text field ends a running
// session; a double-click on a file in Finder mid-session does nothing, since
// opening files is exactly what a session is there to watch.
//
// Only ⌥ and clicks are watched all the time. Keys and scrolls matter only
// while ⌥ is held on its way to a start, so they are watched only then, and
// owl is not woken by every keystroke and scroll of the day.
//
// Needs Accessibility: global monitors are how one app sees another's keys.
@MainActor
final class Gesture {
    var holdSeconds: TimeInterval = 0.5
    var latchSeconds: TimeInterval = 1.5
    var doubleClickEnabled = true

    private let onStart: (_ latched: Bool) -> Void
    private let onStop: () -> Void
    private let onLatch: () -> Void
    /// ⌥ and clicks, for as long as the gesture is on.
    private var monitors: [Any] = []
    /// Keys, right clicks and scrolls, while a hold of ⌥ is armed.
    private var interrupts: [Any] = []
    private var armTask: Task<Void, Never>?
    private var latchTask: Task<Void, Never>?
    private var optionDown = false
    private var started = false
    private var latched = false

    init(onStart: @escaping (_ latched: Bool) -> Void, onStop: @escaping () -> Void,
         onLatch: @escaping () -> Void = {}) {
        self.onStart = onStart
        self.onStop = onStop
        self.onLatch = onLatch
    }

    var isRunning: Bool { started }

    /// The session was ended from outside the gesture (the X on the pill, the
    /// menu). Drop the state so the next press is a fresh start.
    func abandon() {
        disarm()
        started = false
        latched = false
    }

    static var trusted: Bool { AXIsProcessTrusted() }

    @discardableResult
    static func requestTrust() -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        return AXIsProcessTrustedWithOptions(opts as CFDictionary)
    }

    func start() {
        stop()
        monitors = watch([.flagsChanged, .leftMouseDown])
        Log.line("gesture watching (accessibility trusted: \(Self.trusted))")
    }

    /// A global and a local monitor for `mask`. Handled synchronously: these
    /// arrive on the main thread already, and a hop through a Task makes the
    /// release feel stuck. The local monitor sees events in owl's own windows
    /// (the menu, the pill, the drawing layer); a double-click there is never
    /// the gesture.
    private func watch(_ mask: NSEvent.EventTypeMask) -> [Any] {
        var out: [Any] = []
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] e in
            MainActor.assumeIsolated { self?.handle(e, inOwl: false) }
        }) { out.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in
            MainActor.assumeIsolated { self?.handle(e, inOwl: true) }
            return e
        }) { out.append(l) }
        return out
    }

    func stop() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors = []
        disarm()
        if started { started = false; latched = false; onStop() }
        latched = false
        optionDown = false
    }

    private func handle(_ event: NSEvent, inOwl: Bool) {
        if event.type == .leftMouseDown, event.clickCount == 2, !inOwl { doubleClick(event) }
        guard event.type == .flagsChanged else {
            if !started { disarm() }
            return
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let option = flags.contains(.option)
        let others = flags.intersection([.command, .control, .shift, .capsLock])

        if !option {
            optionDown = false
            disarm()
            if started {
                if latched {
                    Log.line("⌥ released, session latched")
                } else {
                    started = false
                    Log.line("⌥ released")
                    onStop()
                }
            }
            return
        }
        if !others.isEmpty && !started {
            disarm()
            return
        }
        guard !optionDown else { return }
        optionDown = true
        if started {
            if latched {
                // The stop for a latched session, on the way down, and no
                // arm() so this same hold cannot become a new session.
                latched = false
                started = false
                Log.line("⌥ pressed — latched session stopped")
                onStop()
            }
            return
        }
        arm()
    }

    private func doubleClick(_ event: NSEvent) {
        guard doubleClickEnabled else { return }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock)
        guard mods.isEmpty else { return }
        guard TextProbe.editable(at: NSEvent.mouseLocation) else { return }
        if started {
            guard latched else { return }
            latched = false
            started = false
            Log.line("double-click in a text field — session stopped")
            onStop()
            return
        }
        disarm()
        started = true
        latched = true
        Log.line("double-click in a text field — session running")
        onStart(true)
    }

    private func arm() {
        disarm()
        interrupts = watch([.keyDown, .rightMouseDown, .scrollWheel])
        let wait = holdSeconds
        armTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled, let self, self.optionDown, !self.started else { return }
            self.started = true
            self.armTask = nil
            self.onStart(false)
        }
        let latchWait = latchSeconds
        latchTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(latchWait))
            guard !Task.isCancelled, let self, self.optionDown, self.started, !self.latched else { return }
            self.latched = true
            self.latchTask = nil
            Log.line("session latched after \(latchWait)s hold")
            self.onLatch()
        }
    }

    private func disarm() {
        armTask?.cancel(); armTask = nil
        latchTask?.cancel(); latchTask = nil
        for m in interrupts { NSEvent.removeMonitor(m) }
        interrupts = []
    }
}

// Is the thing under the pointer somewhere you can type? Asked of the app
// under the cursor through the accessibility tree, on the spot: the gesture
// has to answer the double-click it is looking at.
enum TextProbe {
    private static let textRoles: Set<String> = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole]

    /// `point` in AppKit's screen coordinates, as NSEvent has it.
    static func editable(at point: CGPoint) -> Bool {
        guard let hit = AX.element(at: Space.fromCocoa(point)) else { return false }
        var element: AXUIElement? = hit
        for _ in 0..<3 {
            guard let e = element else { return false }
            if isEditableText(e) { return true }
            element = AX.parent(of: e)
        }
        return false
    }

    static func isEditableText(_ e: AXUIElement) -> Bool {
        if let role = AX.string(e, kAXRoleAttribute), textRoles.contains(role) {
            return AX.settable(e, kAXValueAttribute)
        }
        return AX.copy(e, kAXSelectedTextRangeAttribute) != nil && AX.settable(e, kAXValueAttribute)
    }
}
