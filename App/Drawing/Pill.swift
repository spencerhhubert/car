import AppKit
import Observation
import CarKit
import SwiftUI

// The pill at the bottom of the screen. A session runs for hours, so while it
// records the pill is a dot (🏎️ ●, and the tool in hand if there is one)
// that brightens with the sound coming in, so a glance says the microphone
// hears you. It opens into the toolbar while the pointer is on it: the time
// and level, pause and stop, the pen, arrow, circle and rectangle, the inks,
// and the eraser, which wipes the drawings off the screen (never the
// session). Every button lights up under the pointer and says what it does
// if the pointer rests on it. It says a word when something happens
// ("marker 3 · copied"). Discarding a session is in the menu, behind a
// question. When nothing is recording it says how the last transcription
// went, then goes.
//
// It sits over whatever app is in use, so it never takes focus (a
// non-activating panel), joins every space, sits above the drawing layer so
// it can always be reached, and keeps to the screen the mouse is on. It is
// torn down rather than hidden when not needed, and ticks only while
// recording (not while paused): ten times a second, redrawing only what
// changed.
@MainActor
final class Pill {
    enum Phase: Equatable {
        case recording
        /// Something taking a while: "transcribing…".
        case working(String)
        /// A moment's word when nothing is recording.
        case said(String, ok: Bool)
    }

    @MainActor @Observable
    final class Model {
        var phase: Phase = .recording
        /// Open into the toolbar: the pointer is on the pill.
        var open = false
        /// A moment's word while recording.
        var note: String?
        /// The session is paused: nothing is being recorded.
        var paused = false
    }

    /// Ten times a second while the toolbar is open: kept apart so the
    /// ticking redraws the clock and the level, not the toolbar.
    @MainActor @Observable
    final class Meter {
        var elapsed: Double = 0
        var level: Float = -160
        /// How loud the sound coming in is, 0 to 1 in tenths, falling
        /// slowly: what the dot shows.
        var voice: Double = 0
    }

    let model = Model()
    let meter = Meter()
    /// Where the clock and the level come from while recording.
    var reading: (() -> (elapsed: Double, level: Float))?
    private let drawing: Drawing
    private let actions: Actions
    private var panel: NSPanel?
    private var ticker: Timer?
    private var follower: Timer?
    private var closing: Task<Void, Never>?
    private var noteTask: Task<Void, Never>?
    private var watch: Task<Void, Never>?

    /// What the toolbar's session buttons do.
    struct Actions {
        let pause: () -> Void
        let stop: () -> Void
    }

    init(drawing: Drawing, actions: Actions) {
        self.drawing = drawing
        self.actions = actions
        // A tool picked or put down changes the dot's size.
        watch = Task { [weak self] in
            for await _ in Observations({ drawing.tool == nil }) { self?.place(force: false) }
        }
    }

