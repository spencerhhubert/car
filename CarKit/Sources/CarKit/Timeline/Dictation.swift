import Foundation

// Quick dictation (⇧ ⌥ ⌥): the last thing said, as text, for answering a
// message out loud in the middle of a session. The app cuts the sound there
// so its words come at once, waits for them, and copies this.
public enum Dictation {
    /// The last stretch of talk in `words`: from the first word after the
    /// last pause of at least `pause` ms to the end. The text, and when it
    /// started and ended on the session clock.
    public static func last(_ words: [Word], pause: Int) -> (text: String, from: Int, to: Int)? {
        guard var i = words.indices.last else { return nil }
        let to = words[i].end
        while i > 0, words[i].start - words[i - 1].end < pause { i -= 1 }
        return (words[i...].map(\.text).joined(separator: " "), words[i].start, to)
    }
}
