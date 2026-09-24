import Foundation

// Everything owl keeps lives under ~/Library/Application Support/<name>:
//
//   config.json        the choices below
//   openrouter.key     the API key, one line, mode 600 (or OPENROUTER_API_KEY
//                      in the environment, which wins)
//   models.json        the last fetched list of audio-capable models
//   sessions/<id>/     one folder per session (see Session.swift)
//
// <name> is owl, or owl-dev for the development copy (`./build.sh` builds it,
// `./build.sh release` the real one). The two run side by side as separate
// apps: their own bundle, command, settings, sessions, log and permissions, so
// working on owl never touches the owl in use. The dev copy leaves the gesture
// off until it is turned on from its menu, so one hold of ⌥ never starts two
// sessions, and reads the key from the real copy's folder when it has none.
struct Config: Codable {
    /// The model that writes the words. Any OpenRouter chat model that takes
    /// audio input.
    var textModel = "google/gemini-3-flash-preview"
    /// Where word times come from: "apple" (the on-device recognizer, which
    /// stamps every word from the sound itself) or "openrouter:<model>" (a
    /// model asked for timestamped segments, which is only as good as the
    /// model's sense of time).
    var timeSource = "apple"
    /// Microphone, by the device UID CoreAudio reports, or nil for the system
    /// default at the moment a session starts.
    var inputUID: String?
    var inputName: String?
    /// Whether a double-click inside a text field starts a session.
    var doubleClick = !Config.isDev
    /// Whether holding ⌥ starts a session.
    var enabled = !Config.isDev

    /// The app this binary is in. Run as a command, it is reached through a
    /// symlink, which Bundle.main does not follow.
    static let bundle: Bundle = {
        guard let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return .main }
        let app = exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return app.pathExtension == "app" ? Bundle(url: app) ?? .main : .main
    }()
    /// "owl" or "owl-dev": the executable's name, which is also the command's.
    static let name = bundle.executableURL?.lastPathComponent ?? "owl"
    static var isDev: Bool { name != "owl" }

    static let root = support(name)
    static let sessionsDir = root.appending(path: "sessions")
    private static let file = root.appending(path: "config.json")

    private static func support(_ name: String) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: name)
    }

    static func load() -> Config {
        guard let data = try? Data(contentsOf: file) else { return Config() }
        do {
            return try JSONDecoder().decode(Config.self, from: data)
        } catch {
            Log.line("config.json unreadable, using defaults: \(error.localizedDescription)")
            return Config()
        }
    }

    func save() {
        do {
            try FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try enc.encode(self).write(to: Self.file, options: .atomic)
        } catch {
            Log.line("config.json write failed: \(error.localizedDescription)")
        }
    }

    /// The OpenRouter key, never logged, never printed.
    static var openRouterKey: String? {
        if let k = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"], !k.isEmpty { return k }
        for dir in isDev ? [root, support("owl")] : [root] {
            guard let s = try? String(contentsOf: dir.appending(path: "openrouter.key"), encoding: .utf8)
            else { continue }
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
        }
        return nil
    }
}

extension Config {
    // Missing keys take their defaults, so a config written by an older owl
    // still loads.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        textModel = try c.decodeIfPresent(String.self, forKey: .textModel) ?? d.textModel
        timeSource = try c.decodeIfPresent(String.self, forKey: .timeSource) ?? d.timeSource
        inputUID = try c.decodeIfPresent(String.self, forKey: .inputUID)
        inputName = try c.decodeIfPresent(String.self, forKey: .inputName)
        doubleClick = try c.decodeIfPresent(Bool.self, forKey: .doubleClick) ?? d.doubleClick
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
    }
}
