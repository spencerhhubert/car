import Foundation
import OwlKit

// The `owl` command: the same binary as the app, run from a terminal (the
// development copy's is `owl-dev`, and sees only its own catalog). It is how
// an agent reads a session.
//
//   owl marker [<id|last> [<n|last>]] [--from M]
//                        what was said up to a marker, since the one before
//                        (or --from); waits until the words reach it
//   owl session <id|last> [--from M] [--to M]
//                        the timeline; waits for a stopped session's last words
//   owl events <id|last> [--from M] [--to M]    every event, JSON, one a line
//   owl words <id|last> [--from M] [--to M]     every word, JSON, one a line
//   owl sessions         every session, newest last
//   owl status           what is being recorded or transcribed now; exit 3 if anything
//   owl usage            what transcription has cost
//   owl pointer <id|last>  the line that hands a whole session to an agent
//   owl transcribe <id|last> [--again|--all] [--remote-model M|none] [--local-model apple|none]
//   owl bench <id|last> [--chunk N] [--model M]
//   owl models | config [key value] | render <id|last> | guide | version
//
// A moment M is start, end, m3 (marker 3), -20m / -90s (before the end), or a
// time on the session clock (12:30, 1:02:03).
enum CLI {
    static func run(_ args: [String]) async -> Int32 {
        guard let cmd = args.first else { return usage() }
        let rest = Array(args.dropFirst())
        var positional: [String] = []
        var value = false
        for a in rest {
            if value { value = false } else if valued.contains(a) { value = true } else if !a.hasPrefix("--") { positional.append(a) }
        }
        do {
            switch cmd {
            case "marker":
                let id = try resolve(positional.first ?? "last", withMarkers: true)
                let markers = Session.markers(id)
                guard !markers.isEmpty else { throw Failure("session \(id) has no markers") }
                let arg = positional.count > 1 ? positional[1] : "last"
                guard let m = arg == "last" ? markers.last : Int(arg).flatMap({ n in markers.first { $0.n == n } })
                else { throw Failure("session \(id) has no marker \(arg)") }
                await settle(id, upTo: m.t)
                let before = markers.last { $0.n < m.n }
                let from = try flag(rest, "--from").map { try moment($0, id, end: m.t) } ?? before?.t ?? 0
                let about = flag(rest, "--from") == nil ? (before.map { "what was said since marker \($0.n)" }
                    ?? "what was said from the start") : nil
                print(Render.text(id: id, from: from, to: m.t, about: about ?? "up to marker \(m.n)"))
            case "session":
                let id = try resolve(positional.first)
                await settle(id, upTo: nil)
                let (from, to) = try range(id, rest)
                print(Render.text(id: id, from: from, to: to))
            case "events":
                let id = try resolve(positional.first)
                let (from, to) = try range(id, rest)
                let shots = Session.files(id, kind: "shot")
                for var e in Session.events(id, from: from, to: to ?? .max) {
                    if let f = e["file"] as? Int { e["file"] = shots[f]?.path }
                    line(e)
                }
            case "words":
                let id = try resolve(positional.first)
                let (from, to) = try range(id, rest)
                for w in Session.words(id, from: from, to: to ?? .max) {
                    line(["text": w.text, "start": w.start, "end": w.end, "chunk": w.chunk, "how": w.how])
                }
            case "sessions":
                for s in Session.list() {
                    let chunks = Session.chunks(s.id)
                    let markers = Session.markers(s.id).count
                    print("\(s.id)  \(Render.clock(s.lengthMs ?? chunks.compactMap(\.endMs).max() ?? 0))  " +
                          "\(count(chunks.count, "chunk"))  \(count(markers, "marker"))  \(s.state.rawValue)")
                }
            case "status":
                let live = Session.list().filter { $0.isLive && SessionLock.isHeld(Session.dir($0.id)) }
                if live.isEmpty {
                    print("idle")
                    return 0
                }
                for s in live {
                    let chunks = Session.chunks(s.id)
                    let waiting = chunks.filter { !$0.state.settled }.count
                    print("\(s.id)  \(s.state.rawValue)  \(chunks.count) chunks, \(waiting) without words yet")
                }
                return 3
            case "usage":
                for span in Usage.spans {
                    let t = Usage.total(since: span.since)
                    print("\(span.name.padding(toLength: 9, withPad: " ", startingAt: 0)) \(Usage.dollars(t.cost))  " +
                          "\(Int(t.audioSeconds / 60)) min of sound sent, \(t.calls) calls")
                }
                for (model, t) in Usage.byModel(since: Usage.spans[2].since) {
                    print("  30 days, \(model): \(Usage.dollars(t.cost))")
                }
            case "pointer":
                print(Pointer.session(try resolve(positional.first)))
            case "render":
                let id = try resolve(positional.first)
                try Render.write(id: id)
                print("wrote \(Session.dir(id).appending(path: "session.md").path)")
            case "transcribe":
                let id = try resolve(positional.first)
                guard let lock = SessionLock(Session.dir(id)) else {
                    throw Failure("\(Config.name) is recording or transcribing \(id) right now")
                }
                defer { lock.release() }
                var o = Transcribe.Options()
                if let m = flag(rest, "--remote-model") { o.remoteModel = m == "none" ? "" : m }
                if let m = flag(rest, "--local-model") { o.localModel = m }
                let t = Transcriber(id: id, options: o)
                await t.addUnsettled(again: rest.contains("--again"), all: rest.contains("--all"))
                let out = await t.finish()
                print("\(id): \(out.state.rawValue), \(out.words) words" + (out.error.map { "; \($0)" } ?? ""))
            case "bench":
                let id = try resolve(positional.first)
                let n = flag(rest, "--chunk").flatMap(Int.init) ?? 1
                print(try await Transcribe.bench(id, chunk: n, model: flag(rest, "--model") ?? Config.load().remoteModel))
            case "models":
                guard let key = Config.openRouterKey else {
                    throw Failure("no OpenRouter key: set it from the menu, or OPENROUTER_API_KEY")
                }
                let models = try await OpenRouter.audioModels(key: key)
                try JSONEncoder().encode(models).write(to: Config.root.appending(path: "models.json"))
                for m in models { print(m.id) }
            case "config":
                var c = Config.load()
                if rest.count >= 2 {
                    switch rest[0] {
                    case "remoteModel": c.remoteModel = rest[1] == "none" ? "" : rest[1]
                    case "localModel": c.localModel = rest[1]
                    case "keys": c.keys = rest[1] == "true"
                    default: throw Failure("unknown setting \(rest[0])")
                    }
                    c.save()
                }
                print("remoteModel \(c.remoteModel.isEmpty ? "none" : c.remoteModel)")
                print("localModel  \(c.localModel)")
                print("input       \(c.inputName ?? "system default")")
                print("keys        \(c.keys)")
                print("key         \(Config.openRouterKey == nil ? "missing" : "present")")
                print("sessions    \(Config.sessionsDir.path)")
            case "version":
                print("\(Config.name) \(Config.bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
            case "guide":
                guard let url = Config.bundle.url(forResource: "guide", withExtension: "md"),
                      let text = try? String(contentsOf: url, encoding: .utf8)
                else { throw Failure("this copy of \(Config.name) was built without its guide") }
                print(text)
            case "help", "--help", "-h":
                return usage()
            default:
                _ = usage()
                return 2
            }
        } catch {
            say(error.localizedDescription)
            return 1
        }
        return 0
    }

    /// Flags followed by a value.
    private static let valued: Set<String> = ["--from", "--to", "--remote-model", "--local-model", "--chunk", "--model"]

    /// Before reading a session: wait while its lock holder transcribes it
    /// (up to `upTo`, or all of it once it stopped), and take over a session
    /// no one is at any more. A session still recording is read as it stands
    /// when there is no `upTo`.
    private static func settle(_ id: String, upTo t: Int?) async {
        let dir = Session.dir(id)
        let giveUp = Date().addingTimeInterval(20 * 60)
        var told = false
        while let s = Session.record(id), s.isLive {
            let pending = Session.chunks(id).filter { !$0.state.settled && (t == nil || $0.startMs < t!) }
            if t != nil, pending.isEmpty { return }
            if t == nil, s.state == .recording, SessionLock.isHeld(dir) { return }
            if let lock = SessionLock(dir) {
                say("\(id) was left \(s.state.rawValue) with no one at it; transcribing what is left")
                Session.setState(id, .transcribing)
                let tr = Transcriber(id: id)
                await tr.addUnsettled()
                _ = await tr.finish()
                lock.release()
                return
            }
            if !told {
                say(t == nil ? "waiting for the last of \(id) to be transcribed…"
                             : "waiting for the words up to the marker (\(pending.count) chunk\(pending.count == 1 ? "" : "s") to go)…")
                told = true
            }
            if Date() > giveUp {
                say("still transcribing after 20 minutes; showing what there is")
                return
            }
            try? await Task.sleep(for: .milliseconds(400))
        }
    }

    private static func range(_ id: String, _ args: [String]) throws -> (Int, Int?) {
        let end = Session.record(id)?.lengthMs ?? Session.chunks(id).compactMap(\.endMs).max() ?? 0
        let to = try flag(args, "--to").map { try moment($0, id, end: end) }
        let from = try flag(args, "--from").map { try moment($0, id, end: to ?? end) } ?? 0
        return (from, to)
    }

    private static func moment(_ s: String, _ id: String, end: Int) throws -> Int {
        guard let t = Moment.parse(s, in: id, end: end) else {
            throw Failure("\(s) is not a moment: start, end, m3, -20m, or a time like 12:30")
        }
        return t
    }

    private static func resolve(_ arg: String?, withMarkers: Bool = false) throws -> String {
        guard let arg else { throw Failure("which session? an id, or last") }
        if arg == "last" {
            let sessions = Session.list().filter { !withMarkers || !Session.markers($0.id).isEmpty }
            guard let s = sessions.last else { throw Failure(withMarkers ? "no session has a marker yet" : "no sessions yet") }
            return s.id
        }
        guard Session.record(arg) != nil else { throw Failure("no session \(arg)") }
        return arg
    }

    private static func flag(_ args: [String], _ name: String) -> String? {
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    private static func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }

    private static func line(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return }
        print(String(decoding: data, as: UTF8.self))
    }

    private static func say(_ s: String) {
        FileHandle.standardError.write(Data("\(Config.name): \(s)\n".utf8))
    }

    private static func usage() -> Int32 {
        let owl = Config.name
        print("""
        \(owl) — records your voice and what you do on the computer, as one timeline

          \(owl) marker [<id|last> [<n|last>]] [--from M]   what was said up to a marker
          \(owl) session <id|last> [--from M] [--to M]      the timeline
          \(owl) events <id|last> [--from M] [--to M]       every event, JSON lines
          \(owl) words <id|last> [--from M] [--to M]        every word, JSON lines
          \(owl) sessions | status | usage
          \(owl) pointer <id|last>
          \(owl) transcribe <id|last> [--again|--all] [--remote-model M|none] [--local-model apple|none]
          \(owl) bench <id|last> [--chunk N] [--model M]
          \(owl) models | config [remoteModel|localModel|keys VALUE] | render <id|last> | guide | version

        M: start, end, m3 (marker 3), -20m (before the end), 12:30 (session clock).
        ⌘⇧R starts and stops a session; ⌥ ⌥ sets a marker. `\(owl) guide` for the rest.
        """)
        return 0
    }
}
