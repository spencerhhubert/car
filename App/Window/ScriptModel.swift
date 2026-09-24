import CarKit
import Foundation
import Observation

// The session in the main pane, read as a script (CarKit's Script.swift).
// A session still recording or transcribing is read again every second while
// it is on screen, and only what changed is asked of the catalog; a finished
// one is read once.
@MainActor @Observable
final class ScriptModel {
    private(set) var script: Script?
    /// Counts the scripts read, so a view can tell a new one arrived.
    private(set) var revision = 0
    /// The session picked is not in the catalog (it was just discarded).
    private(set) var missing = false
    /// The picture shown big, by its id.
    var viewing: Int?
    /// Rows showing all their actions, not the first few.
    private(set) var expanded: Set<String> = []

    func expand(_ row: String) { expanded.insert(row) }

    /// Read session `id`, and keep reading it while it is live, for as long
    /// as the calling task runs: the pane's, which ends when another page is
    /// picked or the window closes.
    func follow(_ id: String) async {
        if script?.id != id {
            script = nil
            viewing = nil
            expanded = []
            revision += 1
        }
        missing = false
        let reader = ScriptReader(id: id)
        while !Task.isCancelled {
            if let s = await reader.read() {
                script = s
                revision += 1
            } else if script == nil {
                missing = true
                return
            }
            guard script?.status.isLive == true else { return }
            try? await Task.sleep(for: .seconds(1))
        }
    }
}
