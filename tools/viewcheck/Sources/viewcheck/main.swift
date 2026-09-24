import AppKit
import CarKit
import SwiftUI

// viewcheck OUT ID light|dark: render car's windows for session ID to PNGs
// in OUT. SwiftUI draws nothing into a window that was never shown, so each
// window is shown for a moment fully transparent and deaf to the mouse:
// nothing appears on the screen and nothing can be clicked.
let args = CommandLine.arguments
let out = URL(fileURLWithPath: args[1])
let id = args[2]
let dark = args.count > 3 && args[3] == "dark"
let mode = dark ? "dark" : "light"

@MainActor func snap(_ view: NSView, _ name: String) {
    view.layoutSubtreeIfNeeded()
    view.displayIfNeeded()
    let scale: CGFloat = 2
    guard let layer = view.layer,
          let ctx = CGContext(data: nil, width: Int(view.bounds.width * scale), height: Int(view.bounds.height * scale),
                              bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
    ctx.scaleBy(x: scale, y: scale)
    if view.isFlipped {
        ctx.translateBy(x: 0, y: view.bounds.height)
        ctx.scaleBy(x: 1, y: -1)
    }
    layer.render(in: ctx)
    guard let image = ctx.makeImage(),
          let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
    try? png.write(to: out.appending(path: name))
    print("\(name) \(Int(view.bounds.width))×\(Int(view.bounds.height))")
}

/// Show a window unseen for `seconds`, so SwiftUI draws into it.
@MainActor func unseen(_ w: NSWindow, _ seconds: Double) {
    w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    w.alphaValue = 0
    w.ignoresMouseEvents = true
    w.orderFrontRegardless()
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

/// A SwiftUI view on its own, at a size.
@MainActor func render(_ v: some View, _ size: NSSize, _ name: String) {
    let h = NSHostingView(rootView: v.environment(\.colorScheme, dark ? .dark : .light))
    h.frame = NSRect(origin: .zero, size: size)
    let w = NSWindow(contentRect: h.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    w.isReleasedWhenClosed = false
    w.contentView = h
    unseen(w, 2)
    snap(h, name)
    w.orderOut(nil)
}

struct Viewer: View {
    let script: Script
    @State var id: Int?
    var body: some View { PictureViewer(script: script, viewing: $id) }
}

NSApplication.shared.setActivationPolicy(.accessory)
MainActor.assumeIsolated {
    let app = App()
    let w = SessionsWindow()
    w.library.selectedID = id
    Task { await w.library.follow() }
    Task { await w.script.follow(id) }
    guard let window = w.window else { return }
    window.setFrame(NSRect(x: 0, y: 0, width: 1280, height: 820), display: false)
    unseen(window, 3)
    guard let script = w.script.script else { print("no session \(id)"); return }

    window.orderOut(nil)

    let width: CGFloat = 1072
    let columns = Columns(width: width)
    let flat = VStack(alignment: .leading, spacing: 0) {
        Header(script: script)
        ForEach(script.rows.prefix(40)) { row in
            RowView(row: row, id: script.id, time: script.date(row.start).map(Format.timeSeconds) ?? "",
                    columns: columns, open: { _ in })
        }
        Footer(script: script)
    }
    .padding(.horizontal, Metrics.scriptMargin)
    .frame(width: width, alignment: .topLeading)
    .background(Color(nsColor: .textBackgroundColor))
    let size = NSHostingView(rootView: flat).fittingSize
    render(flat, NSSize(width: width, height: size.height), "script-\(mode).png")

    let rows = VStack(alignment: .leading, spacing: Spacing.m) {
        ForEach(w.library.sessions.prefix(8)) { SessionRow(session: $0) }
    }
    .padding(Spacing.m)
    .frame(width: 220, alignment: .topLeading)
    .background(Color(nsColor: .windowBackgroundColor))
    render(rows, NSSize(width: 220, height: 560), "sessions-\(mode).png")

    if let p = script.pictures.first {
        render(Viewer(script: script, id: p.id), NSSize(width: width, height: 720), "picture-\(mode).png")
    }

    let settings = SettingsWindow(app: app)
    if let s = settings.window, let view = s.contentViewController?.view {
        unseen(s, 1)
        snap(view, "settings-\(mode).png")
        s.orderOut(nil)
    }
}
