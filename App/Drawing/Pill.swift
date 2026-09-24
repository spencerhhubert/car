import AppKit
import Combine
import OwlKit
import SwiftUI

// The pill at the bottom of the screen. A session runs for hours, so while it
// records the pill is a dot (🦉 ●, and the tool in hand if there is one), and
// opens into the toolbar while the pointer is on it: the time and level, the
// pen, arrow, circle and rectangle, the inks, and wiping the drawings. It
// says a word when something happens ("marker 3 · copied"). Only ⌘⇧R stops a
// session; discarding one is in the menu, behind a question. When nothing is
// recording it says how the last transcription went, then goes.
//
// It sits over whatever app is in use, so it never takes focus (a
// non-activating panel), joins every space, sits above the drawing layer so
// it can always be reached, and keeps to the screen the mouse is on. It is
// torn down rather than hidden when not needed, and ticks only while open.
@MainActor
final class Pill {
    enum Phase: Equatable {
        case recording
        /// Something taking a while: "transcribing…".
        case working(String)
        /// A moment's word when nothing is recording.
        case said(String, ok: Bool)
    }

    final class Model: ObservableObject {
        @Published var phase: Phase = .recording
        /// Open into the toolbar: the pointer is on the pill.
        @Published var open = false
        /// A moment's word while recording.
        @Published var note: String?
    }

    /// Ten times a second while the toolbar is open: kept apart so the
    /// ticking redraws the clock and the level, not the toolbar.
    final class Meter: ObservableObject {
        @Published var elapsed: Double = 0
        @Published var level: Float = -160
    }

    let model = Model()
    let meter = Meter()
    /// Where the clock and the level come from while recording.
    var reading: (() -> (elapsed: Double, level: Float))?
    private let drawing: Drawing
    private var panel: NSPanel?
    private var ticker: Timer?
    private var follower: Timer?
    private var closing: Task<Void, Never>?
    private var noteTask: Task<Void, Never>?
    private var watch: AnyCancellable?

    init(drawing: Drawing) {
        self.drawing = drawing
        // A tool picked or put down changes the dot's size.
        watch = drawing.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.place(force: false) } }
        }
    }

    func show(_ phase: Phase) {
        model.phase = phase
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

    /// A word on the pill for a moment, while recording.
    func say(_ note: String) {
        model.note = note
        place(force: false)
        noteTask?.cancel()
        noteTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
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
        let wanted = model.phase == .recording && model.open
        if !wanted {
            ticker?.invalidate()
            ticker = nil
            return
        }
        guard ticker == nil else { return }
        let update = { [weak self] in
            guard let self, let r = self.reading?() else { return }
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
            if model.open { return CGSize(width: 404, height: 52) }
            if model.note != nil { return CGSize(width: 250, height: 34) }
            return CGSize(width: drawing.tool == nil ? 60 : 84, height: 34)
        case .working, .said:
            return CGSize(width: 300, height: 34)
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
        p.contentView = PillHostingView(pill: self, rootView: PillView(model: model, meter: meter, drawing: drawing))
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
        let frame = NSRect(x: (screenFrame.midX - size.width / 2).rounded(), y: screenFrame.minY + 90,
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

private struct PillView: View {
    @ObservedObject var model: Pill.Model
    let meter: Pill.Meter
    @ObservedObject var drawing: Drawing

    var body: some View {
        HStack(spacing: 8) {
            switch model.phase {
            case .recording:
                if model.open { toolbar } else { dot }
            case .working(let text):
                ProgressView().controlSize(.small)
                message(text)
            case .said(let text, let ok):
                Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(ok ? .green : .orange)
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
            .font(.system(size: 12.5, weight: .medium, design: .rounded))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var dot: some View {
        Text("🦉").font(.system(size: 15))
        Circle().fill(.red).frame(width: 8, height: 8)
        if let tool = drawing.tool {
            Image(systemName: tool.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(drawing.ink.color)
        }
        if let note = model.note { message(note) }
    }

    @ViewBuilder
    private var toolbar: some View {
        Text("🦉").font(.system(size: 16)).help("recording: ⌘⇧R stops, ⌥ ⌥ sets a marker")
        MeterView(meter: meter)
        Divider().frame(height: 26)
        HStack(spacing: 2) {
            ForEach(Tool.allCases, id: \.self) { toolButton($0) }
        }
        HStack(spacing: 3) {
            ForEach(Ink.allCases, id: \.self) { inkButton($0) }
        }
        Button { drawing.clear() } label: {
            Image(systemName: "trash")
                .font(.system(size: 13, weight: .medium))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(drawing.marks.isEmpty ? .tertiary : .secondary)
        .disabled(drawing.marks.isEmpty)
        .help("wipe the drawings off the screen (the session keeps them)")
    }

    private func toolButton(_ tool: Tool) -> some View {
        let inHand = drawing.tool == tool
        return Button { drawing.pick(tool) } label: {
            Image(systemName: tool.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(inHand ? drawing.ink.color : Color.primary)
                .frame(width: 26, height: 26)
                .background(inHand ? drawing.ink.color.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tool.help)
    }

    private func inkButton(_ ink: Ink) -> some View {
        let chosen = drawing.ink == ink
        return Button { drawing.ink = ink } label: {
            Circle()
                .fill(ink.color)
                .frame(width: 12, height: 12)
                .padding(2.5)
                .overlay(Circle().strokeBorder(chosen ? Color.primary : .clear, lineWidth: 1.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(ink.rawValue)
    }
}

private struct MeterView: View {
    @ObservedObject var meter: Pill.Meter

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(Self.clock(meter.elapsed))
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .monospacedDigit()
            LevelBar(db: meter.level)
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
        case .pen: "pen: draw freehand; stays in hand until clicked again, Esc, or a click"
        case .arrow: "arrow: point at something (⇧ for 45°)"
        case .circle: "circle: ring something (⇧ for a true circle)"
        case .rectangle: "rectangle: box something in (⇧ for a square)"
        }
    }
}

private extension Ink {
    var color: Color { Color(cgColor: cgColor) }
}
