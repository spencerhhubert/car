import Foundation

// The timeline: what was said and done, in order, one line per thing, for
// the whole session or a stretch of it.
//
// Words come grouped into remarks (a pause or a marker ends one); everything
// else is an event. A mark drawn while a remark was being said also appears
// inside it, in braces, at the word it was drawn at: "this part here
// {red circle 1} is wrong". A marker is a line of its own. Times are on the
// session clock. Pictures are named by where they are now, so a reader opens
// the one it needs.
public enum Render {
    /// The whole session, to session.md in its folder.
    public static func write(id: String) throws {
        try text(id: id).write(to: Session.dir(id).appending(path: "session.md"), atomically: true, encoding: .utf8)
    }

    /// The session from `from` to `to` (session ms). `about` says what the
    /// stretch is, for the header ("since marker 2").
    public static func text(id: String, from: Int = 0, to: Int? = nil, about: String? = nil) -> String {
        guard let s = Session.record(id) else { return "no session \(id)\n" }
        let chunks = Session.chunks(id)
        let markers = Session.markers(id)
        let length = s.lengthMs ?? chunks.compactMap(\.endMs).max() ?? 0
        let to = to ?? .max
        let events = Session.events(id, from: from, to: to)
        let words = Session.words(id, from: from, to: to)
        let shots = Session.files(id, kind: "shot")
        let car = Config.name
        var lines = ["# car session \(id)", ""]

        var head: [String] = []
        if let started = s.started { head.append("started \(wall(started, zone: s.timeZone))") }
        head.append(clock(length) + " long")
        let heard = chunks.filter { $0.state == .transcribed }.count
        let open = chunks.filter { !$0.state.settled }.count
        head.append("\(chunks.count) chunk\(chunks.count == 1 ? "" : "s") of sound (\(heard) with words\(open > 0 ? ", \(open) still to come" : ""))")
        if !markers.isEmpty { head.append("\(markers.count) marker\(markers.count == 1 ? "" : "s")") }
        head.append("\(shots.count) pictures")
        let remote = Set(chunks.compactMap(\.remoteModel)).sorted()
        if !remote.isEmpty { head.append("words by \(remote.joined(separator: ", "))") }
        let local = Set(chunks.compactMap(\.localModel)).sorted()
        if !local.isEmpty { head.append("times by \(local.joined(separator: ", "))") }
        lines.append(head.joined(separator: " · "))

        switch s.state {
        case .recording:
            let reached = chunks.filter { $0.state.settled }.compactMap(\.endMs).max() ?? 0
            lines += ["", "Still recording. The words reach \(clock(reached)); later ones arrive a chunk at a time."]
        case .transcribing:
            lines += ["", "Stopped; the last chunks are still being transcribed."]
        case .failed:
            lines += ["", "Some of it could not be transcribed: \(s.error ?? "no reason recorded"). " +
                      "`\(car) transcribe \(id)` tries again."]
        case .done:
            break
        }
        if from > 0 || to < .max {
            let span = "\(clock(from))–\(to == .max ? "the end" : clock(to))"
            lines += ["", "This is \(about.map { "\($0), " } ?? "")\(span) of the session. " +
                      "More: `\(car) session \(id) --from start`, or `--from m<marker>`, `--from -30m`."]
        }
        for c in chunks where c.note != nil && c.state != .silent && c.startMs < to && (c.endMs ?? .max) > from {
            lines += ["", "Chunk \(c.n) (\(clock(c.startMs))): \(c.note!)"]
        }
        lines += ["", """
            How to read it: each line is a moment, [minutes:seconds.ms] from the start, on one clock for words and \
            events alike. Quoted lines are what was said; the rest is what happened on the screen. A marker line is \
            where the person handed the session to an agent. A drawing's name in braces inside a quote, like \
            {red circle 1}, is where in the sentence it was drawn; its own line says what it was drawn on, and it \
            is in the pictures, with its number, until the line that says it faded. Open the pictures the timeline \
            names. `\(car) events` and `\(car) words` print the full detail as JSON.
            """, "", "## timeline", ""]

        struct Line { let t: Int; let order: Int; let text: String }
        var rows: [Line] = []
        for (i, e) in events.enumerated() {
            guard let t = e["t"] as? Int, let d = describe(e, shots: shots) else { continue }
            rows.append(Line(t: t, order: i, text: "[\(clock(t))] \(d)"))
        }
        for m in markers where m.t >= from && m.t <= to {
            let at = ISO8601DateFormatter().date(from: m.at).map { wall($0, zone: s.timeZone) } ?? m.at
            rows.append(Line(t: m.t, order: -2, text: "[\(clock(m.t))] ▶ marker \(m.n), set at \(at)"))
        }
        let drawn = events.filter { $0["kind"] as? String == "mark" }.compactMap { e -> (t: Int, name: String)? in
            guard let t = e["t"] as? Int, let name = e["name"] as? String else { return nil }
            return (t, name)
        }
        for r in remarks(words, marks: drawn, breaks: markers.map(\.t)) {
            rows.append(Line(t: r.start, order: -1, text: "[\(clock(r.start))–\(clock(r.end))] “\(r.text)”"))
        }
        rows.sort { $0.t != $1.t ? $0.t < $1.t : $0.order < $1.order }
        lines.append(contentsOf: rows.map(\.text))
        lines.append("")
        return lines.joined(separator: "\n")
    }

