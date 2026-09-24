import AppKit
import SwiftUI

// The floating pill at the bottom of the screen. While a session records it
// shows the time and the level and carries the drawing tools: the pen, the
// arrow, the circle and the rectangle, the inks, clearing what was drawn, stop,
// and the X that throws the session away. When nothing is recording it says a
// transcription is running, or how the last one went, and then goes.
//
// It sits over whatever app is in use, so it never takes focus (a
// non-activating panel), joins every space, sits above the drawing layer so it
// can always be reached, and keeps to the screen the mouse is on. It is torn
// down rather than hidden when not needed: a hidden hosting view keeps running
// its animations.
@MainActor
final class Pill {
    enum Phase: Equatable {
        case recording(latched: Bool)
        case transcribing(Int)
        case done(String)
        case failed(String)

        var size: CGSize {
            if case .recording = self { return CGSize(width: 486, height: 52) }
            return CGSize(width: 300, height: 52)
        }
    }

    final class Model: ObservableObject {
        @Published var phase: Phase = .transcribing(1)
        /// Earlier sessions still being transcribed while this one records.
        @Published var behind = 0
    }

    /// Ten times a second while recording: kept apart so the ticking redraws
    /// the clock and the level, not the toolbar.
    final class Meter: ObservableObject {
        @Published var elapsed: Double = 0
        @Published var level: Float = -160
    }

    let model = Model()
    let meter = Meter()
    private let drawing: Drawing
    private let onStop: () -> Void
    private let onDiscard: () -> Void
    private var panel: NSPanel?

    init(drawing: Drawing, onStop: @escaping () -> Void, onDiscard: @escaping () -> Void) {
        self.drawing = drawing
        self.onStop = onStop
        self.onDiscard = onDiscard
    }

    func show(_ phase: Phase) {
        model.phase = phase
        if panel == nil { build() }
        place(force: true)
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
    }

    /// Keep to the screen with the mouse; nothing happens unless it moved screens.
    func follow() { place(force: false) }

    private func build() {
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: model.phase.size),
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
        p.contentView = PillHostingView(model: model, rootView: PillView(model: model, meter: meter,
                                                                      drawing: drawing, onStop: onStop,
                                                                      onDiscard: onDiscard))
        panel = p
    }

    // Bottom centre of the screen with the mouse, above the Dock.
    private func place(force: Bool) {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
        else { return }
        let size = model.phase.size
        let area = screen.visibleFrame
        let frame = NSRect(x: (area.midX - size.width / 2).rounded(), y: area.minY + 90,
                           width: size.width, height: size.height)
        guard force || frame != panel.frame else { return }
        panel.setFrame(frame, display: true)
    }
}

/// Clicks land on the pill only while it has buttons; otherwise they fall
/// through to whatever is under it.
private final class PillHostingView: NSHostingView<PillView> {
    private let model: Pill.Model

    init(model: Pill.Model, rootView: PillView) {
        self.model = model
        super.init(rootView: rootView)
        setAccessibilityElement(false)
    }

    required init(rootView: PillView) { fatalError("use init(model:rootView:)") }
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard case .recording = model.phase else { return nil }
        return super.hitTest(point)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct PillView: View {
    @ObservedObject var model: Pill.Model
    let meter: Pill.Meter
    @ObservedObject var drawing: Drawing
    let onStop: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            switch model.phase {
            case .recording(let latched):
                recording(latched: latched)
            case .transcribing(let n):
                ProgressView().controlSize(.small)
                message(n == 1 ? "transcribing…" : "transcribing \(n) sessions…")
            case .done(let text):
                Image(systemName: "checkmark.circle.fill").font(.system(size: 15)).foregroundStyle(.green)
                message(text)
            case .failed(let text):
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 15)).foregroundStyle(.orange)
                message(text)
            }
        }
        .padding(.horizontal, 14)
        .frame(width: model.phase.size.width, height: model.phase.size.height)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func recording(latched: Bool) -> some View {
        HStack(spacing: 4) {
            Text("🦉").font(.system(size: 16))
            Image(systemName: latched ? "lock.fill" : "waveform")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.red)
                .symbolEffect(.variableColor.iterative, options: .repeating)
        }
        .help(latched ? "recording: press ⌥ to stop" : "recording while ⌥ is held")
        MeterView(meter: meter, behind: model.behind)
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
        Divider().frame(height: 26)
        Button(action: onStop) {
            Image(systemName: "stop.circle.fill")
                .font(.system(size: 17))
                .foregroundStyle(.red)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("stop and transcribe (same as ⌥)")
        Button(action: onDiscard) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("discard this session")
    }

    private func toolButton(_ tool: Tool) -> some View {
        let inHand = drawing.tool == tool
        return Button { drawing.pick(tool) } label: {
            Image(systemName: tool.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(inHand ? drawing.ink.color : Color.primary)
                .frame(width: 26, height: 26)
                .background(inHand ? drawing.ink.color.opacity(0.22) : .clear,
                            in: RoundedRectangle(cornerRadius: 7))
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
    let behind: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Text(Self.clock(meter.elapsed))
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .monospacedDigit()
                if behind > 0 {
                    ProgressView().controlSize(.mini)
                        .help(behind == 1 ? "the last session is still being transcribed"
                                          : "\(behind) earlier sessions are still being transcribed")
                }
            }
            LevelBar(db: meter.level)
        }
        .frame(width: 56, alignment: .leading)
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
