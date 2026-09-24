import AppKit
import ApplicationServices
import Foundation
import CarKit
import OSAKit

// What is in front of the person, read two ways at once.
//
// The generic reading works for every app: the front window's title and
// document, the focused element, the selected text. On top of it, an adapter
// for an app that has a better answer: a browser's page URL, Finder's selected
// files, an app's own `desk` command. Both readings are recorded, the generic
// one always, so an adapter that turns out to be wrong for some window never
// costs the record.
//
// Every one of these is a question to another app, answered when that app gets
// round to it. So all of it runs on the reader queue, never on the main thread,
// and each question has a short limit: a hung Finder costs one reading, not
// the pill, the gesture or the session.

/// The one queue that talks to other apps. Serial, so readings arrive in the
/// order they were asked for.
enum Reader {
    static let queue = DispatchQueue(label: "car.reader", qos: .userInitiated)

    /// Do `work` on the queue, then hand its result to the main thread.
    static func run<T>(_ work: @escaping () -> T, then: @escaping @MainActor (T) -> Void) {
        queue.async {
            let value = work()
            DispatchQueue.main.async { MainActor.assumeIsolated { then(value) } }
        }
    }
}

/// The app in front, as the workspace has it: read on the main thread, handed
/// to the reader.
struct Front {
    let pid: pid_t
    let name: String
    let bundle: String
    let bundleURL: URL?

    @MainActor static func now() -> Front? {
        guard let a = NSWorkspace.shared.frontmostApplication else { return nil }
        return Front(pid: a.processIdentifier, name: a.localizedName ?? "", bundle: a.bundleIdentifier ?? "",
                     bundleURL: a.bundleURL)
    }
}

struct Reading {
    var app = ""
    var bundle = ""
    var pid: pid_t = 0
    var windowTitle = ""
    var document = ""
    /// The focused window in the display space: which window a picture is of.
    var windowFrame: CGRect?
    var focus: [String: String] = [:]
    /// The app's adapter's reading, if it has one: the event kind and its fields.
    var adapter: (kind: String, fields: [String: Any])?
}

enum Adapters {
    /// Read the app in front. On the reader queue.
    static func read(_ front: Front) -> Reading {
        var r = Reading(app: front.name, bundle: front.bundle, pid: front.pid)
        let app = AX.app(front.pid)
        if let win = AX.element(app, kAXFocusedWindowAttribute) {
            r.windowTitle = AX.string(win, kAXTitleAttribute) ?? ""
            r.document = AX.string(win, kAXDocumentAttribute) ?? ""
            r.windowFrame = AX.frame(win)
        }
        if let focused = AX.element(app, kAXFocusedUIElementAttribute) {
            r.focus = AX.describe(focused, valueLimit: 300).mapValues { "\($0)" }
        }
        if let kind = kind(of: front) {
            let fields: [String: Any]
            switch kind {
            case "finder": fields = finder()
            case "page": fields = browser(front)
            default: fields = desk(front)
            }
            r.adapter = (kind, fields)
        }
        return r
    }

    /// What is under a point: the app and window there (car's overlays
    /// looked through) and the element. On the reader queue.
    static func under(_ p: CGPoint) -> [String: Any] {
        var f: [String: Any] = [:]
        let window = AX.window(at: p)
        if let window, !window.title.isEmpty { f["window"] = window.title }
        if let el = AX.element(at: p) {
            f["element"] = AX.describe(el, valueLimit: 160)
            if let pid = AX.pid(el), let app = NSRunningApplication(processIdentifier: pid)?.localizedName {
                f["app"] = app
            }
        }
        if f["app"] == nil, let window { f["app"] = window.app }
        return f
    }

    /// The field typing went into. On the reader queue.
    static func focused(_ pid: pid_t) -> [String: Any]? {
        AX.element(AX.app(pid), kAXFocusedUIElementAttribute).map { AX.describe($0, valueLimit: 400) }
    }

    private static func kind(of front: Front) -> String? {
        if front.bundle == "com.apple.finder" { return "finder" }
        if browsers[front.bundle] != nil { return "page" }
        if deskCommand(front) != nil { return "desk" }
        return nil
    }

