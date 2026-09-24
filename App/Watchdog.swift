import Foundation
import CarKit

// Watches the main thread. Every second it asks the main thread to answer;
// if it has not answered after `stall` seconds, car is hanging (a beachball),
// and a sample of every thread goes into the logs folder, once per hang,
// with a line in the log saying where. A hang then leaves behind what it was
// doing, instead of only a person's word that it happened.
final class Watchdog: @unchecked Sendable {
    static let stall = 3.0

    private let queue = DispatchQueue(label: "car.watchdog", qos: .utility)
    private var timer: DispatchSourceTimer?
    // On `queue`. Uptime, which stops while the Mac sleeps, so waking from
    // sleep is not a hang.
    private var asked: TimeInterval?
    private var sampled = false

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(250))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func tick() {
        if let asked {
            let waited = ProcessInfo.processInfo.systemUptime - asked
            if waited > Self.stall, !sampled {
                sampled = true
                sample(waited)
            }
            return
        }
        asked = ProcessInfo.processInfo.systemUptime
        DispatchQueue.main.async { [weak self] in
            self?.queue.async {
                self?.asked = nil
                self?.sampled = false
            }
        }
    }

    private func sample(_ waited: Double) {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let file = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appending(path: "Logs/\(Config.name)-hang-\(f.string(from: Date())).txt")
        Log.line("the main thread has not answered for \(Int(waited)) s; sampling it to \(file.path)")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        p.arguments = [String(ProcessInfo.processInfo.processIdentifier), "3", "-file", file.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }
}
