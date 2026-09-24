// swift-tools-version: 6.0
//
// CarKit: everything car does that is not the Mac's screen, keys or
// microphone. The catalog and sessions, the transcription pipeline, the
// timeline, marks. It builds and tests on its own:
//
//     swift test --package-path CarKit
//
// The app (../App) records into it; the `car` command reads out of it.
import PackageDescription

let package = Package(
    name: "CarKit",
    platforms: [.macOS("26.0")],
    products: [.library(name: "CarKit", targets: ["CarKit"])],
    targets: [
        .target(name: "CarKit"),
        .testTarget(name: "CarKitTests", dependencies: ["CarKit"]),
    ],
    swiftLanguageModes: [.v5]
)
