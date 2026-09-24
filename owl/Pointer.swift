import AppKit

// What the clipboard gets when a session stops: not its words, one line that
// names it ("new owl session 20260924-111424"; owl-dev for the development
// copy). The agent it is pasted into knows owl, reads the session itself with
// `owl session <id>`, which waits for the words, and so gets all of it: what
// was said, what was on the screen while it was said, what was drawn, the
// pictures.
enum Pointer {
    static func text(id: String) -> String { "new \(Config.name) session \(id)" }

    static func copy(_ text: String) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
    }
}
