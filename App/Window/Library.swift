import CarKit
import Foundation
import Observation

// What car's window shows: the list of sessions down its side, and which
// page is in front, a session or Settings. While the list is on screen it is
// read again every two seconds (the command, or another copy of the app, can
// change a session too) and at once when this app starts, stops or finishes
// one. The catalog is read off the main thread; the list changes only when
// what it holds did.
@MainActor @Observable
final class Library {
    enum Page: Hashable, Sendable {
        case session(String)
        case settings
    }

    private(set) var sessions: [SessionSummary] = []
    private(set) var loaded = false
    /// The page in front; nil until the list is first read.
    var page: Page?

    /// The session in front, when a session is.
    var selectedID: String? {
        get { if case .session(let id) = page { id } else { nil } }
        set { page = newValue.map(Page.session) ?? page }
    }

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
        // Until something is picked, or when the session in front is gone:
        // the one being recorded, else the newest.
        let gone = selectedID.map { id in !list.contains { $0.id == id } } ?? false
        if page == nil || gone {
            page = (list.first { $0.record.state == .recording } ?? list.first).map { .session($0.id) }
        }
    }
}
