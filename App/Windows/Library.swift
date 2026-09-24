import Foundation
import Observation
import CarKit

// The list of sessions the sessions window shows, and which one is picked.
// While the list is on screen it is read again every two seconds (the
// command, or another copy of the app, can change a session too) and at
// once when this app starts, stops or finishes one. The catalog is read off
// the main thread; the list changes only when what it holds did.
@MainActor @Observable
final class Library {
    private(set) var sessions: [SessionSummary] = []
    private(set) var loaded = false
    var selectedID: String?

    var selected: SessionSummary? { sessions.first { $0.id == selectedID } }

    /// The sessions by day, newest first.
    var days: [(day: String, sessions: [SessionSummary])] {
        var out: [(day: String, sessions: [SessionSummary])] = []
        for s in sessions {
            let day = s.record.started.map { Format.day($0) } ?? "Earlier"
            if out.last?.day == day { out[out.count - 1].sessions.append(s) } else { out.append((day, [s])) }
        }
        return out
    }

    /// Keep the list current for as long as the calling task runs: the
    /// sidebar's, so it stops when the window closes.
    func follow() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                while !Task.isCancelled {
                    await self.refresh()
                    try? await Task.sleep(for: .seconds(2))
                }
            }
            group.addTask { @MainActor in
                for await _ in NotificationCenter.default.notifications(named: Recorder.changed) {
                    await self.refresh()
                }
            }
        }
    }

    private func refresh() async {
        let list = await Task.detached(priority: .userInitiated) { Session.summaries() }.value
        if list != sessions { sessions = list }
        loaded = true
        // The session being recorded, else the newest, until one is picked.
        if selectedID == nil || !list.contains(where: { $0.id == selectedID }) {
            selectedID = list.first { $0.record.state == .recording }?.id ?? list.first?.id
        }
    }
}
