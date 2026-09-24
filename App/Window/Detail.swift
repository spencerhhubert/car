import AppKit
import CarKit
import Observation
import SwiftUI

// The window's main pane: the session picked in the sidebar (its script),
// Settings, or, before there is anything, a word saying how to start. All
// three are built when the window opens and kept, and the pane shows one at a
// time, so picking a page shows it at once. A page not on show does no work:
// the script stops reading, and Settings reads its numbers only when shown.
@MainActor
final class DetailController: NSViewController {
    private let library: Library
    private let script: ScriptController
    private let settingsModel: SettingsModel
    private let settings: NSViewController
    private let empty = host(ContentUnavailableView("No Sessions", systemImage: "waveform",
                                                    description: Text("Hold ⌘ and tap ⌥ twice to start one.")))
    private var watching: Task<Void, Never>?

    init(library: Library, script: ScriptModel, settings: SettingsModel) {
        self.library = library
        self.script = ScriptController(model: script)
        settingsModel = settings
        self.settings = host(SettingsView(model: settings))
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not from a nib") }

    override func loadView() {
        view = NSView()
        for child in [script, settings, empty] {
            addChild(child)
            child.view.frame = view.bounds
            child.view.autoresizingMask = [.width, .height]
            child.view.isHidden = true
            view.addSubview(child.view)
        }
    }

    func start() {
        guard watching == nil else { return }
        _ = view
        watching = Task { [weak self, library] in
            for await (page, loaded) in Observations({ (library.page, library.loaded) }) {
                self?.show(page, loaded: loaded)
            }
        }
    }

    func stop() {
        watching?.cancel()
        watching = nil
        script.stop()
    }

    private func show(_ page: Library.Page?, loaded: Bool) {
        switch page {
        case .session(let id):
            only(script)
            script.show(id)
        case .settings:
            script.stop()
            only(settings)
            settingsModel.reload()
        case nil:
            script.stop()
            only(loaded ? empty : nil)
        }
    }

    /// Show `child` and hide the others.
    private func only(_ child: NSViewController?) {
        for c in [script, settings, empty] { c.view.isHidden = c !== child }
    }
}
