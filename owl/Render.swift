import Foundation

// session.md: what was said and done, in order, one line per thing.
//
// Words come grouped into remarks (a pause ends one); everything else is an
// event from events.jsonl. A mark drawn while a remark was being said also
// appears inside it, in braces, at the word it was drawn at: "this part here
// {red circle 1} is wrong". Times are [mm:ss.mmm] on the session clock.
// Pictures are named by path so a reader opens the one it needs rather than
// every one.
enum Render {
    static func write(id: String) throws {
        try text(id: id).write(to: Session.dir(id).appending(path: "session.md"), atomically: true, encoding: .utf8)
    }

    static func text(id: String) -> String {
        let meta = Session.meta(id) ?? Meta(id: id)
        let events = Session.events(id)
        let words = loadWords(id)
        var lines = ["# owl session \(id)", ""]

        let seconds = meta.seconds ?? Double(events.last?["t"] as? Int ?? 0) / 1000
        let shots = events.filter { $0["kind"] as? String == "shot" }.count
        let screenOff = events.first { $0["kind"] as? String == "session" && $0["phase"] as? String == "start" }
            .map { ($0["screen"] as? Bool) == false } ?? false
        let marks = events.filter { $0["kind"] as? String == "mark" }
        var head: [String] = []
        if let s = meta.startedAt { head.append("started \(s)") }
        head.append(clock(Int(seconds * 1000)) + " long")
        head.append("\(events.count) events")
        head.append("\(shots) pictures" + (screenOff ? " (Screen Recording was not granted)" : ""))
        if !marks.isEmpty { head.append("\(marks.count) drawn") }
        if let tm = meta.textModel { head.append("words by \(tm)") }
        if let ts = meta.timeSource { head.append("times by \(ts)") }
        lines.append(head.joined(separator: " · "))
        switch meta.status {
        case .recording: lines += ["", "Still being recorded: this is what it holds so far, without the words."]
        case .transcribing: lines += ["", "Still being transcribed: the words are not in yet."]
        case .failed:
            lines += ["", "The transcription failed: \(meta.error ?? "no reason recorded"). " +
                      "`\(Config.name) transcribe \(id)` tries again."]
        case .done: break
        }
        if let note = meta.note { lines += ["", "Note: \(note)"] }
        lines += ["", """
            How to read it: each line is a moment, [minutes:seconds.ms] from the start, on one clock for words and \
            events alike. Quoted lines are what was said; the rest is what happened on the screen. A drawing's name \
            in braces inside a quote, like {red circle 1}, is where in the sentence it was drawn; its own line says \
            what it was drawn on, and it is on the screen, and in the pictures with its number, until the line that \
            says it faded. Pictures are in `shots/`: open the ones the timeline names. Every word's time is in `words.json`, every event's full detail in `events.jsonl`.
            """, "", "## timeline", ""]

        struct Row { let t: Int; let order: Int; let text: String }
        var rows: [Row] = []
        for (i, e) in events.enumerated() {
            guard let t = e["t"] as? Int, let s = describe(e) else { continue }
            rows.append(Row(t: t, order: i, text: "[\(clock(t))] \(s)"))
        }
        let drawn = marks.compactMap { m -> (t: Int, name: String)? in
            guard let t = m["t"] as? Int, let name = m["name"] as? String else { return nil }
            return (t, name)
        }
        for r in remarks(words, marks: drawn) {
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

    /// Words into remarks, with each mark drawn during a remark set in it at
    /// the word it was drawn before. `marks` are (time, name), in time order.
    static func remarks(_ words: [[String: Any]], marks: [(t: Int, name: String)] = []) -> [Remark] {
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
            guard let text = w["text"] as? String, let s = w["start"] as? Int, let e = w["end"] as? Int else { continue }
            place(upTo: s)
            // A pause ends a remark, and so does the end of a sentence with a
            // shorter pause after it, or any sentence end once a remark has
            // run long enough that events would otherwise pile up inside it.
            let sentenceEnd = cur.last.map { $0.hasSuffix(".") || $0.hasSuffix("?") || $0.hasSuffix("!") } ?? false
            if !cur.isEmpty, s - end > 700 || (sentenceEnd && (s - end > 250 || end - start > 6000)) {
                out.append(Remark(start: start, end: end, text: cur.joined(separator: " ")))
                cur = []
            }
            if cur.isEmpty { start = s }
            cur.append(text)
            end = max(end, e)
        }
        place(upTo: end + 400)
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
        case "shot": return "picture \(e["file"] ?? "") (\(e["why"] ?? ""))"
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
            let names = e["names"] as? [String] ?? (e["marks"] as? [Int] ?? []).map { "drawing \($0)" }
            return "wiped \(names.joined(separator: ", ")) off the screen"
        default: return nil
        }
    }
}
