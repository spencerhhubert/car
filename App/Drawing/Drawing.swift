import AppKit
import OwlKit

// The drawing layer: the tool in hand, the ink, the marks of the session being
// recorded, and the transparent windows they are drawn on. The pill
// (Pill.swift) is where a tool and an ink are picked; what a mark is, and
// when one fades, are OwlKit's Marks.swift and Fading.swift.
//
// With no tool in hand the layer lets every click through to the apps and only
// shows the marks. With one, it takes the mouse on every screen: a drag draws,
// and a click without a drag puts the tool down, as does Escape, which an
// event tap swallows (and nothing else) for as long as a tool is in hand.
//
// A mark is a gesture made while talking, not a note left on the screen: it
// holds for a few seconds and fades. When what it was drawn on changes a lot
// (another tab, a scroll, a model turned; ScreenChange.swift watches), it
// fades at once. A mark leaves the session's record the moment it starts to
// fade, so no picture shows it over something it was not about. The windows
// exist only while there is something to show, and go when the session does.
@MainActor
final class Drawing: ObservableObject {
    /// The tool in hand, or nil when the pointer belongs to the apps.
    @Published private(set) var tool: Tool?
    /// One ink for every tool, kept from one session to the next.
    @Published var ink: Ink = .red
    /// The marks on the screen and on the record: drawn, not yet fading.
    @Published private(set) var marks: [Mark] = []

    private var session: Session?
    private var next = 1
    private var live: Mark?
    /// Marks fading out: still drawn, no longer on the record, gone at `until`.
    private var leaving: [Int: (mark: Mark, until: Date)] = [:]
    /// Each mark's hold, then its fade.
    private var timers: [Int: Task<Void, Never>] = [:]
    private var onMark: (Mark) -> Void = { _ in }
    private var onFade: (Mark, Fade) -> Void = { _, _ in }
    private var onClear: ([Mark]) -> Void = { _ in }
    private lazy var change = ScreenChange { [weak self] n in self?.fade(n, over: Fading.quickly, because: .screen) }
    private var windows: [CanvasWindow] = []
    private var escape: EscapeTap?
    private var screens: NSObjectProtocol?

    /// How many marks this session has made.
    var drawn: Int { next - 1 }

    /// A session started: marks can be drawn. Each finished one is handed to
    /// `onMark`, each one that starts to fade to `onFade`, and a wipe's to
    /// `onClear`.
    func begin(_ session: Session, onMark: @escaping (Mark) -> Void, onFade: @escaping (Mark, Fade) -> Void,
               onClear: @escaping ([Mark]) -> Void) {
        self.session = session
        self.onMark = onMark
        self.onFade = onFade
        self.onClear = onClear
        next = 1
    }

    /// The session is over: what was drawn goes, and the tool is put down.
    func end() {
        session = nil
        tool = nil
        live = nil
        drop()
        onMark = { _ in }
        onFade = { _, _ in }
        onClear = { _ in }
        sync()
    }

    /// Take a tool, or put it down if it is the one in hand.
    func pick(_ t: Tool) {
        guard session != nil else { return }
        tool = tool == t ? nil : t
        live = nil
        sync()
    }

    func putDown() {
        guard tool != nil || live != nil else { return }
        tool = nil
        live = nil
        sync()
    }

    /// Wipe the screen now. The marks stay in the session's record.
    func clear() {
        guard !marks.isEmpty || !leaving.isEmpty else { return }
        let gone = marks
        drop()
        sync()
        if !gone.isEmpty { onClear(gone) }
    }

    private func drop() {
        for t in timers.values { t.cancel() }
        timers = [:]
        marks = []
        leaving = [:]
        change.forgetAll()
    }

    // MARK: - the mouse, from a canvas window

    fileprivate func press(at p: CGPoint) {
        guard let tool, let session else { return }
        live = Mark(n: next, tool: tool, ink: ink, at: p, time: session.now)
        showLive()
    }

    fileprivate func drag(to p: CGPoint, constrained: Bool) {
        guard live != nil else { return }
        live?.extend(to: p, constrained: constrained)
        showLive()
    }

