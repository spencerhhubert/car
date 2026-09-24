// swift-tools-version: 6.0
//
// OwlKit: everything owl does that is not the Mac's screen, keys or
// microphone. The catalog and sessions, the transcription pipeline, the
// timeline, marks. It builds and tests on its own:
//
//     swift test --package-path OwlKit
//
// The app (../App) records into it; the `owl` command reads out of it.
import PackageDescription

let package = Package(
    name: "OwlKit",
    platforms: [.macOS("26.0")],
    products: [.library(name: "OwlKit", targets: ["OwlKit"])],
    targets: [
        .target(name: "OwlKit"),
        .testTarget(name: "OwlKitTests", dependencies: ["OwlKit"]),
    ],
    swiftLanguageModes: [.v5]
)
