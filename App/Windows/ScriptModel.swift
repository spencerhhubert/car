import Foundation
import Observation
import CarKit

// The session in the sessions window's main pane, read as a script
// (CarKit's Script.swift). A session still recording or transcribing is read
// again every second while it is on screen, and only what changed is asked
// of the catalog; a finished one is read once.
@MainActor @Observable
final class ScriptModel {
    private(set) var script: Script?
    /// The session picked is not in the catalog (it was just discarded).
    private(set) var missing = false
    /// The picture shown big, by its id.
    var viewing: Int?

    /// Read session `id`, and keep reading it while it is live, for as long
    /// as the calling task runs: the pane's, which ends when another session
    /// is picked or the window closes.
    func follow(_ id: String) async {
        if script?.id != id {
            script = nil
            viewing = nil
        }
        missing = false
        let reader = ScriptReader(id: id)
        while !Task.isCancelled {
            if let s = await reader.read() {
                script = s
            } else if script == nil {
                missing = true
                return
            }
            guard script?.status.isLive == true else { return }
            try? await Task.sleep(for: .seconds(1))
        }
    }
}
