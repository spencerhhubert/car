import Foundation

// Everything owl keeps lives under ~/Library/Application Support/owl:
//
//   config.json        the choices below
//   openrouter.key     the API key, one line, mode 600 (or OPENROUTER_API_KEY
//                      in the environment, which wins)
//   models.json        the last fetched list of audio-capable models
//   sessions/<id>/     one folder per session (see Session.swift)
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
    var doubleClick = true
    /// Whether the gesture is armed at all.
    var enabled = true

    static let root = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "owl")
    static let sessionsDir = root.appending(path: "sessions")
    private static let file = root.appending(path: "config.json")

    static func load() -> Config {
        guard let data = try? Data(contentsOf: file),
              let c = try? JSONDecoder().decode(Config.self, from: data) else { return Config() }
        return c
    }

    func save() {
        try? FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(self).write(to: Self.file)
    }

    /// The OpenRouter key, never logged, never printed.
    static var openRouterKey: String? {
        if let k = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"], !k.isEmpty { return k }
        guard let s = try? String(contentsOf: root.appending(path: "openrouter.key"), encoding: .utf8)
        else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
