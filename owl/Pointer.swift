import AppKit

// What the clipboard gets when a session stops: not its words, but a note for
// an agent saying there is a session, what owl is, and how to read it. The
// session is the message: the words, what was on the screen while they were
// said, what was drawn, the pictures. Pasted into any agent, the note sends it
// to all of that rather than to a transcript cut loose from it. The note is
// ready the moment the session stops, before the words are; `owl session`
// waits for them.
enum Pointer {
    static func text(id: String, started: Date, seconds: Double) -> String {
        let owl = Config.name
        return """
        I just recorded an owl session: my voice and everything I did on my Mac while I talked, on one clock, with \
        pictures of the screen. owl is the app that records them; `\(owl) guide` explains how it works.

        Session \(id), \(when(started)), \(length(seconds)) long.

        Read it with `\(owl) session \(id)`. That prints the timeline: what I said, and every app, window, page, \
        click and drawing at the moment it happened; if the session is still being transcribed, it waits. The rest \
        is in `\(Session.dir(id).path)/`. Open the pictures in `shots/` that the timeline points to: they show what \
        I was looking at, and anything I drew is in them with its number. What I said in the session is my \
        message to you.
        """
    }

    /// The note for a session on disk.
    static func text(id: String) -> String {
        let meta = Session.meta(id)
        let started = meta?.started ?? Date()
        return text(id: id, started: started, seconds: meta?.seconds ?? Date().timeIntervalSince(started))
    }

    static func copy(_ text: String) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
    }

    private static func when(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEEE d MMMM yyyy 'at' h:mm a"
        f.amSymbol = "am"
        f.pmSymbol = "pm"
        return f.string(from: date)
    }

    private static func length(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s) s" }
        if s < 3600 { return "\(s / 60) min \(s % 60) s" }
        return "\(s / 3600) h \(s % 3600 / 60) min"
    }
}
