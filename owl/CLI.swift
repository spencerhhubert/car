import Foundation

// The `owl` command: the same binary as the app, run from a terminal.
//
//   owl sessions                          every session, newest last
//   owl session <id|last>                 the timeline (session.md)
//   owl transcribe <id|last> [--text-model M] [--time-source apple|openrouter:M]
//   owl bench <id|last> [--model M]       a model's times against the on-device ones
//   owl models                            OpenRouter models that take audio
//   owl config [key value]                show or set a setting
//   owl render <id|last>                  rewrite session.md from what is on disk
enum CLI {
    static let commands: Set<String> = ["sessions", "session", "transcribe", "bench", "models",
                                        "config", "render", "help", "--help", "-h"]

    static func run(_ args: [String]) async -> Int32 {
        guard let cmd = args.first else { return usage() }
        let rest = Array(args.dropFirst())
        do {
            switch cmd {
            case "sessions":
                for id in Session.list() {
                    let m = Session.meta(id)
                    let secs = (m["seconds"] as? Double) ?? 0
                    let words = m["textModel"] == nil ? "" : "  transcribed"
                    print("\(id)  \(Render.clock(Int(secs * 1000)))  \(m["events"] ?? 0) events\(words)")
                }
            case "session":
                let id = try resolve(rest.first)
                let md = Session.dir(id).appending(path: "session.md")
                if !FileManager.default.fileExists(atPath: md.path) { try Render.write(id: id) }
                print(try String(contentsOf: md, encoding: .utf8))
            case "render":
                let id = try resolve(rest.first)
                try Render.write(id: id)
                print("wrote \(Session.dir(id).appending(path: "session.md").path)")
            case "transcribe":
                let id = try resolve(rest.first)
                var o = Transcribe.Options()
                if let m = flag(rest, "--text-model") { o.textModel = m }
                if let s = flag(rest, "--time-source") { o.timeSource = s }
                let s = try await Transcribe.run(id: id, options: o)
                print("\(id): \(s.words) words, \(s.matched) matched, \(s.onsets) onsets, words by \(s.textModel), times by \(s.timeSource), $\(String(format: "%.4f", s.cost))")
                if !s.note.isEmpty { print(s.note) }
            case "bench":
                let id = try resolve(rest.first)
                let model = flag(rest, "--model") ?? Config.load().textModel
                print(try await Transcribe.bench(id: id, model: model))
            case "models":
                guard let key = Config.openRouterKey else { throw OpenRouter.Failure(message: "no OpenRouter key: put it in \(Config.root.path)/openrouter.key or OPENROUTER_API_KEY") }
                let models = try await OpenRouter.audioModels(key: key)
                try JSONEncoder().encode(models).write(to: Config.root.appending(path: "models.json"))
                for m in models { print(m.id) }
            case "config":
                var c = Config.load()
                if rest.count >= 2 {
                    switch rest[0] {
                    case "textModel": c.textModel = rest[1]
                    case "timeSource": c.timeSource = rest[1]
                    case "doubleClick": c.doubleClick = rest[1] == "true"
                    case "enabled": c.enabled = rest[1] == "true"
                    default: throw OpenRouter.Failure(message: "unknown setting \(rest[0])")
                    }
                    c.save()
                }
                print("textModel   \(c.textModel)")
                print("timeSource  \(c.timeSource)")
                print("input       \(c.inputName ?? "system default")")
                print("doubleClick \(c.doubleClick)")
                print("enabled     \(c.enabled)")
                print("key         \(Config.openRouterKey == nil ? "missing" : "present")")
                print("sessions    \(Config.sessionsDir.path)")
            default:
                return usage()
            }
        } catch {
            FileHandle.standardError.write("owl: \(error.localizedDescription)\n".data(using: .utf8)!)
            return 1
        }
        return 0
    }

    private static func resolve(_ arg: String?) throws -> String {
        guard let arg else { throw OpenRouter.Failure(message: "which session?") }
        if arg == "last" {
            guard let id = Session.list().last else { throw OpenRouter.Failure(message: "no sessions yet") }
            return id
        }
        guard FileManager.default.fileExists(atPath: Session.dir(arg).path) else {
            throw OpenRouter.Failure(message: "no session \(arg)")
        }
        return arg
    }

    private static func flag(_ args: [String], _ name: String) -> String? {
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    private static func usage() -> Int32 {
        print("""
        owl — records your voice and what you do on the computer, as one timeline

          owl sessions
          owl session <id|last>
          owl transcribe <id|last> [--text-model M] [--time-source apple|openrouter:M]
          owl bench <id|last> [--model M]
          owl models
          owl config [textModel|timeSource|doubleClick|enabled VALUE]
          owl render <id|last>

        Hold ⌥ (or double-click in a text field) to start a session; see README.md.
        """)
        return 0
    }
}
