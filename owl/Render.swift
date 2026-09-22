import Foundation

// session.md: what he said and did, in order, one line per thing.
//
// Words come grouped into remarks (a pause over 0.7 s ends one); everything
// else is an event from events.jsonl. Times are [mm:ss.mmm] on the session
// clock. Pictures are named by path so a reader can open the one it needs
// rather than every one.
enum Render {
    static func write(id: String) throws {
        try text(id: id).write(to: Session.dir(id).appending(path: "session.md"),
                               atomically: true, encoding: .utf8)
    }

    static func text(id: String) -> String {
        let meta = Session.meta(id)
        let events = Session.events(id)
        let words = loadWords(id)
        var lines: [String] = []
        let secs = (meta["seconds"] as? Double) ?? 0
        lines.append("# owl session \(id)")
        lines.append("")
        var head: [String] = []
        if let s = meta["startedAt"] as? String { head.append("started \(s)") }
        head.append(clock(Int(secs * 1000)) + " long")
        head.append("\(events.count) events")
        let shots = events.filter { $0["kind"] as? String == "shot" }.count
        let screenOff = events.first { $0["kind"] as? String == "session" && $0["phase"] as? String == "start" }
            .map { ($0["screen"] as? Bool) == false } ?? false
        head.append("\(shots) pictures" + (screenOff ? " (Screen Recording was not granted)" : ""))
        if let tm = meta["textModel"] as? String { head.append("words by \(tm)") }
        if let ts = meta["timeSource"] as? String { head.append("times by \(ts)") }
        lines.append(head.joined(separator: " · "))
        if let note = meta["note"] as? String { lines.append(""); lines.append("Note: \(note)") }
        lines.append("")
        lines.append("Every word with its time is in `words.json`; the raw events are `events.jsonl`; pictures are in `shots/`.")
        lines.append("")
        lines.append("## timeline")
        lines.append("")

        struct Row { let t: Int; let order: Int; let text: String }
        var rows: [Row] = []
        for (i, e) in events.enumerated() {
            guard let t = e["t"] as? Int, let s = describe(e) else { continue }
            rows.append(Row(t: t, order: i, text: "[\(clock(t))] \(s)"))
        }
        for r in remarks(words) {
            rows.append(Row(t: r.start, order: -1, text: "[\(clock(r.start))–\(clock(r.end))] “\(r.text)”"))
        }
        rows.sort { $0.t != $1.t ? $0.t < $1.t : $0.order < $1.order }
        lines.append(contentsOf: rows.map(\.text))
        lines.append("")
        return lines.joined(separator: "\n")
    }

    static func clock(_ ms: Int) -> String {
        let m = ms / 60000, s = (ms % 60000) / 1000, r = ms % 1000
        return String(format: "%02d:%02d.%03d", m, s, r)
    }

    struct Remark { let start: Int; let end: Int; let text: String }

    static func remarks(_ words: [[String: Any]]) -> [Remark] {
        var out: [Remark] = []
        var cur: [String] = []
        var start = 0, end = 0
        for w in words {
            guard let t = w["text"] as? String, let s = w["start"] as? Int, let e = w["end"] as? Int else { continue }
            // A pause ends a remark, and so does the end of a sentence with a
            // shorter pause after it, or any sentence end once a remark has
            // run long enough that events would otherwise pile up inside it.
            let sentenceEnd = cur.last.map { $0.hasSuffix(".") || $0.hasSuffix("?") || $0.hasSuffix("!") } ?? false
            if !cur.isEmpty, s - end > 700 || (sentenceEnd && (s - end > 250 || end - start > 6000)) {
                out.append(Remark(start: start, end: end, text: cur.joined(separator: " ")))
                cur = []
            }
            if cur.isEmpty { start = s }
            cur.append(t)
            end = max(end, e)
        }
        if !cur.isEmpty { out.append(Remark(start: start, end: end, text: cur.joined(separator: " "))) }
        return out
    }

    static func loadWords(_ id: String) -> [[String: Any]] {
        guard let data = try? Data(contentsOf: Session.dir(id).appending(path: "words.json")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let words = obj["words"] as? [[String: Any]] else { return [] }
        return words
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

    static func describe(_ e: [String: Any]) -> String? {
        let app = e["app"] as? String ?? ""
        switch e["kind"] as? String ?? "" {
        case "session": return "session \(e["phase"] ?? "")"
        case "app": return "app → \(app)"
        case "window":
            var s = "window \(app)" + q(e["title"])
            if let d = e["document"] as? String { s += " (\(d))" }
            return s
        case "focus": return "focus \(app) " + element(e["element"])
        case "select": return "selected in \(app)" + q(e["text"])
        case "page":
            var s = "page"
            if let u = e["url"] as? String { s += " \(u)" }
            s += q(e["pageTitle"])
            return s
        case "finder":
            var s = "finder"
            if let f = e["folder"] as? String { s += " in \(f)" }
            if let sel = e["selected"] as? [String] { s += " selected: " + sel.joined(separator: ", ") }
            return s
        case "click":
            return "click \(e["button"] ?? "")\((e["count"] as? Int ?? 1) > 1 ? "×\(e["count"]!)" : "") \(app) " + element(e["element"])
        case "key": return "key \(e["chord"] ?? "") in \(app)"
        case "typed": return "typed \(e["keys"] ?? 0) keys in \(app) into " + element(e["field"])
        case "scroll": return "scroll \(e["dy"] ?? 0) in \(app) over " + element(e["element"])
        case "shot": return "picture \(e["file"] ?? "") (\(e["why"] ?? ""))"
        default: return nil
        }
    }
}
