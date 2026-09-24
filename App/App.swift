import AppKit
import Foundation
import CarKit

// The app: an ordinary Mac app with one window (MainWindow.swift): the
// sessions, each read as a script, and Settings. It is in the Dock and the app
// switcher, has its own menu bar (MainMenu.swift), and also a 🏎️ in the menu
// bar (StatusMenu.swift) for starting, stopping and marking while working in
// other apps. Sessions are Recorder.swift's; the keys are Keys.swift's.
//
// Closing the window leaves car running, and recording if it was: the Dock
// icon or the 🏎️ menu opens it again. Quitting (⌘Q, the menus, or a plain
// `kill`) closes the session being recorded properly first; ⌘Q and the menus
// ask before ending a recording.
@MainActor
final class App: NSObject, NSApplicationDelegate {
    let recorder = Recorder()
    private(set) lazy var keys = Keys { [weak self] gesture in self?.handle(gesture) }
    private var status: StatusMenu?
    private var window: MainWindow?
    private let watchdog = Watchdog()
    private var terminate: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.regular)
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
        watchdog.start()
        Log.line("\(Config.name) \(Config.version) up (accessibility \(Keys.trusted), mic \(Mic.permissionGranted), " +
                 "screen \(Screenshot.hasPermission))")
        linkCommand()
        recorder.finishOrphans()
        showWindow()
    }

    func applicationWillTerminate(_ note: Notification) {
        recorder.stopNow()
    }

    /// The Dock icon clicked, or car.app opened again while running.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showWindow()
        return false
    }

    /// Closing the window leaves car running, recording if it was.
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

    /// The window, made when it is needed and let go of when it closes.
    private func open(_ page: Library.Page?) {
        let w = window ?? MainWindow(app: self)
        if window == nil {
            window = w
            w.onClose = { [weak self] in
                // Let go after AppKit is done closing it.
                DispatchQueue.main.async { self?.window = nil }
            }
        }
        w.show(page)
    }

    // MARK: - actions from the menus

    @objc func showWindow() { open(nil) }
    @objc func showSettings() { open(.settings) }
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
