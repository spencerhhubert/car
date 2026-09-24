import Foundation

// A plain file log at ~/Library/Logs/owl.log (owl-dev.log for the development
// copy). Most of what can go wrong here leaves no other trace: a take of
// silence, a screenshot that never landed, an accessibility call that timed
// out.
enum Log {
    private static let url = FileManager.default
        .urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appending(path: "Logs/\(Config.name).log")
    private static let queue = DispatchQueue(label: "owl.log")
    /// Used only on `queue`.
    private static let stamp = ISO8601DateFormatter()

    static func line(_ message: String) {
        let now = Date()
        queue.async {
            guard let data = "\(stamp.string(from: now))  \(message)\n".data(using: .utf8) else { return }
            if let h = try? FileHandle(forWritingTo: url) {
                defer { try? h.close() }
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: data)
            } else {
                try? FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: url)
            }
        }
    }
}

/// The one error owl throws: a sentence a person can act on.
struct Failure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
