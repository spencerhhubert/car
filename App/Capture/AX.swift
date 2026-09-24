import AppKit
import ApplicationServices
import CarKit

// Small helpers over the accessibility API. Everything here is a read; car
// never posts an action into another app. Each call is a synchronous message
// to the other app, answered when that app gets round to it (or after the
// messaging timeout), so they are made on the reader queue (Adapters.swift),
// never on the main thread.
enum AX {
    static func copy(_ e: AXUIElement, _ attr: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attr as CFString, &value) == .success else { return nil }
        return value
    }

    static func string(_ e: AXUIElement, _ attr: String) -> String? {
        guard let v = copy(e, attr) else { return nil }
        if let s = v as? String { return s }
        if let u = v as? URL { return u.absoluteString }
        if let a = v as? NSAttributedString { return a.string }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }

    static func element(_ e: AXUIElement, _ attr: String) -> AXUIElement? {
        guard let v = copy(e, attr), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    static func elements(_ e: AXUIElement, _ attr: String) -> [AXUIElement] {
        guard let v = copy(e, attr) as? [AnyObject] else { return [] }
        return v.compactMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
    }

    static func parent(of e: AXUIElement) -> AXUIElement? { element(e, kAXParentAttribute) }

    static func settable(_ e: AXUIElement, _ attr: String) -> Bool {
        var can: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(e, attr as CFString, &can) == .success else { return false }
        return can.boolValue
    }

    /// An element's frame in the display space.
    static func frame(_ e: AXUIElement) -> CGRect? {
        guard let p = copy(e, kAXPositionAttribute), let s = copy(e, kAXSizeAttribute),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point),
              AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }

    static func pid(_ e: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(e, &pid) == .success else { return nil }
        return pid
    }

    static func app(_ pid: pid_t) -> AXUIElement {
        let e = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(e, 0.25)
        return e
    }

    // MARK: - what is under a point

    struct Window {
        let pid: pid_t
        let app: String
        let title: String
        let layer: Int

        /// One of car's own windows that float over everything (the pill,
        /// the drawing layer): never what anything is about. car's own
        /// window is an ordinary window like any app's.
        var isOverlay: Bool { pid == getpid() && layer > 0 }
    }

    /// The windows under a point, front to back, as the window server has
    /// them. Windows no one can see are left out, and so are the window
    /// server's own above everything (the pointer, the recording
    /// indicators), which are under every point the pointer is at.
    static func windows(at p: CGPoint) -> [Window] {
        guard let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        let top = Int(CGWindowLevelForKey(.screenSaverWindow))
        return list.compactMap { w in
            let layer = w[kCGWindowLayer as String] as? Int ?? 0
            guard layer < top,
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t,
                  let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: b), r.contains(p),
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0 else { return nil }
            return Window(pid: pid, app: w[kCGWindowOwnerName as String] as? String ?? "",
                          title: w[kCGWindowName as String] as? String ?? "", layer: layer)
        }
    }

    /// The front-most window under a point that is not one of car's
    /// overlays.
    static func window(at p: CGPoint) -> Window? {
        windows(at: p).first { !$0.isOverlay }
    }

    /// The element under a point. car's overlays are looked through: a
    /// drawing sits on top of exactly the thing it is about.
    static func element(at p: CGPoint) -> AXUIElement? {
        let under = windows(at: p)
        var hit: AXUIElement?
        if under.first?.isOverlay != true {
            // The system-wide hit test, which also knows the menu bar.
            let system = AXUIElementCreateSystemWide()
            AXUIElementSetMessagingTimeout(system, 0.25)
            guard AXUIElementCopyElementAtPosition(system, Float(p.x), Float(p.y), &hit) == .success else { return nil }
            return hit
        }
        guard let w = under.first(where: { !$0.isOverlay }),
              AXUIElementCopyElementAtPosition(app(w.pid), Float(p.x), Float(p.y), &hit) == .success
        else { return nil }
        return hit
    }

    // MARK: - describing an element

    /// A short description of an element for the log: role, and whatever it
    /// calls itself. Values are cut to `valueLimit` characters and a secure
    /// field's value is never read.
    static func describe(_ e: AXUIElement, valueLimit: Int = 200) -> [String: Any] {
        var d: [String: Any] = [:]
        let role = string(e, kAXRoleAttribute) ?? ""
        d["role"] = role
        let subrole = string(e, kAXSubroleAttribute)
        if let subrole, subrole != role { d["subrole"] = subrole }
        if let t = clean(string(e, kAXTitleAttribute), valueLimit) { d["title"] = t }
        if let desc = clean(string(e, kAXDescriptionAttribute), valueLimit) { d["description"] = desc }
        if let h = clean(string(e, kAXHelpAttribute), valueLimit) { d["help"] = h }
        if let ph = clean(string(e, "AXPlaceholderValue"), valueLimit) { d["placeholder"] = ph }
        if let u = clean(string(e, kAXURLAttribute), 500) { d["url"] = u }
        if subrole != kAXSecureTextFieldSubrole, let v = clean(string(e, kAXValueAttribute), valueLimit) {
            d["value"] = v
        }
        if let sel = clean(string(e, kAXSelectedTextAttribute), valueLimit) { d["selectedText"] = sel }
        // A cell or row says what it holds through its children's titles.
        if ["AXCell", kAXRowRole, "AXStaticText"].contains(role), d["title"] == nil, d["value"] == nil {
            let words = elements(e, kAXChildrenAttribute).prefix(6).compactMap {
                clean(string($0, kAXValueAttribute) ?? string($0, kAXTitleAttribute), 60)
            }
            if !words.isEmpty { d["text"] = String(words.joined(separator: " · ").prefix(valueLimit)) }
        }
        return d
    }

    /// Runs of whitespace (a terminal's screen is mostly spaces) become one
    /// space; nothing left means no value.
    static func clean(_ s: String?, _ limit: Int) -> String? {
        guard let s else { return nil }
        let t = s.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        return t.isEmpty ? nil : String(t.prefix(limit))
    }
}

/// Points in the global display space: origin at the top-left of the main
/// display, y down. The accessibility API, the window server's window list
/// and ScreenCaptureKit all use it, and so does everything car writes down
/// (clicks, drawings). AppKit's screen coordinates (origin bottom-left, y up)
/// are converted at the edge, here.
enum Space {
    /// The main display's height: what flips AppKit's y into this space's.
    static var mainHeight: CGFloat { CGDisplayBounds(CGMainDisplayID()).height }

    static func fromCocoa(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: mainHeight - p.y) }

    /// A screen's frame in this space.
    static func frame(of screen: NSScreen) -> CGRect {
        let f = screen.frame
        return CGRect(x: f.minX, y: mainHeight - f.maxY, width: f.width, height: f.height)
    }

    /// The display a point is on.
    static func display(at p: CGPoint) -> CGDirectDisplayID? {
        var id: CGDirectDisplayID = 0
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(p, 1, &id, &count) == .success, count > 0 else { return nil }
        return id
    }
}
