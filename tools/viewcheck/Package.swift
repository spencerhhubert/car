// swift-tools-version: 6.0
//
// viewcheck: renders car's windows to pictures, from the app's own sources
// and a copy of the catalog, so a view is checked without a person's screen.
// run.sh copies the sources in and runs it; see docs/design-system/engineering.md.
import PackageDescription

let package = Package(
    name: "viewcheck",
    platforms: [.macOS("26.0")],
    dependencies: [.package(path: "../../CarKit")],
    targets: [.executableTarget(name: "viewcheck", dependencies: [.product(name: "CarKit", package: "CarKit")],
                                swiftSettings: [.swiftLanguageMode(.v5)])]
)
