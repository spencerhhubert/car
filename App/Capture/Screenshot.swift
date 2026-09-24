import CoreGraphics
import Foundation
import ImageIO
import CarKit
@preconcurrency import ScreenCaptureKit
import UniformTypeIdentifiers

// Pictures of the screen, taken when something changed: a new window in front,
// a click, a scroll, a drawing. Two kinds: the focused window of an app, which
// is what most moments are about, and a whole display, for a drawing, which is
// often about more than one window. car's overlays (the pill, the drawing
// layer) are never in a picture, though its own window is, like any app's;
// the marks on the screen are drawn into every picture they fall on, with
// their numbers, by car itself, so a picture says which mark is which.
//
// JPEG, at most ~1.5 MP, and only when it differs from the last picture (a
// difference hash) unless the moment is worth one regardless. An actor:
// pictures are asked for from several tasks at once and share that state.
actor Screenshot {
    enum Target: Sendable {
        /// The focused window of an app; `frame` (display space) picks it out
        /// when the app has several.
        case window(pid: pid_t, frame: CGRect?)
        case display(CGDirectDisplayID)
    }

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }
    static func requestPermission() { CGRequestScreenCaptureAccess() }

    /// Minimum seconds between two pictures that were not forced.
    private let minGap: TimeInterval = 0.7
    private let maxPixels: CGFloat = 1_500_000
    private var lastHash: UInt64 = 0
    private var lastAt: TimeInterval = 0
    private var content: SCShareableContent?
    private var contentAt: TimeInterval = 0

    /// Take one and write it to `dir/name.jpg`. Returns the file name, or nil
    /// when nothing changed enough to keep (or it could not be taken).
    func take(_ target: Target, marks: [Mark], into dir: URL, name: String, force: Bool) async -> String? {
        guard Self.hasPermission else { return nil }
        let now = ProcessInfo.processInfo.systemUptime
        if !force {
            if now - lastAt < minGap { return nil }
            lastAt = now
        }
        guard let content = await shareable(), let (filter, rect) = Self.filter(for: target, in: content) else {
            return nil
        }
        let native = CGFloat(filter.pointPixelScale)
        let scale = native * min(1, (maxPixels / (rect.width * rect.height * native * native)).squareRoot())
        let cfg = SCStreamConfiguration()
        cfg.width = max(1, Int(rect.width * scale))
        cfg.height = max(1, Int(rect.height * scale))
        cfg.showsCursor = true
        cfg.captureResolution = .best
        // The window itself: a JPEG has no transparency, and its shadow
        // would come out as a white margin around it.
        cfg.ignoreShadowsSingleWindow = true
        let raw: CGImage
        do {
            raw = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
        } catch {
            Log.line("screenshot failed: \(error.localizedDescription)")
            self.content = nil
            return nil
        }
        let image = Self.draw(marks, onto: raw, showing: rect) ?? raw
        let hash = Self.dHash(image)
        if !force, Self.hamming(hash, lastHash) < 6 { return nil }
        lastHash = hash
        lastAt = now
        let file = "\(name).jpg"
        return Self.writeJPEG(image, to: dir.appending(path: file)) ? file : nil
    }

    private func shareable() async -> SCShareableContent? {
        let now = ProcessInfo.processInfo.systemUptime
        if let content, now - contentAt < 2 { return content }
        do {
            let c = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            content = c
            contentAt = now
            return c
        } catch {
            Log.line("shareable content failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// What to capture, and the rectangle of the display space it shows.
    private static func filter(for target: Target, in content: SCShareableContent) -> (SCContentFilter, CGRect)? {
        let display: CGDirectDisplayID
        switch target {
        case .window(let pid, let frame):
            let windows = content.windows.filter {
                $0.owningApplication?.processID == pid && $0.isOnScreen && $0.windowLayer == 0
                    && $0.frame.width > 50 && $0.frame.height > 50
            }
            let chosen = frame.flatMap { f in windows.min { distance($0.frame, f) < distance($1.frame, f) } }
            if let win = chosen ?? windows.first {
                return (SCContentFilter(desktopIndependentWindow: win), win.frame)
            }
            // No window to speak of (the desktop, a menu): the display the
            // pointer is on.
            guard let at = CGEvent(source: nil)?.location, let d = Space.display(at: at) else { return nil }
            display = d
        case .display(let d):
            display = d
        }
        guard let d = content.displays.first(where: { $0.displayID == display }) ?? content.displays.first
        else { return nil }
        return (SCContentFilter(display: d, excludingWindows: overlays(in: content)), d.frame)
    }

    /// car's own windows that float over everything (the pill, the drawing
    /// layer): never in a picture. car's own window is, like any app's.
    static func overlays(in content: SCShareableContent) -> [SCWindow] {
        content.windows.filter { $0.owningApplication?.processID == getpid() && $0.windowLayer > 0 }
    }

    private static func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        abs(a.minX - b.minX) + abs(a.minY - b.minY) + abs(a.width - b.width) + abs(a.height - b.height)
    }

    /// The marks that fall in `rect` (display space) drawn onto its picture,
    /// or nil when none do.
    static func draw(_ marks: [Mark], onto image: CGImage, showing rect: CGRect) -> CGImage? {
        let on = marks.filter { $0.bounds.insetBy(dx: -16, dy: -16).intersects(rect) }
        guard !on.isEmpty, rect.width > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        let (w, h) = (CGFloat(image.width), CGFloat(image.height))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let scale = w / rect.width
        for m in on {
            m.draw(in: ctx, scale: scale) { p in
                CGPoint(x: (p.x - rect.minX) * scale, y: h - (p.y - rect.minY) * scale)
            }
        }
        return ctx.makeImage()
    }

    static func writeJPEG(_ image: CGImage, to url: URL) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.65] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            Log.line("picture write failed: \(url.lastPathComponent)")
            return false
        }
        return true
    }

    // 9x8 greyscale, each bit is whether a pixel is brighter than its right
    // neighbour. Unchanged screens read 0-2 bits apart, a new page 20+.
    static func dHash(_ image: CGImage) -> UInt64 {
        let w = 9, h = 8
        var px = [UInt8](repeating: 0, count: w * h)
        let drawn: Bool = px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return 0 }
        var hash: UInt64 = 0
        for y in 0..<h {
            for x in 0..<(w - 1) {
                hash <<= 1
                if px[y * w + x] > px[y * w + x + 1] { hash |= 1 }
            }
        }
        return hash
    }

    static func hamming(_ a: UInt64, _ b: UInt64) -> Int { (a ^ b).nonzeroBitCount }
}
