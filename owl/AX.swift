import AppKit
import ApplicationServices

// Small helpers over the accessibility API. Everything here is a read; owl
// never posts an action into another app.
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

    static func frame(_ e: AXUIElement) -> CGRect? {
        guard let p = copy(e, kAXPositionAttribute), let s = copy(e, kAXSizeAttribute) else { return nil }
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

    /// The element under a point in Cocoa screen coordinates.
    static func elementAt(_ point: CGPoint) -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.2)
        guard let primary = NSScreen.screens.first else { return nil }
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(primary.frame.maxY - point.y), &hit)
                == .success else { return nil }
        return hit
    }

    /// A short description of an element for the log: role, and whatever it
    /// calls itself. Values are cut to `valueLimit` characters and a secure
    /// field's value is never read.
    static func describe(_ e: AXUIElement, valueLimit: Int = 200) -> [String: Any] {
        var d: [String: Any] = [:]
        let role = string(e, kAXRoleAttribute) ?? ""
        d["role"] = role
        if let sub = string(e, kAXSubroleAttribute), sub != role { d["subrole"] = sub }
        if let t = string(e, kAXTitleAttribute), !t.isEmpty { d["title"] = t }
        if let desc = string(e, kAXDescriptionAttribute), !desc.isEmpty { d["description"] = desc }
        if let h = string(e, kAXHelpAttribute), !h.isEmpty { d["help"] = h }
        if let ph = string(e, "AXPlaceholderValue"), !ph.isEmpty { d["placeholder"] = ph }
        if let u = string(e, kAXURLAttribute), !u.isEmpty { d["url"] = u }
        if string(e, kAXSubroleAttribute) != kAXSecureTextFieldSubrole, let v = string(e, kAXValueAttribute), !v.isEmpty {
            d["value"] = String(v.prefix(valueLimit))
        }
        if let sel = string(e, kAXSelectedTextAttribute), !sel.isEmpty {
            d["selectedText"] = String(sel.prefix(valueLimit))
        }
        // A cell or row says what it holds through its children's titles.
        if ["AXCell", kAXRowRole, "AXStaticText"].contains(role), d["title"] == nil, d["value"] == nil {
            let words = elements(e, kAXChildrenAttribute).prefix(6).compactMap {
                string($0, kAXValueAttribute) ?? string($0, kAXTitleAttribute)
            }.filter { !$0.isEmpty }
            if !words.isEmpty { d["text"] = words.joined(separator: " · ").prefix(valueLimit).description }
        }
        return d
    }
}
