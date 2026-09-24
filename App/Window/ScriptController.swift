import AppKit
import CarKit
import Observation
import SwiftUI

// The script, as a table: AppKit scrolls it, and AppKit asks each row's
// height before drawing it (ScriptLayout.swift), so no scroll, resize or
// update ever waits on SwiftUI working out how big something is. Each row is
// a SwiftUI view (ScriptView.swift) in a reused cell, drawn inside the height
// it was given.
//
// A session being recorded grows at the bottom; if the table was at the
// bottom it stays there. A picture opens over the table (PictureViewer).
//
// Nothing here changes the table while AppKit is laying it out. A new width
// is noticed on the clip view and acted on at the next turn of the run loop,
// and a row's SwiftUI view never asks its way up to the table (no safe
// area): the first script hung when a row, laid out inside the table's
// layout, made the table tile, which reported a new width, which reloaded
// every row inside that same layout, round and round.
@MainActor
final class ScriptController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let model: ScriptModel
    private let scroll = NSScrollView()
    private let table = NSTableView()
    private var lines: [ScriptLine] = []
    private var layout = ScriptLayout(width: 0)
    /// Heights by line id, for `layout`.
    private var heights: [String: CGFloat] = [:]
    private var shown: String?
    private var following: Task<Void, Never>?
    private var watching: Task<Void, Never>?
    private var overlay: NSView?
    private var overlaid: (viewing: Int?, missing: Bool) = (nil, false)
    private var currentID: String?
    /// A new width is waiting to be laid out.
    private var widthChanged = false

    init(model: ScriptModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not from a nib") }

    override func loadView() {
        let column = NSTableColumn(identifier: .init("line"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.intercellSpacing = .zero
        table.selectionHighlightStyle = .none
        table.gridStyleMask = []
        table.backgroundColor = .textBackgroundColor
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.focusRingType = .none
        table.dataSource = self
        table.delegate = self
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        // Always there: with a mouse attached the scroller takes room, and
        // one that came and went with the script's length would change the
        // rows' width, and every row's height with it.
        scroll.autohidesScrollers = false
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        scroll.contentView.postsBoundsChangedNotifications = false
        scroll.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(resized), name: NSView.frameDidChangeNotification,
                                               object: scroll.contentView)
        view = scroll
    }

    /// Show session `id`, and follow it while it is live.
    func show(_ id: String) {
        guard shown != id || following == nil else { return }
        shown = id
        following?.cancel()
        following = Task { [model] in await model.follow(id) }
        watch()
    }

    /// Stop reading: the pane shows something else, or the window closed.
    func stop() {
        following?.cancel()
        following = nil
        watching?.cancel()
        watching = nil
        shown = nil
        overlaid = (nil, false)
        overlay?.removeFromSuperview()
        overlay = nil
    }

    private func watch() {
        guard watching == nil else { return }
        watching = Task { [weak self, model] in
            for await (_, viewing, missing) in Observations({ (model.revision, model.viewing, model.missing) }) {
                self?.update()
                self?.showOverlay(viewing: viewing, missing: missing)
            }
        }
    }

    // MARK: - the rows

    private func update() {
        guard let s = model.script else {
            lines = []
            table.reloadData()
            return
        }
        let wasAtBottom = atBottom
        let newSession = lines.isEmpty || s.id != currentID
        let width = scroll.contentView.bounds.width
        if abs(width - layout.width) > 0.5 {
            layout = ScriptLayout(width: width)
            heights = [:]
        }
        currentID = s.id
        // A row that did not change keeps its height; the footer's words
        // change with the session.
        let old = Dictionary(lines.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        lines = [.header] + s.rows.map(ScriptLine.row) + [.footer]
        let now = Dictionary(lines.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        heights = heights.filter { id, _ in id != "footer" && old[id] != nil && old[id] == now[id] }
        table.reloadData()
        if newSession {
            // A live session opens at its newest; a finished one at its start.
            if s.status == .recording { scrollToEnd() } else { table.scrollRowToVisible(0) }
        } else if s.status == .recording, wasAtBottom {
            scrollToEnd()
        }
    }

    private var atBottom: Bool {
        let clip = scroll.contentView.bounds
        return clip.maxY >= table.frame.height - 60
    }

    private func scrollToEnd() {
        guard !lines.isEmpty else { return }
        table.scrollRowToVisible(lines.count - 1)
    }

    /// The clip view changed size, in the middle of a layout pass: lay the
    /// rows out again once it is over.
    @objc private func resized() {
        guard !widthChanged else { return }
        widthChanged = true
        DispatchQueue.main.async { [weak self] in self?.relayout() }
    }

    private func relayout() {
        widthChanged = false
        let width = scroll.contentView.bounds.width
        guard abs(width - layout.width) > 0.5 else { return }
        let wasAtBottom = atBottom
        layout = ScriptLayout(width: width)
        heights = [:]
        table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<lines.count))
        table.reloadData()
        if wasAtBottom, model.script?.status == .recording { scrollToEnd() }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { lines.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard lines.indices.contains(row), let s = model.script else { return 1 }
        let line = lines[row]
        if let h = heights[line.id] { return h }
        let h = max(1, line.height(in: layout, script: s, expanded: model.expanded.contains(line.id)))
        heights[line.id] = h
        return h
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard lines.indices.contains(row), let s = model.script else { return nil }
        let line = lines[row]
        let cell = tableView.makeView(withIdentifier: LineCell.id, owner: nil) as? LineCell ?? LineCell()
        cell.show(LineView(line: line, script: s, layout: layout, expanded: model.expanded.contains(line.id),
                           open: { [weak self] in self?.model.viewing = $0 },
                           expand: { [weak self] in self?.expand(line.id) }))
        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    private func expand(_ id: String) {
        model.expand(id)
        heights[id] = nil
        guard let i = lines.firstIndex(where: { $0.id == id }) else { return }
        table.noteHeightOfRows(withIndexesChanged: [i])
        table.reloadData(forRowIndexes: [i], columnIndexes: [0])
    }

    // MARK: - over the table

    /// The picture viewer, or a word that the session is gone.
    private func showOverlay(viewing: Int?, missing: Bool) {
        guard viewing != overlaid.viewing || missing != overlaid.missing else { return }
        overlaid = (viewing, missing)
        overlay?.removeFromSuperview()
        overlay = nil
        let content: AnyView?
        if viewing != nil, let s = model.script {
            let binding = Binding(get: { [model] in model.viewing }, set: { [model] in model.viewing = $0 })
            content = AnyView(PictureViewer(script: s, viewing: binding))
        } else if missing {
            content = AnyView(ContentUnavailableView("No Such Session", systemImage: "questionmark.folder",
                                                     description: Text("It was discarded or removed.")))
        } else {
            content = nil
        }
        guard let content, let parent = view.superview else { return }
        let host = NSHostingView(rootView: content)
        host.sizingOptions = []
        host.frame = view.frame
        host.autoresizingMask = [.width, .height]
        parent.addSubview(host, positioned: .above, relativeTo: view)
        overlay = host
        view.window?.makeFirstResponder(host)
    }
}

/// A reused table cell holding one line's SwiftUI view, at the cell's size.
private final class LineCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("line")
    private let host = NSHostingView<LineView?>(rootView: nil)

    init() {
        super.init(frame: .zero)
        identifier = Self.id
        host.sizingOptions = []
        // A row has no safe area to keep out of, and asking for one walks up
        // to the table and makes it tile in the middle of its own layout.
        host.safeAreaRegions = []
        host.autoresizingMask = [.width, .height]
        host.frame = bounds
        addSubview(host)
    }

    required init?(coder: NSCoder) { fatalError("not from a nib") }

    func show(_ line: LineView) {
        host.rootView = line
    }
}
