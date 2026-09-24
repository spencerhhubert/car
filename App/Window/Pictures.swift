import AppKit

/// Pictures from disk, off the main thread: small ones for lists, kept in a
/// cache that lets go of the oldest past its limit, and whole ones for the
/// picture viewer.
enum Pictures {
    private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.totalCostLimit = 96 << 20
        return c
    }()

    static func thumbnail(_ url: URL, pixels: Int) async -> NSImage? {
        let key = "\(url.path)#\(pixels)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let made = await Task.detached(priority: .utility) { () -> (NSImage, Int)? in
            let opts = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: pixels,
                        kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts) else { return nil }
            return (NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)), cg.bytesPerRow * cg.height)
        }.value
        guard let (image, cost) = made else { return nil }
        cache.setObject(image, forKey: key, cost: cost)
        return image
    }

    static func full(_ url: URL) async -> NSImage? {
        await Task.detached(priority: .userInitiated) { () -> NSImage? in
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cg = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
            else { return nil }
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }.value
    }
}
