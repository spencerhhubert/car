import AppKit
import CarKit
import SwiftUI

// The sessions window: the sessions down the side, newest first, and the one
// picked read as a script (ScriptView.swift). A session being recorded reads
// live. AppKit makes the window, the split and the toolbar; SwiftUI draws
// what is in the two panes, from two models the window owns.
@MainActor
final class SessionsWindow: NSWindowController, NSToolbarDelegate, NSToolbarItemValidation {
    let library: Library
    let script: ScriptModel
    private var titling: Task<Void, Never>?

    private static let copyItem = NSToolbarItem.Identifier("copy")
    private static let revealItem = NSToolbarItem.Identifier("reveal")

    init() {
        let library = Library()
        let script = ScriptModel()
        self.library = library
        self.script = script
        let split = NSSplitViewController()
        let sidebar = NSSplitViewItem(sidebarWithViewController: host(SessionList(library: library)))
        sidebar.minimumThickness = Metrics.sidebar.min
        sidebar.maximumThickness = Metrics.sidebar.max
        let detail = NSSplitViewItem(viewController: host(ScriptPane(library: library, model: script)))
        detail.minimumThickness = Metrics.sessionsWindowMin.width - Metrics.sidebar.min
        split.splitViewItems = [sidebar, detail]

        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Metrics.sessionsWindow),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = split
        window.title = "Sessions"
        window.minSize = Metrics.sessionsWindowMin
        window.toolbarStyle = .unified
        window.setContentSize(Metrics.sessionsWindow)
        if !window.setFrameUsingName("car.sessions") { window.center() }
        window.setFrameAutosaveName("car.sessions")
        super.init(window: window)

        let toolbar = NSToolbar(identifier: "car.sessions")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar

        // The window's title is the session in front, for the Window menu
        // and Mission Control.
        titling = Task { [weak self, library] in
            for await title in Observations({ library.selected.flatMap { $0.record.started.map(Format.session) } }) {
                self?.window?.title = title ?? "Sessions"
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("not from a nib") }

    /// The window closed: stop following the session list.
    func closed() {
        titling?.cancel()
        titling = nil
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
