import Foundation

// A session laid out for a person to read, the way the sessions window shows
// it: a script, one row per moment, each with what was said, what was done
// around it, and the pictures taken then.
//
// A row is one of three things:
//   - a remark (words grouped as the timeline groups them, Render.swift) with
//     the events from a moment before it starts to a few seconds after it
//     ends: "near it";
//   - where nothing was said, a stretch of events on their own, ended by a
//     pause or by running long;
//   - a marker.
// Where the words are still to come (a chunk still recording, or closed and
// waiting for its words) or will not come (failed, lost), the rows there say
// so, and a chunk still to come always has a row, so a live session reads
// true up to the moment.
//
// ScriptReader keeps one session's script current while it grows, asking the
// catalog only for what changed since its last read.
public struct Script: Sendable {
    public enum Status: Sendable, Equatable {
        case recording
        /// Stopped, with this many chunks still to transcribe.
        case transcribing(Int)
        case done
        case failed(String)

        public var isLive: Bool {
            switch self {
            case .recording, .transcribing: true
            case .done, .failed: false
            }
        }
    }

    public let id: String
    public let started: Date?
    public let status: Status
    /// On the session clock: its length once stopped, how far it had got
    /// when read while recording.
    public let length: Int
    public let rows: [Row]
    /// Every picture, in order: what the picture viewer steps through.
    public let pictures: [Picture]
    public let words: Int
    public let markers: Int
    /// Dollars spent transcribing it.
    public let cost: Double

    /// The wall time of a moment on the session clock, which keeps counting
    /// through sleep.
    public func date(_ t: Int) -> Date? { started.map { $0.addingTimeInterval(Double(t) / 1000) } }
}

extension Script {
    public struct Row: Sendable, Identifiable, Equatable {
        /// What the words column shows.
        public enum Speech: Sendable, Equatable {
            /// A remark; a mark drawn while it was said sits in it in braces,
            /// "{red circle 1}".
            case said(String)
            /// Nothing was said.
            case quiet
            /// The words here are still to come: the chunk is recording, or
            /// closed and waiting for its words. `first` is the chunk's first row.
            case recording(first: Bool)
            case transcribing(first: Bool)
            /// The words here will not come without asking again.
            case failed(String, first: Bool)
            case lost(first: Bool)
        }

        public let id: String
        public let start: Int
        public internal(set) var end: Int
        public internal(set) var speech: Speech
        /// Set on a marker's row, which has nothing else.
        public internal(set) var marker: Marker?
        public internal(set) var actions: [Action] = []
        public internal(set) var pictures: [Picture] = []
        /// How long nothing happened before this row, when that was long.
        public internal(set) var gapBefore: Int?
    }

    public struct Marker: Sendable, Equatable {
        public let n: Int
        /// The wall time it was set at.
        public let at: Date?
    }

    /// Something done, in a person's words: "Clicked “Save”", "button in Safari".
    public struct Action: Sendable, Identifiable, Equatable {
        public enum Kind: String, Sendable {
            case app, window, page, finder, click, key, typed, select, scroll, mark, clear, desk, dictation
        }

        /// The event's id, which is the first of a run of the same action.
        public let id: Int
        public let t: Int
        public let kind: Kind
        public let text: String
        public internal(set) var detail: String?
        /// The app it happened in.
        public let app: String?
        /// A mark's ink.
        public let ink: Ink?
        /// How many times in a row it happened.
        public internal(set) var count = 1
    }

    public struct Picture: Sendable, Identifiable, Equatable {
        /// The catalog's id for the file.
        public let id: Int
        public let t: Int
        public let url: URL
        /// Why it was taken: "click", "app", or the name of the mark it shows.
        public let why: String

        /// Why it was taken, for a caption.
        public var reason: String {
            switch why {
            case "app": "app came to the front"
            case "window": "window changed"
            case "page": "page changed"
            case "click": "after a click"
            case "scroll": "after a scroll"
            default: why
            }
        }
    }
}

