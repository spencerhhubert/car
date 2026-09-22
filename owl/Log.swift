import Foundation

// A plain file log at ~/Library/Logs/owl.log. Most of what can go wrong here
// leaves no other trace: a take of silence, a screenshot that never landed, an
// accessibility call that timed out.
enum Log {
    private static let url = FileManager.default
        .urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appending(path: "Logs/owl.log")
    private static let queue = DispatchQueue(label: "owl.log")

    static func line(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        queue.async {
            let text = "\(stamp)  \(message)\n"
            guard let data = text.data(using: .utf8) else { return }
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
