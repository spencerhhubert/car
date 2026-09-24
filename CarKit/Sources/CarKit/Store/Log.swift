import Foundation

// A plain file log at ~/Library/Logs/car.log (car-dev.log for the development
// copy, log.txt in CAR_ROOT when that is set). Most of what can go wrong here
// leaves no other trace: a chunk of silence, a picture that never landed, an
// accessibility call that timed out.
public enum Log {
    private static let url = ProcessInfo.processInfo.environment["CAR_ROOT"] != nil
        ? Config.root.appending(path: "log.txt")
        : FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appending(path: "Logs/\(Config.name).log")
    private static let queue = DispatchQueue(label: "car.log")
    /// Used only on `queue`.
    private static let stamp = ISO8601DateFormatter()

    public static func line(_ message: String) {
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

/// The one error car throws: a sentence a person can act on.
public struct Failure: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
