import AppKit
import Carbon.HIToolbox
import OwlKit

// owl's two keys, and nothing else starts, stops or marks anything:
//
//   ⌘⇧R          start a session, or stop the one running. A system hot key:
//                owl owns the chord outright, so the app in front never sees
//                it (in a browser it would reload the page). Needs no grant.
//   ⌥ ⌥          two quick taps of ⌥ alone set a marker. Seen with global
//                monitors, so it needs Accessibility; a tap is ⌥ down and up
//                inside `tapLength` with nothing joining it, and the second
//                tap has to come inside the system's double-click interval.
//
// Only ⌥ itself is watched all the time. Keys, clicks and scrolls matter only
// while ⌥ is down (anything joining it spoils the tap), so they are watched
// only then, and owl is not woken by every keystroke of the day.
@MainActor
final class Keys {
    static let tapLength: TimeInterval = 0.35

    private let onToggle: () -> Void
    private let onMarker: () -> Void
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var monitors: [Any] = []
    private var interrupts: [Any] = []
    private var downAt: TimeInterval?
    private var spoiled = false
    private var lastTap: TimeInterval?

    init(onToggle: @escaping () -> Void, onMarker: @escaping () -> Void) {
        self.onToggle = onToggle
        self.onMarker = onMarker
    }

    static var trusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(opts as CFDictionary)
    }

    func start() {
        stop()
        registerHotKey()
        monitors = watch(.flagsChanged)
        Log.line("keys on: ⌘⇧R, ⌥ ⌥ (accessibility \(Self.trusted))")
    }

    func stop() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil
        handler = nil
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors = []
        endTap()
    }

    // MARK: - ⌘⇧R

    private func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, refcon in
            guard let refcon else { return noErr }
            let keys = Unmanaged<Keys>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { keys.onToggle() }
            return noErr
        }, 1, &spec, me, &handler)
        let id = EventHotKeyID(signature: 0x6F776C21 /* owl! */, id: 1)
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_R), UInt32(cmdKey | shiftKey), id,
                                         GetApplicationEventTarget(), 0, &hotKey)
        if status != noErr {
            Log.line("⌘⇧R is taken (OSStatus \(status)); start sessions from the menu")
            hotKey = nil
        }
    }

    // MARK: - ⌥ ⌥

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
        let others = !flags.intersection([.command, .control, .shift, .function]).isEmpty
        let now = ProcessInfo.processInfo.systemUptime
        if option, downAt == nil {
            downAt = now
            spoiled = others
            interrupts = watch([.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel])
        } else if option, others {
            spoiled = true
        } else if !option, let down = downAt {
            let tap = !spoiled && !others && now - down <= Self.tapLength
            endTap()
            guard tap else {
                lastTap = nil
                return
            }
            if let last = lastTap, now - last <= NSEvent.doubleClickInterval {
                lastTap = nil
                onMarker()
            } else {
                lastTap = now
            }
        }
    }

    private func endTap() {
        downAt = nil
        for m in interrupts { NSEvent.removeMonitor(m) }
        interrupts = []
    }
}
