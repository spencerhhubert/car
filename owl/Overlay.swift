import AppKit
import SwiftUI

// The floating pill that says owl is recording.
//
// It sits over whatever app is in use, so everything here is about not
// disturbing that app: a non-activating panel (focus never moves), clicks
// that fall through everywhere except the X, joins every space.
@MainActor
final class Overlay {
    private var panel: NSPanel?

    func show(_ content: PillView) {
        if panel == nil { build() }
        (panel?.contentView as? PillHostingView)?.rootView = content
        position()
        panel?.orderFrontRegardless()
    }

    func hide() {
        // Torn down, not ordered out: a hidden hosting view keeps running the
        // icon's animation at frame rate.
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
    }

    private func build() {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 240, height: 52),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.ignoresMouseEvents = false
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.contentView = PillHostingView(rootView: PillView(state: .recording(0, -160, latched: false)))
        panel = p
    }

    // Bottom centre of the screen with the mouse, above the Dock.
    private func position() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 90))
    }
}

private final class PillHostingView: NSHostingView<PillView> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard PillView.cancelHitRect.contains(local) else { return nil }
        return super.hitTest(point)
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct PillView: View {
    static let cancelHitRect = NSRect(x: 196, y: 0, width: 44, height: 52)

    enum State: Equatable {
        case recording(Double, Float, latched: Bool)
        case finishing(String)
        case failed(String)
    }
    let state: State
    var onCancel: () -> Void = {}

    var body: some View {
        HStack(spacing: 10) {
            icon
            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if case .recording(_, let db, _) = state { LevelBar(db: db) }
            }
            Spacer(minLength: 0)
            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("discard this session")
        }
        .padding(.horizontal, 16)
        .frame(width: 240, height: 52)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
    }

    @ViewBuilder
    private var icon: some View {
        switch state {
        case .recording(_, _, let latched):
            HStack(spacing: 4) {
                Text("🦉").font(.system(size: 16))
                Image(systemName: latched ? "lock.fill" : "waveform")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.red)
                    .symbolEffect(.variableColor.iterative, options: .repeating)
            }
        case .finishing:
            ProgressView().controlSize(.small)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 15)).foregroundStyle(.orange)
        }
    }

    private var label: String {
        switch state {
        case .recording(let s, _, let latched):
            latched ? String(format: "%.0fs · ⌥ to stop", s) : String(format: "recording  %.1fs", s)
        case .finishing(let what): what
        case .failed(let why): why
        }
    }
}

struct LevelBar: View {
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
