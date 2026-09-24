import Foundation
@testable import CarKit

/// Every test that touches the catalog calls this first: it points car at a
/// folder of its own before anything reads where car keeps things, so no test
/// ever writes into a real copy's catalog or sessions.
let testRoot: URL = {
    let root = FileManager.default.temporaryDirectory.appending(path: "car-tests-\(UUID().uuidString)")
    setenv("CAR_ROOT", root.path, 1)
    precondition(Config.root.path == root.path, "Config.root was read before the tests set CAR_ROOT")
    return root
}()