    fileprivate func release() {
        guard var m = live, let session else { return }
        live = nil
        guard m.isDrawn else {
            // A click, not a drag: the way back to the apps.
            putDown()
            return
        }
        m.end = session.now
        next += 1
        marks.append(m)
        if !m.tool.staysInHand { tool = nil }
        sync()
        onMark(m)
        change.track(m)
        let n = m.n
        timers[n] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Fading.hold))
            guard !Task.isCancelled else { return }
            self?.fade(n, over: Fading.slowly, because: .time)
        }
    }

    // MARK: - fading

    /// Start mark `n` fading, or hurry one already fading.
    private func fade(_ n: Int, over duration: TimeInterval, because why: Fade) {
        let until = Date().addingTimeInterval(duration)
        if let i = marks.firstIndex(where: { $0.n == n }) {
            let m = marks.remove(at: i)
            leaving[n] = (m, until)
            onFade(m, why)
        } else if let l = leaving[n], until < l.until {
            leaving[n] = (l.mark, until)
        } else {
            return
        }
        timers[n]?.cancel()
        for w in windows { w.canvas.fade(n, over: duration) }
        timers[n] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled, let self else { return }
            self.timers[n] = nil
            self.leaving[n] = nil
            self.change.forget(n)
            self.sync()
        }
    }

    // MARK: - the windows

    private func showLive() {
        for w in windows { w.canvas.show(live: live) }
    }

    /// Bring the windows and the Escape tap in line with the state.
    private func sync() {
        let taking = tool != nil
        let needed = taking || live != nil || !marks.isEmpty || !leaving.isEmpty
        if needed, windows.isEmpty { build() }
        if !needed, !windows.isEmpty { tearDown() }
        let shown = marks + leaving.values.map(\.mark)
        for w in windows {
            w.ignoresMouseEvents = !taking
            w.canvas.taking = taking
            w.canvas.show(shown)
            w.canvas.show(live: live)
        }
        if taking, escape == nil {
            escape = EscapeTap { [weak self] in self?.putDown() }
            if escape == nil { Log.line("no Escape tap (Accessibility?); a click puts the tool down") }
        }
        if !taking, let tap = escape {
            tap.stop()
            escape = nil
        }
    }

    private func build() {
        windows = NSScreen.screens.map { CanvasWindow(screen: $0, drawing: self) }
        for w in windows { w.orderFrontRegardless() }
        screens = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.tearDown()
                self.sync()
                // Marks already fading carry on from where they were.
                for (n, l) in self.leaving {
                    for w in self.windows { w.canvas.fade(n, over: max(0.1, l.until.timeIntervalSinceNow)) }
                }
            }
        }
    }

    private func tearDown() {
        for w in windows {
            w.orderOut(nil)
            w.contentView = nil
        }
        windows = []
        if let screens { NotificationCenter.default.removeObserver(screens) }
        screens = nil
    }
}

/// Why a mark left the screen: its time was up, or what it was drawn on changed.
enum Fade: String {
    case time, screen
}

/// One screen's worth of the layer: borderless, transparent, above every app
/// and below the pill, never key, on every space.
private final class CanvasWindow: NSPanel {
    let canvas: CanvasView

