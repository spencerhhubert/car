import Foundation

// Everything owl keeps lives under ~/Library/Application Support/<name>:
//
//   config.json        the choices below
//   openrouter.key     the API key, one line, mode 600 (or OPENROUTER_API_KEY
//                      in the environment, which wins)
//   owl.sqlite         the catalog: every session and where its files are
//   models.json        the last fetched list of audio-capable models
//   sessions/<id>/     each session's files (Session.swift)
//
// <name> is owl, or owl-dev for the development copy (`./build.sh` builds it,
// `./build.sh release` the real one). The two run side by side as separate
// apps: their own bundle, command, settings, catalog, sessions, log and
// permissions, so working on owl never touches the owl in use. The dev copy
// leaves its keys off until they are turned on from its menu, since both
// cannot own ⌘⇧R at once, and reads the key from the real copy's folder when
// it has none. OWL_ROOT in the environment puts everything in another folder
// (the tests use it).
public struct Config: Codable, Sendable {
    /// The model that writes the words: any OpenRouter chat model that takes
    /// audio. Gemini flash measured best for words; see the README.
    public var textModel = "google/gemini-3-flash-preview"
    /// Where word times come from: "apple" (the on-device recognizer, which
    /// stamps every word from the sound itself) or "openrouter:<model>" (a
    /// model asked for timestamped segments, only as good as its sense of
    /// time).
    public var timeSource = "apple"
    /// Microphone, by the device UID CoreAudio reports, or nil for the system
    /// default at the moment a session starts.
    public var inputUID: String?
    public var inputName: String?
    /// Whether ⌘⇧R and the double tap of ⌥ are owl's.
    public var keys = !Config.isDev

    public init() {}

    /// The app this binary is in. Run as a command, it is reached through a
    /// symlink, which Bundle.main does not follow.
    public static let bundle: Bundle = {
        guard let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return .main }
        let app = exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return app.pathExtension == "app" ? Bundle(url: app) ?? .main : .main
    }()
    /// "owl" or "owl-dev": the executable's name, which is also the command's.
    public static let name = bundle.executableURL?.lastPathComponent ?? "owl"
    public static var isDev: Bool { name != "owl" }

    public static let root = ProcessInfo.processInfo.environment["OWL_ROOT"].map { URL(fileURLWithPath: $0) }
        ?? support(name)
    public static let sessionsDir = root.appending(path: "sessions")
    private static let file = root.appending(path: "config.json")
    private static let keyFile = root.appending(path: "openrouter.key")

    private static func support(_ name: String) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: name)
    }

    public static func load() -> Config {
        guard let data = try? Data(contentsOf: file) else { return Config() }
        do {
            return try JSONDecoder().decode(Config.self, from: data)
        } catch {
            Log.line("config.json unreadable, using defaults: \(error.localizedDescription)")
            return Config()
        }
    }

    public func save() {
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
    public static var openRouterKey: String? {
        if let k = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"], !k.isEmpty { return k }
        for file in isDev ? [keyFile, support("owl").appending(path: "openrouter.key")] : [keyFile] {
            guard let s = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
        }
        return nil
    }

    /// Keep a new key, readable by this user only.
    public static func saveKey(_ key: String) throws {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { throw Failure("that key is empty") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data((k + "\n").utf8).write(to: keyFile, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFile.path)
    }

    // Missing keys take their defaults, so a config from an older owl loads.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        textModel = try c.decodeIfPresent(String.self, forKey: .textModel) ?? d.textModel
        timeSource = try c.decodeIfPresent(String.self, forKey: .timeSource) ?? d.timeSource
        inputUID = try c.decodeIfPresent(String.self, forKey: .inputUID)
        inputName = try c.decodeIfPresent(String.self, forKey: .inputName)
        keys = try c.decodeIfPresent(Bool.self, forKey: .keys) ?? d.keys
    }
}
