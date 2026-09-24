// CarDrive: plays a plan of mouse and keyboard actions into the desktop it
// runs on and takes pictures of the screen, so car can be tested live, end to
// end, on a Mac no one is using. Never run it on a Mac someone is using: every
// action is real input.
//
//   tools/drive.sh [host]                 build it (and put it and car-dev on host)
//   open -W -n /Applications/CarDrive.app --args PLAN OUTDIR
//   open -W -n /Applications/CarDrive.app --args --ask
//                                         ask for its grants, which puts it in
//                                         the lists in System Settings
//
// It is an app so that it holds its own grants: Accessibility (to post
// events) and Screen Recording (for pictures). Launched with `open`, it is
// its own process in the eyes of the privacy system even when the `open`
// came over ssh.
//
// PLAN is one action a line; `#` starts a comment. A point is `X,Y` in the
// display space (points from the top-left of the main display, y down), or
// `pill+X,Y` from the top-left of car's pill.
//
//   click P               left click
//   drag P P [P ...]      press at the first point, drag through the rest, let go
//   shiftdrag P P [P ...] the same with ⇧ held
//   option down|up        the ⌥ key alone
//   key esc               a key: esc, return, space
//   wait SECONDS
//   shot NAME             the main display, every window, to OUTDIR/NAME.png
//
// OUTDIR/log.txt says what was done and when, and why anything failed.
import AppKit
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

let args = CommandLine.arguments
if args.count == 2, args[1] == "--ask" {
    _ = CGRequestPostEventAccess()
    _ = CGRequestScreenCaptureAccess()
    exit(0)
}
guard args.count >= 3 else {
    FileHandle.standardError.write(Data("usage: CarDrive PLAN OUTDIR\n".utf8))
    exit(2)
}
let plan = URL(fileURLWithPath: args[1])
let out = URL(fileURLWithPath: args[2])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
var log = ""
let started = Date()

func note(_ s: String) {
    log += String(format: "%7.3f  ", Date().timeIntervalSince(started)) + s + "\n"
    try? log.write(to: out.appending(path: "log.txt"), atomically: true, encoding: .utf8)
}

let source = CGEventSource(stateID: .hidSystemState)
var flags: CGEventFlags = []

func pause(_ s: Double) { Thread.sleep(forTimeInterval: s) }

func mouse(_ type: CGEventType, _ p: CGPoint) {
    guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: .left)
    else { return }
    e.flags = flags
    e.post(tap: .cghidEventTap)
}

func key(_ code: CGKeyCode, down: Bool) {
    guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return }
    e.flags = flags
    e.post(tap: .cghidEventTap)
}

/// car's pill, found by its size among car's windows.
func pillOrigin() -> CGPoint? {
    let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
    for w in list {
        guard let owner = w[kCGWindowOwnerName as String] as? String, owner.hasPrefix("car"),
              let b = w[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: b),
              r.height == 52, r.width > 400 else { continue }
        return r.origin
    }
    return nil
}

enum Bad: Error { case point(String), noPill }

func point(_ token: Substring) throws -> CGPoint {
    var t = token
    var base = CGPoint.zero
    if t.hasPrefix("pill+") {
        guard let o = pillOrigin() else { throw Bad.noPill }
        base = o
        t = t.dropFirst(5)
    }
    let xy = t.split(separator: ",").compactMap { Double($0) }
    guard xy.count == 2 else { throw Bad.point(String(token)) }
    return CGPoint(x: base.x + xy[0], y: base.y + xy[1])
}

func drag(_ pts: [CGPoint]) {
    mouse(.mouseMoved, pts[0])
    pause(0.05)
    mouse(.leftMouseDown, pts[0])
    for (a, b) in zip(pts, pts.dropFirst()) {
        for i in 1...12 {
            let f = Double(i) / 12
            mouse(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f))
            pause(0.012)
        }
    }
    mouse(.leftMouseUp, pts.last!)
}

func shot(_ name: String) async {
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) else {
            note("shot \(name): no main display")
            return
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let cfg = SCStreamConfiguration()
        cfg.width = Int(CGFloat(display.width) * CGFloat(filter.pointPixelScale))
        cfg.height = Int(CGFloat(display.height) * CGFloat(filter.pointPixelScale))
        cfg.showsCursor = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
        let url = out.appending(path: "\(name).png")
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(dest, image, nil)
        note(CGImageDestinationFinalize(dest) ? "shot \(name)" : "shot \(name): write failed")
    } catch {
        note("shot \(name) failed: \(error.localizedDescription)")
    }
}

note("accessibility \(AXIsProcessTrusted()), post \(CGPreflightPostEventAccess()), screen \(CGPreflightScreenCaptureAccess())")
guard let text = try? String(contentsOf: plan, encoding: .utf8) else {
    note("no plan at \(plan.path)")
    exit(1)
}
let keys: [String: CGKeyCode] = ["esc": 53, "return": 36, "space": 49]
for raw in text.split(separator: "\n") {
    let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
        .trimmingCharacters(in: .whitespaces)
    guard !line.isEmpty else { continue }
    let w = line.split(separator: " ")
    do {
        switch w[0] {
        case "click":
            let p = try point(w[1])
            mouse(.mouseMoved, p)
            pause(0.05)
            mouse(.leftMouseDown, p)
            pause(0.04)
            mouse(.leftMouseUp, p)
        case "drag", "shiftdrag":
            let pts = try w.dropFirst().map(point)
            guard pts.count >= 2 else { throw Bad.point(line) }
            if w[0] == "shiftdrag" {
                flags = .maskShift
                key(56, down: true)
            }
            drag(pts)
            if w[0] == "shiftdrag" {
                flags = []
                key(56, down: false)
            }
        case "option":
            let down = w.count > 1 && w[1] == "down"
            flags = down ? .maskAlternate : []
            key(58, down: down)
        case "key":
            guard w.count > 1, let code = keys[String(w[1])] else { throw Bad.point(line) }
            key(code, down: true)
            pause(0.03)
            key(code, down: false)
        case "wait":
            pause(Double(w.count > 1 ? w[1] : "1") ?? 1)
        case "shot":
            await shot(w.count > 1 ? String(w[1]) : "shot")
        default:
            throw Bad.point(line)
        }
        note(line)
    } catch {
        note("\(line): \(error)")
    }
    pause(0.15)
}
note("done")