/// An event as the catalog holds it.
struct Event {
    let id: Int
    let t: Int
    let kind: String
    let data: [String: Any]
}

extension Script {
    /// Events from `lead` before a remark starts to `tail` after it ends are
    /// near it.
    static let lead = 1500
    static let tail = 3000
    /// A row of events with nothing said ends at a pause this long, or once
    /// it spans `span`.
    static let pause = 15_000
    static let span = 60_000
    /// A gap this long between rows is shown.
    static let longGap = 120_000

    static func build(_ record: SessionRecord, chunks: [ChunkRecord], words: [Word], events: [Event],
                      markers: [MarkerRecord], files: [Int: URL], cost: Double) -> Script {
        let drawn = events.filter { $0.kind == "mark" }.compactMap { e -> (t: Int, name: String)? in
            (e.data["name"] as? String).map { (e.t, $0) }
        }
        let remarks = Render.remarks(words, marks: drawn, breaks: markers.map(\.t))
        let starts = remarks.map(\.start)
        let markerTimes = markers.map(\.t)

        // Everything that happened, as actions and pictures, in order.
        enum Item { case action(Action), picture(Picture) }
        var items: [(t: Int, item: Item)] = []
        var pictures: [Picture] = []
        for e in events {
            if e.kind == "shot" {
                guard let f = e.data["file"] as? Int, let url = files[f] else { continue }
                let p = Picture(id: f, t: e.t, url: url, why: e.data["why"] as? String ?? "")
                pictures.append(p)
                items.append((e.t, .picture(p)))
            } else if let a = action(e) {
                items.append((e.t, .action(a)))
            }
        }

        // Near a remark: the last remark starting (less the lead) at or before
        // t, if t is not past its tail and no marker lies between.
        func remark(near t: Int) -> Int? {
            var lo = 0, hi = starts.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if starts[mid] - lead <= t { lo = mid + 1 } else { hi = mid }
            }
            let i = lo - 1
            guard i >= 0, t <= remarks[i].end + tail else { return nil }
            let (a, b) = (min(t, starts[i]), max(t, starts[i]))
            return markerTimes.contains { $0 > a && $0 <= b } ? nil : i
        }

        // What the words column says at t: the chunk t falls in.
        struct Heard: Equatable { let speech: Row.Speech; let chunk: Int }
        func heard(at t: Int) -> Heard {
            guard let c = chunks.last(where: { $0.startMs <= t && t < ($0.endMs ?? .max) }) else {
                return Heard(speech: .quiet, chunk: 0)
            }
            switch c.state {
            case .recording: return Heard(speech: .recording(first: false), chunk: c.n)
            case .recorded: return Heard(speech: .transcribing(first: false), chunk: c.n)
            case .failed: return Heard(speech: .failed(c.error ?? "no reason recorded", first: false), chunk: c.n)
            case .lost: return Heard(speech: .lost(first: false), chunk: c.n)
            case .transcribed, .silent: return Heard(speech: .quiet, chunk: 0)
            }
        }

        var said = remarks.map { r in
            Row(id: "s\(r.start)", start: r.start, end: r.end, speech: .said(r.text))
        }
        // Rows where nothing was said, built in one sweep. A chunk still to
        // come, or whose words will not come, opens one even with nothing in
        // it.
        struct Open { var row: Row; var last: Int; let heard: Heard }
        var quiet: [(row: Row, chunk: Int)] = []
        var open: Open?
        func close() {
            if let o = open { quiet.append((o.row, o.heard.chunk)) }
            open = nil
        }
        var sweep: [(t: Int, item: Item?)] = []
        for c in chunks where !(c.state == .transcribed || c.state == .silent) { sweep.append((c.startMs, nil)) }
        for (t, item) in items {
            if let i = remark(near: t) {
                switch item {
                case .action(let a): append(a, to: &said[i].actions)
                case .picture(let p): said[i].pictures.append(p)
                }
                said[i].end = max(said[i].end, t)
            } else {
                sweep.append((t, item))
            }
        }
        sweep.sort { $0.t < $1.t }
        let breaks = (starts + markerTimes).sorted()
        for (t, item) in sweep {
            let v = heard(at: t)
            if let o = open {
                let between = breaks.contains { $0 > o.last && $0 <= t }
                if v != o.heard || between || t - o.last > pause || t - o.row.start > span { close() }
            }
            if open == nil {
                let row = Row(id: "q\(t)", start: t, end: t, speech: v.speech)
                open = Open(row: row, last: t, heard: v)
            }
            switch item {
            case .action(let a): append(a, to: &open!.row.actions)
            case .picture(let p): open!.row.pictures.append(p)
            case nil: break
            }
            open!.last = t
            open!.row.end = t
        }
        close()

