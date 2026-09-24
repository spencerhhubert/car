import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

// Watches the screen under the marks and says when what a mark was drawn on
// has changed a lot: another tab, a scroll, a model turned. One small, slow
// ScreenCaptureKit stream per display that has marks: a third of the
// display's size, at most five frames a second, and a frame only when
// something on the display changed. owl's own windows and the pointer are
// left out, so the marks never count. Nothing runs while there are no marks,
// and without Screen Recording nothing runs at all (marks then only fade with
// time).
//
// A mark's region (its bounds with a margin) is read as a grid of brightness
// when it is drawn and again on every frame. What the mark was about is gone
// when the region has moved, on average, by half its own spread: measured
// against the region's own contrast, so a sparse list clearing counts as much
// as a busy toolbar scrolling. Checked against pictures of real pages: a
// 30 pt scroll of a list or a toolbar, a 120 pt scroll of anything, a page
// going blank all count; noise, the pointer and a 6 pt nudge do not.
final class ScreenChange: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private struct Watched {
        let display: CGDirectDisplayID
        /// The region, display space.
        let rect: CGRect
        var reference: [UInt8]?
    }

    private final class Feed {
        let stream: SCStream
        /// The display, display space.
        let frame: CGRect
        var latest: Gray?
        init(stream: SCStream, frame: CGRect) {
            self.stream = stream
            self.frame = frame
        }
    }

    private struct Gray {
        let width: Int
        let height: Int
        let px: [UInt8]
    }

    /// The grid is at most this many cells a side.
    private static let cells = 48
    /// The region has changed when its mean move (brightness, of 255) is at
    /// least this share of its spread at the start…
    private static let relativeMove = 0.5
    /// …and at least this much, whatever the spread: a blank region is not
    /// changed by noise.
    private static let minimumMove = 6.0

    private let queue = DispatchQueue(label: "owl.screen-change", qos: .utility)
    private let onChanged: @MainActor (Int) -> Void
    // Everything below is touched only on `queue`.
    private var watched: [Int: Watched] = [:]
    private var feeds: [CGDirectDisplayID: Feed] = [:]
    private var starting: Set<CGDirectDisplayID> = []

    init(onChanged: @escaping @MainActor (Int) -> Void) {
        self.onChanged = onChanged
    }

    func track(_ m: Mark) {
        guard Screenshot.hasPermission, let display = Space.display(at: m.anchor) else { return }
        let pad = max(24, 0.25 * max(m.bounds.width, m.bounds.height))
        let rect = m.bounds.insetBy(dx: -pad, dy: -pad)
        queue.async {
            var w = Watched(display: display, rect: rect)
            // The screen as it was when the mark was finished, if the feed is
            // already running; otherwise its first frame.
            if let feed = self.feeds[display], let g = feed.latest { w.reference = Self.grid(g, of: feed.frame, rect) }
            self.watched[m.n] = w
            self.feed(display)
        }
    }

    func forget(_ n: Int) {
        queue.async {
            self.watched[n] = nil
            self.stopIdle()
        }
    }

    func forgetAll() {
        queue.async {
            self.watched = [:]
            self.stopIdle()
        }
    }

    // MARK: - the feeds

    private func feed(_ display: CGDirectDisplayID) {
        guard feeds[display] == nil, !starting.contains(display) else { return }
        starting.insert(display)
        let frame = CGDisplayBounds(display)
        Task {
            var started: SCStream?
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let d = content.displays.first(where: { $0.displayID == display }) else { throw Failure("no display") }
                let me = content.applications.filter { $0.processID == getpid() }
                let cfg = SCStreamConfiguration()
                cfg.width = max(64, Int(frame.width / 3))
                cfg.height = max(40, Int(frame.height / 3))
                cfg.minimumFrameInterval = CMTime(value: 1, timescale: 5)
                cfg.pixelFormat = kCVPixelFormatType_32BGRA
                cfg.showsCursor = false
                cfg.queueDepth = 3
                let stream = SCStream(filter: SCContentFilter(display: d, excludingApplications: me, exceptingWindows: []),
                                      configuration: cfg, delegate: self)
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
                try await stream.startCapture()
                started = stream
            } catch {
                Log.line("screen-change feed for display \(display) did not start: \(error.localizedDescription)")
            }
            queue.async {
                self.starting.remove(display)
                guard let stream = started else { return }
                self.feeds[display] = Feed(stream: stream, frame: frame)
                self.stopIdle()
            }
        }
    }

    /// A feed with no marks on its display stops.
    private func stopIdle() {
        let needed = Set(watched.values.map(\.display))
        for (display, feed) in feeds where !needed.contains(display) {
            feeds[display] = nil
            feed.stream.stopCapture { _ in }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async {
            if let display = self.feeds.first(where: { $0.value.stream === stream })?.key { self.feeds[display] = nil }
            Log.line("screen-change feed stopped: \(error.localizedDescription)")
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, Self.complete(sample), let pixels = sample.imageBuffer,
              let (display, feed) = feeds.first(where: { $0.value.stream === stream }),
              let g = Self.gray(pixels) else { return }
        feed.latest = g
        for (n, w) in watched where w.display == display {
            let now = Self.grid(g, of: feed.frame, w.rect)
            guard let reference = w.reference else {
                watched[n]?.reference = now
                continue
            }
            if Self.changed(reference, now) {
                watched[n] = nil
                let tell = onChanged
                DispatchQueue.main.async { MainActor.assumeIsolated { tell(n) } }
            }
        }
        stopIdle()
    }

    // MARK: - reading a frame

    private static func complete(_ sample: CMSampleBuffer) -> Bool {
        guard let infos = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let raw = infos.first?[.status] as? Int else { return false }
        return SCFrameStatus(rawValue: raw) == .complete
    }

    private static func gray(_ buffer: CVPixelBuffer) -> Gray? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let (w, h, row) = (CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer),
                           CVPixelBufferGetBytesPerRow(buffer))
        var px = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            let line = base + y * row
            for x in 0..<w {
                let p = line + x * 4
                px[y * w + x] = UInt8((29 * Int(p[0]) + 150 * Int(p[1]) + 77 * Int(p[2])) >> 8)
            }
        }
        return Gray(width: w, height: h, px: px)
    }

    /// The mean brightness of each cell of `rect` (display space) in a frame
    /// of the display at `frame`.
    private static func grid(_ g: Gray, of frame: CGRect, _ rect: CGRect) -> [UInt8] {
        let sx = CGFloat(g.width) / frame.width, sy = CGFloat(g.height) / frame.height
        let x0 = max(0, min(g.width - 1, Int((rect.minX - frame.minX) * sx)))
        let y0 = max(0, min(g.height - 1, Int((rect.minY - frame.minY) * sy)))
        let x1 = max(x0 + 1, min(g.width, Int((rect.maxX - frame.minX) * sx)))
        let y1 = max(y0 + 1, min(g.height, Int((rect.maxY - frame.minY) * sy)))
        let cols = min(cells, x1 - x0), rows = min(cells, y1 - y0)
        var out = [UInt8](repeating: 0, count: cols * rows)
        for r in 0..<rows {
            let ya = y0 + (y1 - y0) * r / rows, yb = y0 + (y1 - y0) * (r + 1) / rows
            for c in 0..<cols {
                let xa = x0 + (x1 - x0) * c / cols, xb = x0 + (x1 - x0) * (c + 1) / cols
                var sum = 0
                for y in ya..<yb { for x in xa..<xb { sum += Int(g.px[y * g.width + x]) } }
                out[r * cols + c] = UInt8(sum / max(1, (yb - ya) * (xb - xa)))
            }
        }
        return out
    }

    static func changed(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count, !a.isEmpty else { return false }
        let n = Double(a.count)
        let moved = zip(a, b).reduce(0.0) { $0 + Double(abs(Int($1.0) - Int($1.1))) } / n
        let mean = a.reduce(0.0) { $0 + Double($1) } / n
        let spread = a.reduce(0.0) { $0 + abs(Double($1) - mean) } / n
        return moved >= minimumMove && moved >= relativeMove * spread
    }
}
