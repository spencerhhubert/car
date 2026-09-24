import Foundation

// What car keeps on this Mac's disk, for Settings: the pictures and the sound
// in the sessions folder, the catalog, and the room left on the disk. It
// walks the folder rather than trusting the catalog's byte counts, so it is
// what is actually there; that takes a moment on a big folder, so it is never
// asked on the main thread.
public enum Storage {
    public struct Use: Sendable, Equatable {
        public var pictures: Int64 = 0
        public var sound: Int64 = 0
        /// Timelines, locks and anything else in the sessions folder.
        public var other: Int64 = 0
        public var catalog: Int64 = 0
        /// Room left on the disk car keeps its things on.
        public var free: Int64?

        public var total: Int64 { pictures + sound + other + catalog }
    }

    public static func use() -> Use {
        var u = Use()
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        if let walk = FileManager.default.enumerator(at: Config.sessionsDir, includingPropertiesForKeys: Array(keys)) {
            for case let url as URL in walk {
                guard let v = try? url.resourceValues(forKeys: keys), v.isRegularFile == true else { continue }
                let n = Int64(v.totalFileAllocatedSize ?? 0)
                switch url.pathExtension {
                case "jpg": u.pictures += n
                case "m4a", "wav": u.sound += n
                default: u.other += n
                }
            }
        }
        for suffix in ["", "-wal", "-shm"] {
            let url = URL(fileURLWithPath: Catalog.file.path + suffix)
            u.catalog += Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
        u.free = (try? Config.root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
        return u
    }

    /// "1.2 GB", "0 KB"
    public static func bytes(_ n: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false
        return f.string(fromByteCount: n)
    }
}
