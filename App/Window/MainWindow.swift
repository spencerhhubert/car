import AppKit
import CarKit
import Observation
import SwiftUI

// car's window: the sessions down the side, newest first, with Settings at
// the foot of the sidebar; the main pane shows the page picked (Detail.swift).
// AppKit makes the window, the split and the toolbar; SwiftUI draws the
// sidebar's list and each piece inside the panes. The window exists while it
// is open: closing it stops everything it was reading, and the app (and any
// recording) carries on.
@MainActor
final class MainWindow: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSToolbarItemValidation {
    let library: Library
    private let detail: DetailController
    private var titling: Task<Void, Never>?
    /// Told when the window has closed.
    var onClose: () -> Void = {}

    private static let copyItem = NSToolbarItem.Identifier("copy")
    private static let revealItem = NSToolbarItem.Identifier("reveal")

    init(app: App) {
        let library = Library()
        self.library = library
        detail = DetailController(library: library, script: ScriptModel(), settings: SettingsModel(app: app))

        let split = NSSplitViewController()
        let sidebar = NSSplitViewItem(sidebarWithViewController: host(Sidebar(library: library)))
        sidebar.minimumThickness = Metrics.sidebar.min
        sidebar.maximumThickness = Metrics.sidebar.max
        let main = NSSplitViewItem(viewController: detail)
        main.minimumThickness = Metrics.windowMin.width - Metrics.sidebar.min
        split.splitViewItems = [sidebar, main]

        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Metrics.window),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = split
        window.title = Config.name
        window.minSize = Metrics.windowMin
        window.toolbarStyle = .unified
        window.setContentSize(Metrics.window)
        if !window.setFrameUsingName("car.main") { window.center() }
        window.setFrameAutosaveName("car.main")
        super.init(window: window)
        window.delegate = self

        let toolbar = NSToolbar(identifier: "car.main")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar

        detail.start()
        // The window's title is the page in front, for the Window menu and
        // Mission Control.
        titling = Task { [weak self, library] in
            for await title in Observations({ () -> String in
                switch library.page {
                case .settings: return "Settings"
                case .session: return library.selected?.record.started.map(Format.session) ?? Config.name
                case nil: return Config.name
                }
            }) {
                self?.window?.title = title
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("not from a nib") }

    /// Bring the window to the front, on `page` if one is given.
    func show(_ page: Library.Page? = nil) {
        if let page { library.page = page }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func windowWillClose(_ note: Notification) {
        detail.stop()
        titling?.cancel()
        titling = nil
        onClose()
    }

    // MARK: - the toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, Self.copyItem, Self.revealItem]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let (symbol, label, help, action): (String, String, String, Selector)
        switch id {
        case Self.copyItem:
            (symbol, label, help, action) = ("doc.on.clipboard", "Copy for Agent",
                                             "Copy the line that hands this session to an agent", #selector(copyForAgent))
        case Self.revealItem:
            (symbol, label, help, action) = ("folder", "Show in Finder", "Show this session's files in Finder",
                                             #selector(revealInFinder))
        default:
            return nil
        }
        let item = NSToolbarItem(itemIdentifier: id)
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.label = label
        item.toolTip = help
        item.target = self
        item.action = action
        item.isBordered = true
        return item
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool { library.selectedID != nil }

    @objc private func copyForAgent() {
        guard let id = library.selectedID else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Pointer.session(id), forType: .string)
    }

    @objc private func revealInFinder() {
        guard let id = library.selectedID else { return }
        NSWorkspace.shared.activateFileViewerSelecting([Session.dir(id)])
    }
}

/// A SwiftUI view in an AppKit pane. The pane's size is AppKit's to decide:
/// a hosting controller that also sizes its window from its content fights
/// the split view over it.
@MainActor
func host(_ view: some View) -> NSViewController {
    let c = NSHostingController(rootView: view)
    c.sizingOptions = []
    return c
}
