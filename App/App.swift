import AppKit
import Foundation
import CarKit

// The app: the car in the menu bar (StatusMenu.swift), the keys, the
// sessions (Recorder.swift), and two windows (Windows/): the sessions, read
// as a script, and the settings.
//
// car lives in the menu bar. While one of its windows is open it is also an
// ordinary app, in the Dock and the app switcher with a menu bar of its own
// (MainMenu.swift); when the last one closes it goes back to the menu bar
// alone. Opening car.app while it runs opens the sessions window.
//
// Quitting (⌘Q, the menu, or a plain `kill`) closes the session being
// recorded properly first; ⌘Q and the menu ask before ending a recording.
@MainActor
final class App: NSObject, NSApplicationDelegate {
    let recorder = Recorder()
    private(set) lazy var keys = Keys { [weak self] gesture in self?.handle(gesture) }
    private(set) lazy var windows = Windows(app: self)
    private var status: StatusMenu?
    private var terminate: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.mainMenu = MainMenu.build(for: self)
        status = StatusMenu(app: self)
        if Config.load().keys { setKeys(on: true) }
        // `kill` is a quit like any other: the session being recorded is
        // closed, not cut off.
        signal(SIGTERM, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        term.setEventHandler { NSApp.terminate(nil) }
        term.resume()
        terminate = term
        Log.line("\(Config.name) \(Config.version) up (accessibility \(Keys.trusted), mic \(Mic.permissionGranted), " +
                 "screen \(Screenshot.hasPermission))")
        linkCommand()
        recorder.finishOrphans()
    }

    func applicationWillTerminate(_ note: Notification) {
        recorder.stopNow()
    }

    /// car.app opened again while running (Finder, Spotlight, the Dock). The
    /// pill counts as a visible window, so this does not ask.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        windows.showSessions()
        return false
    }

    /// Closing the windows leaves car in the menu bar, recording.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func handle(_ gesture: Keys.Gesture) {
        switch gesture {
        case .toggle: recorder.toggle()
        case .marker: recorder.marker()
        case .dictation: recorder.dictate()
        }
    }

    /// Whether car answers its keys; Settings turns them on and off.
    func setKeys(on: Bool) {
        if on {
            if !Keys.trusted { Keys.requestTrust() }
            keys.start()
        } else {
            keys.stop()
        }
    }

    // MARK: - actions from the menus

    @objc func showSessions() { windows.showSessions() }
    @objc func showSettings() { windows.showSettings() }
    @objc func toggleSession() { recorder.toggle() }
    @objc func setMarker() { recorder.marker() }
    @objc func discardSession() { recorder.discard() }

    /// Quit, asking first when that would end a recording.
    @objc func quit() {
        if let r = recorder.recording {
            let ask = NSAlert()
            ask.messageText = "Stop recording and quit?"
            ask.informativeText = "The session has been recording for \(Render.clock(r.session.now).dropLast(4)). "
                + "It is closed now and its last words are transcribed the next time \(Config.name) opens."
            ask.addButton(withTitle: "Quit")
            ask.addButton(withTitle: "Cancel")
            NSApp.activate()
            guard ask.runModal() == .alertFirstButtonReturn else { return }
        }
        NSApp.terminate(nil)
    }

    /// `car` (or `car-dev`) on the command line: a link in ~/.local/bin to
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
}
