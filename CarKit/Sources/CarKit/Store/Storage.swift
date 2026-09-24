import Foundation

// What car keeps, for Settings: the pictures and the sound in the sessions
// folder on this Mac, the catalog, and the room left on the disk; and, with
// a recordings folder chosen, what is in it and the room left on its drive,
// or that it is not there. It walks the folders rather than trusting the
// catalog's byte counts, so it is what is actually there; that takes a
// moment on a big folder, so it is never asked on the main thread.
public enum Storage {
    public struct Use: Sendable, Equatable {
        public var pictures: Int64 = 0
        public var sound: Int64 = 0
        /// Timelines, locks and anything else in the sessions folder.
        public var other: Int64 = 0
        public var catalog: Int64 = 0
        /// Room left on the disk car keeps its things on.
        public var free: Int64?
        /// The recordings folder, when one is chosen.
        public var recordings: Folder?

        public var total: Int64 { pictures + sound + other + catalog }
    }

    public struct Folder: Sendable, Equatable {
        public var path: String
        /// Nil when it is not there (its drive is not plugged in).
        public var bytes: Int64?
        public var free: Int64?
    }

    public static func use() -> Use {
        var u = Use()
        walk(Config.sessionsDir) { ext, n in
            switch ext {
            case "jpg": u.pictures += n
            case "m4a", "wav": u.sound += n
            default: u.other += n
            }
        }
        for suffix in ["", "-wal", "-shm"] {
            let url = URL(fileURLWithPath: Catalog.file.path + suffix)
            u.catalog += Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
        u.free = free(Config.root)
        if let path = Config.load().recordings {
            let url = URL(fileURLWithPath: path)
            var f = Folder(path: path)
            if FileManager.default.fileExists(atPath: path) {
                var n: Int64 = 0
                walk(url) { _, b in n += b }
                f.bytes = n
                f.free = free(url)
            }
            u.recordings = f
        }
        return u
    }

    private static func walk(_ dir: URL, _ add: (String, Int64) -> Void) {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let walk = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: Array(keys)) else { return }
        for case let url as URL in walk {
            guard let v = try? url.resourceValues(forKeys: keys), v.isRegularFile == true else { continue }
            add(url.pathExtension, Int64(v.totalFileAllocatedSize ?? 0))
        }
    }

    private static func free(_ url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
    }

    /// "1.2 GB", "0 KB"
    public static func bytes(_ n: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false
        return f.string(fromByteCount: n)
    }
}
