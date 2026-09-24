import Foundation

// The lines car puts on the clipboard for pasting into an agent. Never the
// words: a line that names what to read, for an agent that knows car (its
// skill, `skill/SKILL.md`), which reads the session itself and so gets all of
// it: what was said, what was on the screen while it was said, what was
// drawn, the pictures.
//
// A marker is the usual one: set in the middle of a long session, it hands
// over what was said up to it, and `car marker` waits for those words to be
// transcribed. The session line is for handing over a whole session.
// The development copy writes car-dev, so the agent reads the right catalog.
public enum Pointer {
    /// "car marker 3 set at 12:31:05 pm in session 20260924-122534"
    public static func marker(_ n: Int, at date: Date, in id: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "h:mm:ss a"
        f.amSymbol = "am"
        f.pmSymbol = "pm"
        return "\(Config.name) marker \(n) set at \(f.string(from: date)) in session \(id)"
    }

    /// "new car session 20260924-122534"
    public static func session(_ id: String) -> String { "new \(Config.name) session \(id)" }
}