    /// Session ms as mm:ss.mmm, or h:mm:ss.mmm past the first hour.
    public static func clock(_ ms: Int) -> String {
        let h = ms / 3_600_000, m = (ms % 3_600_000) / 60000, s = (ms % 60000) / 1000, r = ms % 1000
        return h > 0 ? String(format: "%d:%02d:%02d.%03d", h, m, s, r) : String(format: "%02d:%02d.%03d", m, s, r)
    }

    /// A wall time the way a person says it: "Thursday 24 September 2026, 12:31:05 pm".
    static func wall(_ date: Date, zone: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: zone) ?? .current
        f.dateFormat = "EEEE d MMMM yyyy, h:mm:ss a"
        f.amSymbol = "am"
        f.pmSymbol = "pm"
        return f.string(from: date)
    }

    struct Remark { let start: Int; let end: Int; let text: String }

    /// Words into remarks, each mark drawn during a remark set in it at the
    /// word it was drawn before. A pause ends a remark, and so does a marker
    /// (`breaks`): what was said before a marker is what was handed over.
    static func remarks(_ words: [Word], marks: [(t: Int, name: String)] = [], breaks: [Int] = []) -> [Remark] {
        var out: [Remark] = []
        var cur: [String] = []
        var start = 0, end = 0
        var next = 0
        // A mark belongs in the remark being said when it was drawn, or in the
        // moment just after its last word.
        func place(upTo t: Int) {
            while next < marks.count, marks[next].t <= t {
                if !cur.isEmpty, marks[next].t <= end + 400 { cur.append("{\(marks[next].name)}") }
                next += 1
            }
        }
        for w in words {
            place(upTo: w.start)
            // A pause ends a remark, and so does the end of a sentence with a
            // shorter pause after it, or any sentence end once a remark has
            // run long enough that events would otherwise pile up inside it.
            let sentenceEnd = cur.last.map { $0.hasSuffix(".") || $0.hasSuffix("?") || $0.hasSuffix("!") } ?? false
            let marked = breaks.contains { $0 > start && $0 <= w.start }
            if !cur.isEmpty, marked || w.start - end > 700 || (sentenceEnd && (w.start - end > 250 || end - start > 6000)) {
                out.append(Remark(start: start, end: end, text: cur.joined(separator: " ")))
                cur = []
            }
            if cur.isEmpty { start = w.start }
            cur.append(w.text)
            end = max(end, w.end)
        }
        place(upTo: end + 400)
        if !cur.isEmpty { out.append(Remark(start: start, end: end, text: cur.joined(separator: " "))) }
        return out
    }

    private static func q(_ s: Any?) -> String {
        guard let s = s as? String, !s.isEmpty else { return "" }
        return " “" + s.replacingOccurrences(of: "\n", with: " ").prefix(160) + "”"
    }

    private static func element(_ e: Any?) -> String {
        guard let d = e as? [String: Any] else { return "" }
        var s = (d["role"] as? String ?? "").replacingOccurrences(of: "AX", with: "").lowercased()
        if let sub = d["subrole"] as? String { s += "/" + sub.replacingOccurrences(of: "AX", with: "").lowercased() }
        let name = d["title"] as? String ?? d["description"] as? String ?? d["text"] as? String
            ?? d["placeholder"] as? String ?? d["help"] as? String
        s += q(name)
        if let v = d["value"] as? String, v != name { s += " =" + q(v) }
        if let sel = d["selectedText"] as? String { s += " selected" + q(sel) }
        if let u = d["url"] as? String { s += " " + u }
        return s
    }

    static func describe(_ e: [String: Any], shots: [Int: URL] = [:]) -> String? {
        let app = e["app"] as? String ?? ""
        switch e["kind"] as? String ?? "" {
        case "session":
            let sound = (e["sound"] as? String).flatMap(SoundQuality.init(rawValue:)).map { ", sound kept at \($0.summary)" }
            return "session \(e["phase"] ?? "")" + (sound ?? "")
        case "app": return "app → \(app)"
        case "window":
            var s = "window \(app)" + q(e["title"])
            if let d = e["document"] as? String { s += " (\(d))" }
            return s
        case "focus":
            let el = element(e["element"])
            return el.isEmpty ? nil : "focus \(app) " + el
        case "select": return "selected in \(app)" + q(e["text"])
        case "page":
            var s = "page"
            if let u = e["url"] as? String { s += " \(u)" }
            s += q(e["pageTitle"])
            return s
        case "desk":
            var s = app
            if let o = e["open"] as? String { s += " open \(o)" }
            if let p = e["picked"] as? String { s += " · picked \(p)" }
            return s
        case "finder":
            var s = "finder"
            if let f = e["folder"] as? String { s += " in \(f)" }
            if let sel = e["selected"] as? [String] { s += " selected: " + sel.joined(separator: ", ") }
            return s
        case "click":
            let count = e["count"] as? Int ?? 1
            return "click \(e["button"] ?? "")\(count > 1 ? "×\(count)" : "") \(app) " + element(e["element"])
        case "key": return "key \(e["chord"] ?? "") in \(app)"
        case "typed": return "typed \(e["keys"] ?? 0) keys in \(app) into " + element(e["field"])
        case "scroll": return "scroll \(e["dy"] ?? 0) in \(app) over " + element(e["element"])
        case "shot":
            let path = (e["file"] as? Int).flatMap { shots[$0] }?.path ?? "(missing)"
            return "picture \(path) (\(e["why"] ?? ""))"
        case "mark":
            let verb = ["arrow": "pointing at", "pen": "over"][e["tool"] as? String ?? ""] ?? "around"
            let on = element(e["element"])
            var s = "drew \(e["name"] as? String ?? "a mark")" + (on.isEmpty ? "" : " \(verb) \(on)")
            if !app.isEmpty { s += " in \(app)" + q(e["window"]) }
            return s
        case "fade":
            let names = (e["names"] as? [String] ?? []).joined(separator: ", ")
            return "\(names) faded" + (e["why"] as? String == "screen" ? " as the screen under it changed" : "")
        case "clear":
            return "wiped \((e["names"] as? [String] ?? []).joined(separator: ", ")) off the screen"
        case "dictation":
            let from = (e["from"] as? Int).map { " since \(clock($0))" } ?? ""
            return "copied what was said\(from) to the clipboard (\(e["words"] ?? 0) words)"
        default: return nil
        }
    }
}
