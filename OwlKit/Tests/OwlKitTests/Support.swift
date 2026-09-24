import Foundation
@testable import OwlKit

/// Every test that touches the catalog calls this first: it points owl at a
/// folder of its own before anything reads where owl keeps things, so no test
/// ever writes into a real copy's catalog or sessions.
let testRoot: URL = {
    let root = FileManager.default.temporaryDirectory.appending(path: "owl-tests-\(UUID().uuidString)")
    setenv("OWL_ROOT", root.path, 1)
    precondition(Config.root.path == root.path, "Config.root was read before the tests set OWL_ROOT")
    return root
}()
