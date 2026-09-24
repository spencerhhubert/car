import Foundation

// The `owl` command: the same binary as the app, run from a terminal (the
// development copy's is `owl-dev`, and sees only its own sessions).
//
//   owl sessions                          every session, newest last, with its state
//   owl session <id|last>                 the timeline; waits for a transcription in progress
//   owl pointer <id|last>                 the line a stopped session puts on the clipboard
//   owl guide                             how owl works, for a person or an agent
//   owl status                            what is being recorded or transcribed now; exit 3 if anything
//   owl transcribe <id|last> [--text-model M] [--time-source apple|openrouter:M]
//   owl bench <id|last> [--model M]       a model's times against the on-device ones
//   owl models                            OpenRouter models that take audio
//   owl config [key value]                show or set a setting
//   owl render <id|last>                  rewrite session.md from what is on disk
enum CLI {
    static let commands: Set<String> = ["sessions", "session", "pointer", "guide", "status", "transcribe", "bench",
                                        "models", "config", "render", "help", "--help", "-h"]

    static func run(_ args: [String]) async -> Int32 {
        guard let cmd = args.first else { return usage() }
        let rest = Array(args.dropFirst())
        do {
            switch cmd {
            case "sessions":
                for id in Session.list() {
                    let m = Session.meta(id)
                    let secs = m?.seconds ?? 0
                    print("\(id)  \(Render.clock(Int(secs * 1000)))  \(m?.events ?? 0) events  \(m?.status.rawValue ?? "?")")
                }
            case "session":
                let id = try resolve(rest.first)
                await settle(id)
                print(Render.text(id: id))
            case "pointer":
                print(Pointer.text(id: try resolve(rest.first)))
            case "guide":
                guard let url = Config.bundle.url(forResource: "README", withExtension: "md"),
                      let text = try? String(contentsOf: url, encoding: .utf8)
                else { throw Failure("this copy of \(Config.name) was built without its README") }
                print(text)
            case "status":
                let live = Session.list().filter { id in
                    guard let m = Session.meta(id), m.status == .recording || m.status == .transcribing else { return false }
                    return SessionLock.isHeld(Session.dir(id))
                }
                if live.isEmpty {
                    print("idle")
                    return 0
                }
                for id in live { print("\(id)  \(Session.meta(id)?.status.rawValue ?? "?")") }
                return 3
            case "render":
                let id = try resolve(rest.first)
                try Render.write(id: id)
                print("wrote \(Session.dir(id).appending(path: "session.md").path)")
            case "transcribe":
                let id = try resolve(rest.first)
                guard let lock = SessionLock(Session.dir(id)) else {
                    throw Failure("\(Config.name) is recording or transcribing \(id) right now")
                }
                defer { lock.release() }
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
                guard let key = Config.openRouterKey else {
                    throw Failure("no OpenRouter key: put it in \(Config.root.path)/openrouter.key or OPENROUTER_API_KEY")
                }
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
                    default: throw Failure("unknown setting \(rest[0])")
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
            FileHandle.standardError.write(Data("\(Config.name): \(error.localizedDescription)\n".utf8))
            return 1
        }
        return 0
    }

    /// Before reading a session: one being transcribed is waited for, and one
    /// that no one is at any more (owl quit or crashed part way) is finished
    /// here. One still recording is read as it stands.
    private static func settle(_ id: String) async {
        let dir = Session.dir(id)
        let giveUp = Date().addingTimeInterval(20 * 60)
        var told = false
        while let m = Session.meta(id), m.status == .recording || m.status == .transcribing {
            if let lock = SessionLock(dir) {
                say("\(id) was left \(m.status.rawValue) with no one at it; transcribing it now")
                do { _ = try await Transcribe.run(id: id) } catch { say("\(error.localizedDescription)") }
                lock.release()
                return
            }
            if m.status == .recording { return }
            if !told {
                say("waiting for \(id) to finish transcribing…")
                told = true
            }
            if Date() > giveUp {
                say("still transcribing after 20 minutes; showing what there is")
                return
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    private static func say(_ s: String) {
        FileHandle.standardError.write(Data("\(Config.name): \(s)\n".utf8))
    }

    private static func resolve(_ arg: String?) throws -> String {
        guard let arg else { throw Failure("which session? an id, or last") }
        if arg == "last" {
            guard let id = Session.list().last else { throw Failure("no sessions yet") }
            return id
        }
        guard FileManager.default.fileExists(atPath: Session.dir(arg).path) else { throw Failure("no session \(arg)") }
        return arg
    }

    private static func flag(_ args: [String], _ name: String) -> String? {
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    private static func usage() -> Int32 {
        let owl = Config.name
        print("""
        \(owl) — records your voice and what you do on the computer, as one timeline

          \(owl) sessions
          \(owl) session <id|last>        the timeline (waits for a transcription in progress)
          \(owl) pointer <id|last>        the line for an agent
          \(owl) guide                    how owl works
          \(owl) status                   what is being recorded or transcribed now
          \(owl) transcribe <id|last> [--text-model M] [--time-source apple|openrouter:M]
          \(owl) bench <id|last> [--model M]
          \(owl) models
          \(owl) config [textModel|timeSource|doubleClick|enabled VALUE]
          \(owl) render <id|last>

        Hold ⌥ (or double-click in a text field) to start a session; `\(owl) guide` for the rest.
        """)
        return 0
    }
}