    // MARK: - an app with its own answer

    /// An app that ships a command of its own name at Contents/Resources,
    /// whose `desk` subcommand prints what the app is showing: `open ...`,
    /// `picked ...`. That is the best reading there is, in the app's own
    /// words, and it costs nothing to support: the app just has to be one.
    static func deskCommand(_ front: Front) -> URL? {
        guard let bundle = front.bundleURL, !front.name.isEmpty else { return nil }
        let url = bundle.appending(path: "Contents/Resources/\(front.name.lowercased())")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    private static func desk(_ front: Front) -> [String: Any] {
        guard let cmd = deskCommand(front) else { return [:] }
        let p = Process()
        p.executableURL = cmd
        p.arguments = ["desk"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [:] }
        // An app that does not answer inside a second loses this reading.
        let pid = p.processIdentifier
        let limit = DispatchWorkItem { kill(pid, SIGKILL) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 1, execute: limit)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        limit.cancel()
        guard p.terminationReason == .exit, let text = String(data: data, encoding: .utf8) else { return [:] }
        var d: [String: Any] = [:]
        for line in text.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            for key in ["open", "picked"] where t.hasPrefix(key + " ") {
                d[key] = t.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
            }
        }
        return d
    }

    // MARK: - Finder: the folder in front and the files picked in it

    private static func finder() -> [String: Any] {
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
        guard let text = Script.run(script) else { return [:] }
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

    private static func browser(_ front: Front) -> [String: Any] {
        guard let name = browsers[front.bundle] else { return [:] }
        let script = front.bundle == "com.apple.Safari" ? """
            tell application "Safari"
                set t to front document
                return (URL of t) & linefeed & (name of t)
            end tell
            """ : """
            tell application "\(name)"
                set t to active tab of front window
                return (URL of t) & linefeed & (title of t)
            end tell
            """
        guard let text = Script.run(script) else { return [:] }
        let parts = text.components(separatedBy: "\n")
        var d: [String: Any] = [:]
        if let u = parts.first, !u.isEmpty { d["url"] = u }
        if parts.count > 1, !parts[1].isEmpty { d["pageTitle"] = parts[1] }
        return d
    }

    /// Ask for the Automation grants, one prompt per app, by asking each a
    /// harmless question. Called from the menu; the questions go on the reader.
    @MainActor static func requestAutomation() {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let names = ["Finder"] + browsers.filter { running.contains($0.key) }.map(\.value)
        Reader.queue.async {
            for name in names { _ = Script.run("tell application \"\(name)\" to get name") }
        }
    }
}

/// AppleScript, run on the reader queue with a language instance of its own:
/// AppleScript is thread-safe per instance, and the shared instance belongs to
/// the main thread. Each script is compiled once, and every Apple event it
/// sends gives up after two seconds.
private enum Script {
    private static let instance = OSALanguage(forName: "AppleScript").map { OSALanguageInstance(language: $0) }
    private static var compiled: [String: OSAScript] = [:]
    /// Each distinct failure is logged once: a missing grant would otherwise
    /// fill the log once a second.
    private static var reported: Set<String> = []

    static func run(_ source: String) -> String? {
        dispatchPrecondition(condition: .onQueue(Reader.queue))
        guard let instance else { return nil }
        let script: OSAScript
        if let s = compiled[source] {
            script = s
        } else {
            script = OSAScript(source: "with timeout of 2 seconds\n\(source)\nend timeout",
                               from: nil, languageInstance: instance, using: [])
            var error: NSDictionary?
            guard script.compileAndReturnError(&error) else {
                report(error)
                return nil
            }
            compiled[source] = script
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if error != nil || result == nil {
            report(error)
            return nil
        }
        return result?.stringValue
    }

    private static func report(_ error: NSDictionary?) {
        let message = (error?[OSAScriptErrorMessageKey] as? String) ?? "\(error ?? [:])"
        guard reported.insert(message).inserted else { return }
        Log.line("applescript: \(message)")
    }
}