    func show(_ phase: Phase, paused: Bool = false) {
        model.phase = phase
        model.paused = paused
        if phase != .recording {
            model.open = false
            model.note = nil
        }
        if panel == nil { build() }
        place(force: true)
        panel?.orderFrontRegardless()
        tick()
        follower?.invalidate()
        follower = phase == .recording
            ? Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.place(force: false) }
            }
            : nil
    }

    func hide() {
        ticker?.invalidate(); ticker = nil
        follower?.invalidate(); follower = nil
        closing?.cancel(); closing = nil
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        model.open = false
        model.note = nil
    }

    /// A word on the pill while recording, for `seconds` or until the next.
    func say(_ note: String, for seconds: Double = 2) {
        model.note = note
        place(force: false)
        noteTask?.cancel()
        noteTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            self.model.note = nil
            self.place(force: false)
        }
    }

    /// The pointer came onto the pill, or left it.
    fileprivate func hover(_ inside: Bool) {
        guard model.phase == .recording else { return }
        closing?.cancel()
        if inside {
            setOpen(true)
        } else {
            closing = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(0.6))
                guard !Task.isCancelled else { return }
                self?.setOpen(false)
            }
        }
    }

    private func setOpen(_ open: Bool) {
        guard model.open != open else { return }
        model.open = open
        place(force: false)
        tick()
    }

    private func tick() {
        let wanted = model.phase == .recording && !model.paused
        if !wanted {
            ticker?.invalidate()
            ticker = nil
            meter.voice = 0
            return
        }
        guard ticker == nil else { return }
        let update = { [weak self] in
            guard let self, let r = self.reading?() else { return }
            // Quiet (−48 dB) to speaking up (−18 dB), rising at once and
            // falling over half a second, in tenths so the dot redraws only
            // when it would look different.
            let heard = min(1, max(0, (Double(r.level) + 48) / 30))
            let voice = (max(heard, self.meter.voice * 0.75) * 10).rounded() / 10
            if voice != self.meter.voice { self.meter.voice = voice }
            // The clock and the level bar are only on the open toolbar.
            guard self.model.open else { return }
            self.meter.elapsed = r.elapsed
            self.meter.level = r.level
        }
        update()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated { update() }
        }
    }

    private var size: CGSize {
        switch model.phase {
        case .recording:
            if model.open { return Metrics.Pill.toolbar }
            if model.note != nil { return Metrics.Pill.note }
            return drawing.tool == nil ? Metrics.Pill.dot : Metrics.Pill.dotWithTool
        case .working, .said:
            return Metrics.Pill.message
        }
    }

    private func build() {
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .popUpMenu
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        // car is never the app in front while the pill is used; without
        // this, the buttons would never say what they do.
        p.allowsToolTipsWhenApplicationIsInactive = true
        p.contentView = PillHostingView(pill: self, rootView: PillView(model: model, meter: meter, drawing: drawing,
                                                                        actions: actions))
        panel = p
    }

    // Bottom centre of the screen with the mouse, above the Dock. The bottom
    // edge stays put as the pill grows and shrinks.
    private func place(force: Bool) {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
        else { return }
        let size = size
        let area = screen.visibleFrame
        // While the pointer is on the pill it stays on its screen.
        let screenFrame = model.open ? (panel.screen?.visibleFrame ?? area) : area
        let frame = NSRect(x: (screenFrame.midX - size.width / 2).rounded(), y: screenFrame.minY + Metrics.Pill.lift,
                           width: size.width, height: size.height)
        guard force || frame != panel.frame else { return }
        panel.setFrame(frame, display: true)
    }
}

/// Takes clicks only while recording (the toolbar's buttons); otherwise
/// they fall through. Tells the pill when the pointer comes and goes.
private final class PillHostingView: NSHostingView<PillView> {
    private weak var pill: Pill?

    init(pill: Pill, rootView: PillView) {
        self.pill = pill
        super.init(rootView: rootView)
        setAccessibilityElement(false)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    required init(rootView: PillView) { fatalError("use init(pill:rootView:)") }
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    override func mouseEntered(with event: NSEvent) { MainActor.assumeIsolated { pill?.hover(true) } }
    override func mouseExited(with event: NSEvent) { MainActor.assumeIsolated { pill?.hover(false) } }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard MainActor.assumeIsolated({ pill?.model.phase == .recording }) else { return nil }
        return super.hitTest(point)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct PillView: View {
    let model: Pill.Model
    let meter: Pill.Meter
    let drawing: Drawing
    let actions: Pill.Actions

    var body: some View {
        HStack(spacing: Spacing.s) {
            switch model.phase {
            case .recording:
                if model.open { toolbar } else { dot }
            case .working(let text):
                ProgressView().controlSize(.small)
                message(text)
            case .said(let text, let ok):
                Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(ok ? .green : Tint.failed)
                message(text)
            }
        }
        .padding(.horizontal, model.phase == .recording && !model.open && model.note == nil ? 10 : 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(TextStyle.hud.font)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var dot: some View {
        Text("🏎️").font(.system(size: 15))
        Light(meter: meter, paused: model.paused)
        if let tool = drawing.tool {
            Image(systemName: tool.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Tint.ink(drawing.ink))
        }
        if let note = model.note { message(note) }
    }

    @ViewBuilder
    private var toolbar: some View {
        Text("🏎️").font(.system(size: 16))
            .help("Recording. ⌘ ⌥ ⌥ stops, ⌥ ⌥ sets a marker, ⇧ ⌥ ⌥ copies what you just said.")
        MeterView(meter: meter, paused: model.paused)
        Divider().frame(height: 28)
        HStack(spacing: Spacing.xxs) {
            symbolButton(model.paused ? "play.fill" : "pause.fill",
                         model.paused ? "Resume recording" : "Pause: record nothing until you resume. The session stays open.",
                         action: actions.pause)
            symbolButton("stop.fill", "Stop the session (⌘ ⌥ ⌥). It is kept, and its last words are transcribed.",
                         action: actions.stop)
        }
        Divider().frame(height: 28)
        HStack(spacing: Spacing.xxs) {
            ForEach(Tool.allCases, id: \.self) { tool in
                symbolButton(tool.symbol, tool.help, lit: drawing.tool == tool ? Tint.ink(drawing.ink) : nil) {
                    drawing.pick(tool)
                }
            }
        }
        .disabled(model.paused)
        HStack(spacing: Spacing.xxs) {
            ForEach(Ink.allCases, id: \.self) { inkButton($0) }
        }
        .disabled(model.paused)
        symbolButton("eraser", "Wipe the drawings off the screen. The session keeps them.") { drawing.clear() }
            .disabled(drawing.marks.isEmpty)
    }

    private func symbolButton(_ symbol: String, _ help: String, lit: Color? = nil,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: Metrics.Pill.symbol, weight: .semibold))
                .foregroundStyle(lit ?? Color.primary)
        }
        .buttonStyle(PillButtonStyle(lit: lit))
        .help(help)
    }

    private func inkButton(_ ink: Ink) -> some View {
        let chosen = drawing.ink == ink
        return Button { drawing.ink = ink } label: {
            Circle()
                .fill(Tint.ink(ink))
                .frame(width: Metrics.Pill.ink, height: Metrics.Pill.ink)
                .padding(3)
                .overlay(Circle().strokeBorder(chosen ? Color.primary : .clear, lineWidth: 1.5))
        }
        .buttonStyle(PillButtonStyle(size: Metrics.Pill.inkTarget, shape: .circle))
        .help(ink.rawValue.capitalized)
    }
}

/// A toolbar button: lit under the pointer, darker while pressed, and in a
/// tool's ink while it is in hand, so where a click lands is always shown.
private struct PillButtonStyle: ButtonStyle {
    enum Shape { case rounded, circle }
    var lit: Color? = nil
    var size = Metrics.Pill.button
    var shape = Shape.rounded

