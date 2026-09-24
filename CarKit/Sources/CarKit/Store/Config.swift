import Foundation

// Everything car keeps lives under ~/Library/Application Support/<name>:
//
//   config.json        the choices below
//   openrouter.key     the API key, one line, mode 600 (or OPENROUTER_API_KEY
//                      in the environment, which wins)
//   car.sqlite         the catalog: every session and where its files are
//   models.json        the last fetched list of audio-capable models
//   sessions/<id>/     each session's files (Session.swift)
//
// <name> is car, or car-dev for the development copy (`./build.sh` builds it,
// `./build.sh release` the real one). The two run side by side as separate
// apps: their own bundle, command, settings, catalog, sessions, log and
// permissions, so working on car never touches the car in use. The dev copy
// leaves its keys off until they are turned on in its settings, since both
// copies see every tap of ⌥ and one gesture would reach both, and reads the
// key from the real copy's folder when it has none. CAR_ROOT in the environment puts everything in another folder
// (the tests use it).
public struct Config: Codable, Sendable {
    /// The remote model, which writes the words: any OpenRouter chat model
    /// that takes audio, or "" for none (the local model's words). Gemini
    /// flash measured best; see docs/guide.md.
    public var remoteModel = "google/gemini-3-flash-preview"
    /// The local model, which keeps time (and writes the words when there is
    /// no remote one): "apple", the on-device recognizer, or "none" (words are
    /// spread over the voice and snapped to its onsets).
    public var localModel = "apple"
    /// Microphone, by the device UID CoreAudio reports, or nil for the system
    /// default at the moment a session starts.
    public var inputUID: String?
    public var inputName: String?
    /// Quick dictation (⇧ ⌥ ⌥) copies what was said since the last pause
    /// of at least this many seconds.
    public var dictationPause = 15.0
    /// Whether car answers its keys: ⌥ tapped twice alone, with ⇧ held, or
    /// with ⌘ held.
    public var keys = !Config.isDev

    public init() {}

    /// The app this binary is in. Run as a command, it is reached through a
    /// symlink, which Bundle.main does not follow.
    public static let bundle: Bundle = {
        guard let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return .main }
        let app = exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return app.pathExtension == "app" ? Bundle(url: app) ?? .main : .main
    }()
    /// "car" or "car-dev": the executable's name, which is also the command's.
    public static let name = bundle.executableURL?.lastPathComponent ?? "car"
    public static var isDev: Bool { name != "car" }
    /// The commit this copy was built from.
    public static var version: String { bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?" }

    public static let root = ProcessInfo.processInfo.environment["CAR_ROOT"].map { URL(fileURLWithPath: $0) }
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
        for file in isDev ? [keyFile, support("car").appending(path: "openrouter.key")] : [keyFile] {
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

    // Missing keys take their defaults, so a config from an older car loads.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        remoteModel = try c.decodeIfPresent(String.self, forKey: .remoteModel) ?? d.remoteModel
        localModel = try c.decodeIfPresent(String.self, forKey: .localModel) ?? d.localModel
        inputUID = try c.decodeIfPresent(String.self, forKey: .inputUID)
        inputName = try c.decodeIfPresent(String.self, forKey: .inputName)
        dictationPause = try c.decodeIfPresent(Double.self, forKey: .dictationPause) ?? d.dictationPause
        keys = try c.decodeIfPresent(Bool.self, forKey: .keys) ?? d.keys
    }
}
