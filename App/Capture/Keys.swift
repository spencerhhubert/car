import AppKit
import CarKit

// car's keys are one gesture, ⌥ tapped twice, and what is held with it says
// what it does. Nothing else starts, stops or marks anything:
//
//   ⌘ ⌥ ⌥    start a session, or stop the one running
//   ⌥ ⌥      set a marker
//   ⇧ ⌥ ⌥    quick dictation: what was just said, as text on the clipboard
//
// A tap is ⌥ down and up inside `tapLength` with nothing joining it; the
// second has to come inside the system's double-click interval, with the same
// key held (⌘, ⇧ or neither) through both. Taps are seen with global monitors,
// so they need Accessibility. Only the modifier keys are watched all the
// time. Keys, clicks and scrolls matter only while ⌥ is down (anything
// joining it spoils the tap), so they are watched only then, and car is not
// woken by every keystroke of the day.
@MainActor
final class Keys {
    enum Gesture { case toggle, marker, dictation }

    static let tapLength: TimeInterval = 0.35

    private let onGesture: (Gesture) -> Void
    private var monitors: [Any] = []
    private var interrupts: [Any] = []
    private var downAt: TimeInterval?
    /// ⌘ or ⇧, whichever was held when ⌥ went down.
    private var held: NSEvent.ModifierFlags = []
    private var spoiled = false
    private var lastTap: (at: TimeInterval, held: NSEvent.ModifierFlags)?

    init(onGesture: @escaping (Gesture) -> Void) {
        self.onGesture = onGesture
    }

    static var trusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(opts as CFDictionary)
    }

    func start() {
        stop()
        monitors = watch(.flagsChanged)
        Log.line("keys on: ⌘ ⌥ ⌥, ⌥ ⌥, ⇧ ⌥ ⌥ (accessibility \(Self.trusted))")
    }

    func stop() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors = []
        endTap()
        lastTap = nil
    }

    private func watch(_ mask: NSEvent.EventTypeMask) -> [Any] {
        var out: [Any] = []
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] e in
            MainActor.assumeIsolated { self?.handle(e) }
        }) { out.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in
            MainActor.assumeIsolated { self?.handle(e) }
            return e
        }) { out.append(l) }
        return out
    }

    private func handle(_ e: NSEvent) {
        guard e.type == .flagsChanged else {
            // Something joined ⌥ while it was down: not a tap.
            spoiled = true
            lastTap = nil
            return
        }
        let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let option = flags.contains(.option)
        let with = flags.intersection([.command, .shift])
        // ⌃ and fn never go with a tap, and neither do ⌘ and ⇧ together.
        let wrong = !flags.intersection([.control, .function]).isEmpty || with == [.command, .shift]
        let now = ProcessInfo.processInfo.systemUptime
        if option, downAt == nil {
            downAt = now
            held = with
            spoiled = wrong
            interrupts = watch([.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel])
        } else if option {
            // Another modifier went down or up while ⌥ was: not a tap.
            if with != held || wrong { spoiled = true }
        } else if let down = downAt {
            let tap = !spoiled && !wrong && with == held && now - down <= Self.tapLength
            let key = held
            endTap()
            guard tap else {
                lastTap = nil
                return
            }
            if let last = lastTap, last.held == key, now - last.at <= NSEvent.doubleClickInterval {
                lastTap = nil
                onGesture(key.contains(.command) ? .toggle : key.contains(.shift) ? .dictation : .marker)
            } else {
                lastTap = (now, key)
            }
        }
    }

    private func endTap() {
        downAt = nil
        for m in interrupts { NSEvent.removeMonitor(m) }
        interrupts = []
    }
}
