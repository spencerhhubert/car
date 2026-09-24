import AppKit
import CarKit
import SwiftUI

// viewcheck OUT ID light|dark: check car's window against session ID.
//
//   stress   scroll it (a mouse wheel, jumps) and resize it, the way a
//            person does, and report any step the main thread took longer
//            than a quarter second to come back from
//   fit      every row's height as ScriptLayout gives it, against the height
//            SwiftUI needs for it, at three widths: a row that needs more
//            would be cut off
//   pictures the script's rows at their given heights, the sidebar's rows,
//            the picture viewer and Settings, as PNGs in OUT
//
// SwiftUI draws nothing into a window that was never shown, so each window is
// shown for a moment fully transparent and deaf to the mouse: nothing appears
// on the screen and nothing can be clicked. Events are handed to the window's
// own views; nothing is posted to the system.
let args = CommandLine.arguments
let out = URL(fileURLWithPath: args[1])
let id = args[2]
let dark = args.count > 3 && args[3] == "dark"
let mode = dark ? "dark" : "light"
var failed = false

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
    print("picture  \(name)")
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

@MainActor func tableScroll(in v: NSView) -> NSScrollView? {
    if let s = v as? NSScrollView, s.documentView is NSTableView, !(s.documentView is NSOutlineView) { return s }
    for c in v.subviews { if let s = tableScroll(in: c) { return s } }
    return nil
}

/// Time one step; complain about a slow one.
@MainActor func step(_ what: String, _ body: () -> Void) -> Double {
    let start = Date()
    body()
    RunLoop.main.run(until: Date().addingTimeInterval(0.005))
    let took = Date().timeIntervalSince(start)
    if took > 0.25 {
        print("stress   SLOW \(what): \(Int(took * 1000)) ms")
        failed = true
    }
    return took
}

@MainActor func stress(_ window: NSWindow) {
    guard let sv = tableScroll(in: window.contentView!), let doc = sv.documentView else {
        print("stress   no table")
        failed = true
        return
    }
    var worst = 0.0
    var rng = SystemRandomNumberGenerator()
    for i in 0..<600 {
        let dy = Int32(i % 120 < 60 ? -6 : 6) * Int32(1 + i % 3)
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: dy, wheel2: 0, wheel3: 0),
              let e = NSEvent(cgEvent: cg) else { continue }
        worst = max(worst, step("wheel \(i)") { sv.scrollWheel(with: e) })
    }
    for i in 0..<200 {
        let h = max(0, doc.frame.height - sv.contentView.bounds.height)
        let y = i % 20 == 0 ? (i % 40 == 0 ? h : 0) : CGFloat.random(in: 0...max(1, h), using: &rng)
        worst = max(worst, step("jump \(i)") {
            sv.contentView.scroll(to: NSPoint(x: 0, y: y))
            sv.reflectScrolledClipView(sv.contentView)
        })
    }
    let frame = window.frame
    for i in 0..<60 {
        let w = frame.width + CGFloat((i % 30) - 15) * 12
        worst = max(worst, step("resize \(i)") {
            window.setFrame(NSRect(x: frame.minX, y: frame.minY, width: w, height: frame.height), display: true)
        })
    }
    window.setFrame(frame, display: true)
    print("stress   600 wheel steps, 200 jumps, 60 resizes; slowest \(Int(worst * 1000)) ms; content \(Int(doc.frame.height)) pt")
}

@MainActor func fit(_ script: Script) {
    let lines = [ScriptLine.header] + script.rows.map(ScriptLine.row) + [.footer]
    for width in [860.0, 1072.0, 1400.0] {
        let layout = ScriptLayout(width: width)
        var short: [String] = []
        var air: [CGFloat] = []
        for line in lines {
            let given = line.height(in: layout, script: script, expanded: false)
            let view = LineView(line: line, script: script, layout: layout).fixedSize(horizontal: false, vertical: true)
                .environment(\.colorScheme, dark ? .dark : .light)
            let need = NSHostingController(rootView: view)
                .sizeThatFits(in: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)).height
            if need > given + 0.5 { short.append("\(line.id) needs \(Int(need.rounded(.up))) has \(Int(given))") }
            air.append(given - need)
        }
        air.sort()
        print("fit      width \(Int(width)): \(lines.count) lines, \(short.count) too short\(short.isEmpty ? "" : ": " + short.prefix(6).joined(separator: "; ")); " +
              "spare room median \(Int(air[air.count / 2])) pt, most \(Int(air.last ?? 0)) pt")
        if !short.isEmpty { failed = true }
    }
}

struct Viewer: View {
    let script: Script
    @State var id: Int?
    var body: some View { PictureViewer(script: script, viewing: $id) }
}

NSApplication.shared.setActivationPolicy(.accessory)
MainActor.assumeIsolated {
    let app = App()
    let w = MainWindow(app: app)
    w.library.page = .session(id)
    guard let window = w.window else { return }
    window.setFrame(NSRect(x: 0, y: 0, width: 1280, height: 820), display: false)
    unseen(window, 3)
    guard let model = (window.contentViewController as? NSSplitViewController)?.splitViewItems.last?.viewController,
          tableScroll(in: model.view) != nil else { print("no script on show"); failed = true; return }
    stress(window)

    // The script's rows at the heights the table gives them, clipped as the
    // table clips them.
    let reader = ScriptReader(id: id)
    var script: Script?
    let done = DispatchSemaphore(value: 0)
    Task.detached { script = await reader.read(); done.signal() }
    while done.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    guard let script else { print("no session \(id)"); failed = true; return }
    fit(script)

    let width: CGFloat = 1072
    let layout = ScriptLayout(width: width)
    let lines = Array(([ScriptLine.header] + script.rows.map(ScriptLine.row) + [.footer]).prefix(40))
    let flat = VStack(spacing: 0) {
        ForEach(lines) { line in
            LineView(line: line, script: script, layout: layout)
                .frame(height: line.height(in: layout, script: script, expanded: false))
                .clipped()
        }
    }
    .frame(width: width)
    .background(Color(nsColor: .textBackgroundColor))
    let height = lines.reduce(0) { $0 + $1.height(in: layout, script: script, expanded: false) }
    render(flat, NSSize(width: width, height: height), "script-\(mode).png")

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
    let settings = SettingsModel(app: app)
    settings.reload()
    render(SettingsView(model: settings), NSSize(width: 900, height: 1500), "settings-\(mode).png")
    render(Sidebar(library: w.library), NSSize(width: 240, height: 400), "sidebar-\(mode).png")
    window.orderOut(nil)
}
exit(failed ? 1 : 0)
