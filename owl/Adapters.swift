import AppKit
import ApplicationServices
import Foundation

// What is in front of him, read two ways at once.
//
// The generic reading works for every app: the front window's title and
// document, the focused element, the selected text. On top of it, an adapter
// for an app that has a better answer: a browser's page URL, Finder's selected
// files. Both readings are recorded, the generic one always, so an adapter
// that turns out to be wrong for some window never costs the record.
struct Reading: Equatable {
    var app = ""
    var bundle = ""
    var windowTitle = ""
    var document = ""
    var focus: [String: String] = [:]
    var extra: [String: Any] = [:]

    static func == (a: Reading, b: Reading) -> Bool {
        a.app == b.app && a.bundle == b.bundle && a.windowTitle == b.windowTitle
            && a.document == b.document && a.focus == b.focus
            && NSDictionary(dictionary: a.extra).isEqual(to: b.extra)
    }
}

enum Adapters {
    /// Read the front app now.
    static func read() -> Reading {
        var r = Reading()
        guard let front = NSWorkspace.shared.frontmostApplication else { return r }
        r.app = front.localizedName ?? ""
        r.bundle = front.bundleIdentifier ?? ""
        let app = AX.app(front.processIdentifier)
        if let win = AX.element(app, kAXFocusedWindowAttribute) {
            r.windowTitle = AX.string(win, kAXTitleAttribute) ?? ""
            if let doc = AX.string(win, kAXDocumentAttribute) { r.document = doc }
        }
        if let focused = AX.element(app, kAXFocusedUIElementAttribute) {
            var f: [String: String] = [:]
            for (k, v) in AX.describe(focused, valueLimit: 300) { f[k] = "\(v)" }
            r.focus = f
        }
        if let a = adapter(for: r.bundle) { r.extra = a(front) }
        return r
    }

    private static func adapter(for bundle: String) -> ((NSRunningApplication) -> [String: Any])? {
        if bundle == "com.apple.finder" { return finder }
        if browsers[bundle] != nil { return browser }
        return nil
    }

    // MARK: - Finder: the folder in front and the files picked in it

    private static func finder(_ app: NSRunningApplication) -> [String: Any] {
        let script = """
        tell application "Finder"
            set out to ""
            try
                set out to POSIX path of (target of front Finder window as alias)
            end try
            set sel to selection as alias list
            repeat with a in sel
                set out to out & linefeed & POSIX path of a
            end repeat
            return out
        end tell
        """
        guard let text = runScript(script) else { return [:] }
        var lines = text.components(separatedBy: "\n")
        let folder = lines.removeFirst()
        var d: [String: Any] = [:]
        if !folder.isEmpty { d["folder"] = folder }
        let files = lines.filter { !$0.isEmpty }
        if !files.isEmpty { d["selected"] = files }
        return d
    }

    // MARK: - browsers: the page in the front tab

    /// Bundle id to the name AppleScript knows the app by.
    static let browsers: [String: String] = [
        "com.apple.Safari": "Safari",
        "com.google.Chrome": "Google Chrome",
        "com.brave.Browser": "Brave Browser",
        "company.thebrowser.Browser": "Arc",
        "com.microsoft.edgemac": "Microsoft Edge",
        "com.vivaldi.Vivaldi": "Vivaldi",
    ]

    private static func browser(_ app: NSRunningApplication) -> [String: Any] {
        guard let bundle = app.bundleIdentifier, let name = browsers[bundle] else { return [:] }
        let script: String
        if bundle == "com.apple.Safari" {
            script = """
            tell application "Safari"
                set t to front document
                return (URL of t) & linefeed & (name of t)
            end tell
            """
        } else {
            script = """
            tell application "\(name)"
                set t to active tab of front window
                return (URL of t) & linefeed & (title of t)
            end tell
            """
        }
        guard let text = runScript(script) else { return [:] }
        let parts = text.components(separatedBy: "\n")
        var d: [String: Any] = [:]
        if let u = parts.first, !u.isEmpty { d["url"] = u }
        if parts.count > 1, !parts[1].isEmpty { d["pageTitle"] = parts[1] }
        return d
    }

    private static func runScript(_ source: String) -> String? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&error)
        if let error {
            Log.line("applescript: \(error[NSAppleScript.errorMessage] ?? error)")
            return nil
        }
        return result.stringValue
    }

    /// Ask for the Automation grants up front, one prompt per app, by running
    /// a harmless script against each.
    static func requestAutomation() {
        _ = runScript("tell application \"Finder\" to get name")
        for name in browsers.values
        where NSWorkspace.shared.runningApplications.contains(where: { $0.localizedName == name }) {
            _ = runScript("tell application \"\(name)\" to get name")
        }
    }
}
