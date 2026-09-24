import AppKit
import CarKit
import Observation
import SwiftUI

// The window's main pane: the session picked in the sidebar (its script),
// Settings, or, before there is anything, a word saying how to start. It
// follows the sidebar's page and shows one child at a time; a child it is not
// showing does no work.
@MainActor
final class DetailController: NSViewController {
    private let library: Library
    private let script: ScriptController
    private let settings: NSViewController
    private let empty = host(ContentUnavailableView("No Sessions", systemImage: "waveform",
                                                    description: Text("Hold ⌘ and tap ⌥ twice to start one.")))
    private var watching: Task<Void, Never>?

    init(library: Library, script: ScriptModel, settings: SettingsModel) {
        self.library = library
        self.script = ScriptController(model: script)
        self.settings = host(SettingsView(model: settings))
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not from a nib") }

    override func loadView() { view = NSView() }

    func start() {
        guard watching == nil else { return }
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
            put(script)
            script.show(id)
        case .settings:
            script.stop()
            put(settings)
        case nil:
            script.stop()
            put(loaded ? empty : nil)
        }
    }

    /// Make `child` the one on show.
    private func put(_ child: NSViewController?) {
        guard child == nil || child?.parent !== self else { return }
        for c in children {
            c.view.removeFromSuperview()
            c.removeFromParent()
        }
        guard let child else { return }
        addChild(child)
        child.view.frame = view.bounds
        child.view.autoresizingMask = [.width, .height]
        view.addSubview(child.view)
    }
}