    func makeBody(configuration: Configuration) -> some View {
        Face(configuration: configuration, style: self)
    }

    private struct Face: View {
        let configuration: Configuration
        let style: PillButtonStyle
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .frame(width: style.size, height: style.size)
                .background { backdrop }
                .contentShape(Rectangle())
                .opacity(enabled ? 1 : 0.35)
                .onHover { hovering = $0 }
        }

        @ViewBuilder
        private var backdrop: some View {
            switch style.shape {
            case .rounded: RoundedRectangle(cornerRadius: Radius.button).fill(fill)
            case .circle: Circle().fill(fill)
            }
        }

        private var fill: Color {
            if let lit = style.lit { return lit.opacity(configuration.isPressed ? 0.34 : 0.22) }
            guard enabled else { return .clear }
            if configuration.isPressed { return .primary.opacity(0.18) }
            return hovering ? .primary.opacity(0.1) : .clear
        }
    }
}

/// The dot: red, brightening and glowing with the sound coming in; a pause
/// sign while paused.
private struct Light: View {
    let meter: Pill.Meter
    let paused: Bool

    var body: some View {
        if paused {
            Image(systemName: "pause.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: Metrics.Pill.light, height: Metrics.Pill.light)
        } else {
            let v = meter.voice
            Circle()
                .fill(Tint.recording)
                .frame(width: Metrics.Pill.light, height: Metrics.Pill.light)
                .opacity(0.45 + 0.55 * v)
                .scaleEffect(1 + 0.25 * v)
                .shadow(color: Tint.recording.opacity(0.9 * v), radius: 1 + 4 * v)
                .animation(.easeOut(duration: 0.1), value: v)
        }
    }
}

private struct MeterView: View {
    let meter: Pill.Meter
    let paused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(paused ? "Paused" : Self.clock(meter.elapsed))
                .font(TextStyle.hud.font)
                .monospacedDigit()
                .foregroundStyle(paused ? .secondary : .primary)
            LevelBar(db: paused ? -160 : meter.level)
        }
        .frame(width: 60, alignment: .leading)
    }

    static func clock(_ s: Double) -> String {
        let t = Int(s)
        return t < 3600 ? String(format: "%d:%02d", t / 60, t % 60)
                        : String(format: "%d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60)
    }
}

private struct LevelBar: View {
    let db: Float
    private var fraction: Double { (max(-60, min(0, Double(db))) + 60) / 60 }
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(fraction > 0.02 ? Color.green : Color.secondary)
                    .frame(width: max(2, geo.size.width * fraction))
            }
        }
        .frame(height: 4)
        .animation(.linear(duration: 0.05), value: fraction)
    }
}

private extension Tool {
    var help: String {
        switch self {
        case .pen: "Pen: draw freehand. Stays in hand until clicked again, Esc, or a click."
        case .arrow: "Arrow: point at something (⇧ for 45°)."
        case .circle: "Circle: ring something (⇧ for a true circle)."
        case .rectangle: "Rectangle: box something in (⇧ for a square)."
        }
    }
}
