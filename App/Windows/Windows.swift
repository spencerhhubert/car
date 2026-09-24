import AppKit
import CarKit

// car's two windows, the sessions and the settings, and what having one open
// does to the app: while either is open car is in the Dock and the app
// switcher, with its own menu bar; when the last closes it goes back to the
// menu bar alone. A window exists only while it is open: closing one lets go
// of it and of everything it was reading.
@MainActor
final class Windows: NSObject, NSWindowDelegate {
    private unowned let app: App
    private var sessions: SessionsWindow?
    private var settings: SettingsWindow?

    init(app: App) { self.app = app }

    func showSessions() {
        let w = sessions ?? SessionsWindow()
        sessions = w
        present(w.window)
    }

    func showSettings() {
        let w = settings ?? SettingsWindow(app: app)
        settings = w
        present(w.window)
    }

    private func present(_ window: NSWindow?) {
        guard let window else { return }
        window.delegate = self
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func windowWillClose(_ note: Notification) {
        guard let window = note.object as? NSWindow else { return }
        if window === sessions?.window { sessions?.closed() }
        // Let go after AppKit is done closing it.
        DispatchQueue.main.async { [self] in
            if window === sessions?.window { sessions = nil }
            if window === settings?.window { settings = nil }
            if sessions == nil, settings == nil { NSApp.setActivationPolicy(.accessory) }
        }
    }
}