        let marked = markers.map { m in
            Row(id: "m\(m.n)", start: m.t, end: m.t, speech: .quiet,
                marker: Marker(n: m.n, at: ISO8601DateFormatter().date(from: m.at)))
        }
        // A marker comes before anything at the same moment; a remark before
        // a quiet row.
        func rank(_ r: Row) -> Int { r.marker != nil ? 0 : (r.id.hasPrefix("s") ? 1 : 2) }
        var chunkOf: [String: Int] = [:]
        for q in quiet { chunkOf[q.row.id] = q.chunk }
        var rows = (said + quiet.map(\.row) + marked).sorted {
            $0.start != $1.start ? $0.start < $1.start : rank($0) < rank($1)
        }

        // The first row of each chunk still to come says what it is waiting
        // for; the rest only hold its place. Long gaps are marked.
        var seen = Set<Int>()
        var ids = Set<String>()
        var previousEnd: Int?
        for i in rows.indices {
            if let c = chunkOf[rows[i].id], c > 0 {
                let first = seen.insert(c).inserted
                switch rows[i].speech {
                case .recording: rows[i].speech = .recording(first: first)
                case .transcribing: rows[i].speech = .transcribing(first: first)
                case .failed(let why, _): rows[i].speech = .failed(why, first: first)
                case .lost: rows[i].speech = .lost(first: first)
                case .said, .quiet: break
                }
            }
            if let p = previousEnd, rows[i].start - p >= longGap { rows[i].gapBefore = rows[i].start - p }
            previousEnd = max(previousEnd ?? 0, rows[i].end)
            if !ids.insert(rows[i].id).inserted {
                let r = rows[i]
                rows[i] = Row(id: "\(r.id).\(i)", start: r.start, end: r.end, speech: r.speech, marker: r.marker,
                              actions: r.actions, pictures: r.pictures, gapBefore: r.gapBefore)
            }
        }

