import AppKit
import CoreGraphics
import ScreenCaptureKit

// Pictures of the focused window, taken when something changed: a new window
// in front, a click. Stored as JPEG at most ~2 MP, and only when the picture
// differs from the last one (a 64-bit difference hash).
final class Screenshot {
    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }
    static func requestPermission() { CGRequestScreenCaptureAccess() }

    private var lastHash: UInt64 = 0
    private var lastAt: TimeInterval = 0
    /// Minimum seconds between two stored pictures.
    var minGap: TimeInterval = 0.7
    private var content: SCShareableContent?
    private var contentAt: TimeInterval = 0

    /// Take one of the front window of `pid`, or the display under the mouse
    /// when no window can be found. Returns the file name written, or nil when
    /// nothing changed enough to keep.
    func take(pid: pid_t, to dir: URL, name: String, force: Bool = false) async -> String? {
        guard Self.hasPermission else { return nil }
        let now = ProcessInfo.processInfo.systemUptime
        if !force, now - lastAt < minGap { return nil }
        guard let content = await shareable() else { return nil }
        let filter: SCContentFilter
        let size: CGSize
        if let win = content.windows.first(where: {
            $0.owningApplication?.processID == pid && $0.isOnScreen && $0.windowLayer == 0
                && $0.frame.width > 50 && $0.frame.height > 50
        }) {
            filter = SCContentFilter(desktopIndependentWindow: win)
            size = win.frame.size
        } else {
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
            let id = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            guard let display = content.displays.first(where: { $0.displayID == id }) ?? content.displays.first
            else { return nil }
            filter = SCContentFilter(display: display, excludingWindows: [])
            size = CGSize(width: display.width, height: display.height)
        }
        let cfg = SCStreamConfiguration()
        let scale = min(1.0, (2_000_000 / (size.width * size.height)).squareRoot())
        let px = (NSScreen.main?.backingScaleFactor ?? 2)
        cfg.width = Int(size.width * px * scale)
        cfg.height = Int(size.height * px * scale)
        cfg.showsCursor = true
        cfg.captureResolution = .best
        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
        } catch {
            Log.line("screenshot failed: \(error.localizedDescription)")
            self.content = nil
            return nil
        }
        let hash = Self.dHash(image)
        if !force, Self.hamming(hash, lastHash) < 6 { return nil }
        lastHash = hash
        lastAt = now
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.72]) else { return nil }
        let file = "\(name).jpg"
        do {
            try data.write(to: dir.appending(path: file))
        } catch {
            Log.line("screenshot write failed: \(error.localizedDescription)")
            return nil
        }
        return file
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

    // 9x8 greyscale, each bit is whether a pixel is brighter than its right
    // neighbour. Unchanged screens read 0-2 bits apart, a new page 20+.
    static func dHash(_ image: CGImage) -> UInt64 {
        let w = 9, h = 8
        var px = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return 0 }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
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