    init(screen: NSScreen, drawing: Drawing) {
        canvas = CanvasView(size: screen.frame.size, origin: Space.frame(of: screen).origin,
                            scale: screen.backingScaleFactor, drawing: drawing)
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        contentView = canvas
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    /// The whole screen, menu bar included.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Draws the marks with one pair of shape layers each (a dark edge under the
/// ink), so a drag redraws one path rather than the screen.
private final class CanvasView: NSView {
    var taking = false {
        didSet { if taking != oldValue { window?.invalidateCursorRects(for: self) } }
    }

    /// This screen's top-left corner in the display space.
    private let origin: CGPoint
    private let scale: CGFloat
    private unowned let drawing: Drawing
    private var shown: [Int: MarkLayer] = [:]
    private let live: MarkLayer

    init(size: CGSize, origin: CGPoint, scale: CGFloat, drawing: Drawing) {
        self.origin = origin
        self.scale = scale
        self.drawing = drawing
        live = MarkLayer(scale: scale, frame: CGRect(origin: .zero, size: size))
        super.init(frame: NSRect(origin: .zero, size: size))
        wantsLayer = true
        layer?.addSublayer(live)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.cursorUpdate, .activeAlways, .inVisibleRect],
                                       owner: self))
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("not from a nib") }

    /// A display-space point in this view (y up).
    private func local(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x - origin.x, y: bounds.height - (p.y - origin.y))
    }

    func show(_ marks: [Mark]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let keep = Set(marks.map(\.n))
        for (n, l) in shown where !keep.contains(n) {
            l.removeFromSuperlayer()
            shown[n] = nil
        }
        for m in marks where shown[m.n] == nil {
            let l = MarkLayer(scale: scale, frame: bounds)
            l.set(m, map: local)
            layer?.insertSublayer(l, below: live)
            shown[m.n] = l
        }
        CATransaction.commit()
    }

    /// Fade a mark out from wherever it is now; the drawing removes it after.
    func fade(_ n: Int, over duration: TimeInterval) {
        guard let l = shown[n] else { return }
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = l.presentation()?.opacity ?? l.opacity
        a.toValue = 0
        a.duration = duration
        a.timingFunction = CAMediaTimingFunction(name: .easeIn)
        l.opacity = 0
        l.add(a, forKey: "fade")
    }

    func show(live m: Mark?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        live.set(m, map: local)
        CATransaction.commit()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func cursorUpdate(with event: NSEvent) {
        (taking ? NSCursor.crosshair : NSCursor.arrow).set()
    }

    override func mouseDown(with e: NSEvent) { drawing.press(at: point(e)) }

    override func mouseDragged(with e: NSEvent) {
        drawing.drag(to: point(e), constrained: e.modifierFlags.contains(.shift))
    }

    override func mouseUp(with e: NSEvent) {
        drawing.drag(to: point(e), constrained: e.modifierFlags.contains(.shift))
        drawing.release()
    }

    private func point(_ e: NSEvent) -> CGPoint {
        guard let window else { return .zero }
        return Space.fromCocoa(window.convertPoint(toScreen: e.locationInWindow))
    }
}

private final class MarkLayer: CALayer {
    private let edge = CAShapeLayer()
    private let ink = CAShapeLayer()

    init(scale: CGFloat, frame: CGRect) {
        super.init()
        self.frame = frame
        for l in [edge, ink] {
            l.frame = bounds
            l.fillColor = nil
            l.lineCap = .round
            l.lineJoin = .round
            l.contentsScale = scale
            addSublayer(l)
        }
        edge.strokeColor = Mark.edge
        edge.lineWidth = Mark.width + 2.5
        ink.lineWidth = Mark.width
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    func set(_ m: Mark?, map: (CGPoint) -> CGPoint) {
        let path = m?.path(map)
        edge.path = path
        ink.path = path
        ink.strokeColor = m?.ink.cgColor
    }
}

/// Swallows Escape, and only Escape, while a tool is in hand, and puts the
/// tool down. Every other key goes where it was going. Needs Accessibility,
/// like the gesture.
private final class EscapeTap {
    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    private let onEscape: () -> Void

    init?(onEscape: @escaping () -> Void) {
        self.onEscape = onEscape
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                           options: .defaultTap, eventsOfInterest: mask,
                                           callback: EscapeTap.callback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return nil }
        let source = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        self.port = port
        self.source = source
    }

    func stop() {
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        port = nil
        source = nil
    }

    deinit { stop() }

    private static let callback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let me = Unmanaged<EscapeTap>.fromOpaque(refcon).takeUnretainedValue()
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let port = me.port { CGEvent.tapEnable(tap: port, enable: true) }
            return Unmanaged.passUnretained(event)
        case .keyDown, .keyUp:
            guard event.getIntegerValueField(.keyboardEventKeycode) == 53 else {
                return Unmanaged.passUnretained(event)
            }
            if type == .keyDown {
                let f = me.onEscape
                DispatchQueue.main.async { f() }
            }
            return nil
        default:
            return Unmanaged.passUnretained(event)
        }
    }
}