        let status: Status
        switch record.state {
        case .recording: status = .recording
        case .transcribing: status = .transcribing(chunks.filter { !$0.state.settled }.count)
        case .done: status = .done
        case .failed: status = .failed(record.error ?? "no reason recorded")
        }
        let reached = max(chunks.compactMap(\.endMs).max() ?? 0, events.last?.t ?? 0)
        return Script(id: record.id, started: record.started, status: status, length: record.lengthMs ?? reached,
                      rows: rows, pictures: pictures, words: words.count, markers: markers.count, cost: cost)
    }

    /// Add an action to a row's, folding it into the one before when it is
    /// the same again (a run of clicks on one button, a scroll), or the
    /// window of the app that just came to the front.
    static func append(_ a: Action, to actions: inout [Action]) {
        if var last = actions.last {
            if last.kind == a.kind, last.text == a.text, last.detail == a.detail {
                last.count += 1
                actions[actions.count - 1] = last
                return
            }
            if last.kind == .app, a.kind == .window, last.app == a.app, a.t - last.t < 1000, last.detail == nil {
                last.detail = a.text
                actions[actions.count - 1] = last
                return
            }
        }
        actions.append(a)
    }

    // MARK: - an event in a person's words

    /// What an event says for the actions column, or nil for the ones a
    /// person reading along does not need (focus moving, the session's own
    /// start and end, a mark fading). Pictures are not actions.
    static func action(_ e: Event) -> Action? {
        let d = e.data
        let app = d["app"] as? String
        let inApp = app.map { "in \($0)" }
        func make(_ kind: Action.Kind, _ text: String, _ detail: String? = nil, ink: Ink? = nil) -> Action {
            Action(id: e.id, t: e.t, kind: kind, text: text, detail: detail, app: app, ink: ink)
        }
        switch e.kind {
        case "app":
            return app.map { make(.app, "Switched to \($0)") }
        case "window":
            let title = (d["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "untitled window"
            return make(.window, short(title), app)
        case "page":
            let url = d["url"] as? String
            let title = (d["pageTitle"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? url ?? "a page"
            return make(.page, short(title), url.flatMap { URL(string: $0)?.host() } ?? url)
        case "finder":
            let picked = (d["selected"] as? [String] ?? []).map { ($0 as NSString).lastPathComponent }
            let folder = (d["folder"] as? String).map { ($0 as NSString).lastPathComponent }
            if picked.isEmpty { return make(.finder, folder.map { "Opened “\($0)”" } ?? "Finder", "in Finder") }
            let names = picked.prefix(3).joined(separator: ", ") + (picked.count > 3 ? " and \(picked.count - 3) more" : "")
            return make(.finder, "Selected \(names)", folder.map { "in “\($0)”" } ?? "in Finder")
        case "click":
            let count = d["count"] as? Int ?? 1
            let verb = count >= 2 ? "Double-clicked" : (d["button"] as? String == "right" ? "Right-clicked" : "Clicked")
            let el = d["element"]
            if let n = name(el) {
                return make(.click, "\(verb) “\(short(n, 48))”", [role(el), inApp].compactMap { $0 }.joined(separator: " "))
            }
            return make(.click, [verb, role(el)].compactMap { $0 }.joined(separator: " "), inApp)
        case "key":
            return (d["chord"] as? String).map { make(.key, $0, inApp) }
        case "typed":
            let n = d["keys"] as? Int ?? 0
            let into = name(d["field"]).map { "into “\(short($0, 40))”" }
            return make(.typed, "Typed \(n) key\(n == 1 ? "" : "s")", [into, inApp].compactMap { $0 }.joined(separator: " "))
        case "select":
            return (d["text"] as? String).map { make(.select, "Selected “\(short($0, 60))”", inApp) }
        case "scroll":
            return make(.scroll, "Scrolled", inApp)
        case "mark":
            let verb = ["arrow": "pointing at", "pen": "over"][d["tool"] as? String ?? ""] ?? "around"
            let on = name(d["element"]).map { "\(verb) “\(short($0, 40))”" }
            return make(.mark, "Drew \(d["name"] as? String ?? "a mark")", on,
                        ink: (d["color"] as? String).flatMap(Ink.init(rawValue:)))
        case "clear":
            return make(.clear, "Wiped the drawings", (d["names"] as? [String] ?? []).joined(separator: ", "))
        case "desk":
            let open = d["open"] as? String ?? app ?? "its view"
            return make(.desk, short(open), app)
        case "dictation":
            let n = d["words"] as? Int ?? 0
            return make(.dictation, "Copied what was just said", "\(n) word\(n == 1 ? "" : "s")")
        default:
            return nil
        }
    }

    /// An element's name: what a person would call it.
    private static func name(_ element: Any?) -> String? {
        guard let d = element as? [String: Any] else { return nil }
        for k in ["title", "description", "text", "placeholder", "help"] {
            if let s = d[k] as? String, !s.trimmingCharacters(in: .whitespaces).isEmpty { return s }
        }
        return nil
    }

    private static func role(_ element: Any?) -> String? {
        guard let d = element as? [String: Any], let r = d["role"] as? String else { return nil }
        if let sub = d["subrole"] as? String, let s = roles[sub] { return s }
        return roles[r] ?? r.replacingOccurrences(of: "AX", with: "").lowercased()
    }

    private static let roles = [
        "AXButton": "button", "AXTextField": "text field", "AXTextArea": "text area", "AXLink": "link",
        "AXStaticText": "text", "AXImage": "image", "AXMenuItem": "menu item", "AXMenuBarItem": "menu",
        "AXCheckBox": "checkbox", "AXRadioButton": "radio button", "AXPopUpButton": "pop-up button",
        "AXComboBox": "combo box", "AXTabGroup": "tabs", "AXRow": "row", "AXCell": "cell", "AXWebArea": "page",
        "AXGroup": "group", "AXScrollArea": "scroll area", "AXWindow": "window", "AXStandardWindow": "window",
        "AXToolbar": "toolbar", "AXSlider": "slider", "AXList": "list", "AXOutline": "outline", "AXTable": "table",
        "AXHeading": "heading", "AXSearchField": "search field", "AXSecureTextField": "password field",
        "AXTabButton": "tab", "AXSplitGroup": "split view", "AXDisclosureTriangle": "disclosure triangle",
    ]

    /// One line of at most `n` characters.
    static func short(_ s: String, _ n: Int = 80) -> String {
        let line = s.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return line.count <= n ? line : String(line.prefix(n - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

/// Keeps one session's script current while it grows. Each read asks the
/// catalog for the events added since the last one and for the chunks and
/// markers (a handful of rows), and reads the words again only when a chunk
/// changed; it builds the script only when something did.
public actor ScriptReader {
    public let id: String
    private var events: [Event] = []
    private var lastEvent = 0
    private var words: [Word] = []
    private var files: [Int: URL] = [:]
    private var seenChunks: String?
    private var seenRest: String?

    public init(id: String) { self.id = id }

    /// The script as it stands, or nil when nothing has changed since the
    /// last read (or there is no such session).
    public func read() -> Script? {
        guard let record = Session.record(id) else { return nil }
        let (id, after) = (id, lastEvent)
        let fresh: [Event] = (try? Catalog.shared.sync { h in
            h.rows("SELECT id, t, kind, data FROM events WHERE session = ? AND id > ? ORDER BY id", [id, after])
                .compactMap { r -> Event? in
                    guard let e = r.int("id"), let t = r.int("t"), let kind = r.text("kind"),
                          let data = r.text("data").flatMap({ try? JSONSerialization.jsonObject(with: Data($0.utf8)) })
                              as? [String: Any] else { return nil }
                    return Event(id: e, t: t, kind: kind, data: data)
                }
        }) ?? []
        let chunks = Session.chunks(id)
        let markers = Session.markers(id)
        let chunkState = chunks.map { "\($0.n):\($0.state.rawValue):\($0.endMs ?? -1)" }.joined(separator: ",")
        let rest = "\(record.state.rawValue)|\(record.lengthMs ?? -1)|\(markers.count)"
        let chunksChanged = chunkState != seenChunks
        guard !fresh.isEmpty || chunksChanged || rest != seenRest else { return nil }
        (seenChunks, seenRest) = (chunkState, rest)

        if !fresh.isEmpty {
            lastEvent = fresh.map(\.id).max() ?? lastEvent
            events += fresh
            // An event carries the moment it happened, not the moment it was
            // written, so the newest can land before older ones.
            events.sort { $0.t != $1.t ? $0.t < $1.t : $0.id < $1.id }
            if fresh.contains(where: { $0.kind == "shot" }) { files = Session.files(id, kind: "shot") }
        }
        if chunksChanged { words = Session.words(id) }
        return Script.build(record, chunks: chunks, words: words, events: events, markers: markers, files: files,
                            cost: Usage.total(session: id).cost)
    }
}
