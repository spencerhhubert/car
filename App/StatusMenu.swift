import AppKit
import CarKit

// The 🏎️ in the menu bar and its menu, kept short: the session (start, or
// stop, pause, marker and discard while one records), the window, Settings,
// quit.
// Everything that is a setting lives in Settings.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    private unowned let app: App
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var watch: NSObjectProtocol?

    init(app: App) {
        self.app = app
        super.init()
        menu.delegate = self
        item.menu = menu
        title()
        watch = NotificationCenter.default.addObserver(forName: Recorder.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.title() }
        }
    }

    private func title() {
        let r = app.recorder.recording
        item.button?.title = (Config.isDev ? "🏎️dev" : "🏎️") + (r == nil ? "" : r?.paused == true ? "‖" : "●")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let recorder = app.recorder
        // Both copies see every tap of ⌥, so the dev copy's keys start off;
        // say so where it will be seen.
        if Config.isDev, !Config.load().keys {
            menu.addItem(disabled("Keys are off in \(Config.name): turn them on in Settings"))
            menu.addItem(.separator())
        }
        if let r = recorder.recording {
            menu.addItem(item("Stop Session (\(Render.clock(r.session.now).dropLast(4)))", #selector(App.toggleSession),
                              gesture: "⌘ ⌥ ⌥"))
            menu.addItem(item(r.paused ? "Resume Session" : "Pause Session", #selector(App.togglePause)))
            menu.addItem(item("Set Marker", #selector(App.setMarker), gesture: "⌥ ⌥"))
            menu.addItem(item("Discard Session…", #selector(App.discardSession)))
        } else {
            menu.addItem(item("Start Session", #selector(App.toggleSession), gesture: "⌘ ⌥ ⌥"))
        }
        if !recorder.finishing.isEmpty {
            menu.addItem(disabled(recorder.finishing.count == 1 ? "Transcribing the last of a session…"
                                                                : "Transcribing \(recorder.finishing.count) sessions…"))
        }
        menu.addItem(.separator())
        menu.addItem(item("Open \(Config.name)", #selector(App.showWindow)))
        let settings = item("Settings…", #selector(App.showSettings))
        settings.keyEquivalent = ","
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(item("Quit \(Config.name)", #selector(App.quit)))
    }

    /// An item, with the gesture that does the same set to the right the way
    /// a key equivalent would be: a gesture of taps is not one AppKit can
    /// show.
    private func item(_ title: String, _ action: Selector, gesture: String? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = app
        if let gesture {
            let tab = NSMutableParagraphStyle()
            tab.tabStops = [NSTextTab(textAlignment: .right, location: 230)]
            let s = NSMutableAttributedString(string: title, attributes: [.font: NSFont.menuFont(ofSize: 0),
                                                                          .paragraphStyle: tab])
            s.append(NSAttributedString(string: "\t" + gesture, attributes: [
                .font: NSFont.menuFont(ofSize: 0), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: tab,
            ]))
            i.attributedTitle = s
        }
        return i
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }
}
