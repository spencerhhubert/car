import CoreMedia
import CoreVideo
import Foundation
@preconcurrency import ScreenCaptureKit
import OwlKit

// Watches the screen under the marks and says when what a mark was drawn on
// has changed a lot: another tab, a scroll, a model turned. One small, slow
// ScreenCaptureKit stream per display that has marks: a third of the
// display's size, at most five frames a second, and a frame only when
// something on it changed. owl's own windows and the pointer are left out,
// so the marks never count. Nothing runs while there are no marks, and
// without Screen Recording nothing runs at all (marks then only fade with
// time). What counts as a change is OwlKit's Fading.swift.
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
        var latest: Fading.Gray?
        init(stream: SCStream, frame: CGRect) {
            self.stream = stream
            self.frame = frame
        }
    }

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
        let rect = Fading.region(of: m)
        queue.async {
            var w = Watched(display: display, rect: rect)
            // The screen as it was when the mark was finished, if the feed is
            // already running; otherwise its first frame.
            if let feed = self.feeds[display], let g = feed.latest { w.reference = Fading.grid(g, of: feed.frame, rect) }
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
            let now = Fading.grid(g, of: feed.frame, w.rect)
            guard let reference = w.reference else {
                watched[n]?.reference = now
                continue
            }
            if Fading.changed(reference, now) {
                watched[n] = nil
                let tell = onChanged
                DispatchQueue.main.async { MainActor.assumeIsolated { tell(n) } }
            }
        }
        stopIdle()
    }

    private static func complete(_ sample: CMSampleBuffer) -> Bool {
        guard let infos = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let raw = infos.first?[.status] as? Int else { return false }
        return SCFrameStatus(rawValue: raw) == .complete
    }

    private static func gray(_ buffer: CVPixelBuffer) -> Fading.Gray? {
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
        return Fading.Gray(width: w, height: h, px: px)
    }
}
