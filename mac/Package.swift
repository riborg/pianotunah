// swift-tools-version: 6.0
// PianoTunahCore: the app's logic in pure Swift (standard library and
// Foundation only), so it builds and tests on Linux too. See
// docs/macos-port.md and docs/adr/0003-mac-core-is-pure-swift.md.
import PackageDescription

let package = Package(
    name: "PianoTunahCore",
    // The core uses no recent APIs, so it asks only for macOS 15. That lets
    // CI run its tests on GitHub's macOS runners (Apple's libm, arm64),
    // which may not have macOS 27 yet. The app itself targets macOS 27.
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "PianoTunahCore", targets: ["PianoTunahCore"]),
    ],
    targets: [
        .target(name: "PianoTunahCore"),
        .testTarget(
            name: "PianoTunahCoreTests",
            dependencies: ["PianoTunahCore"],
            // Written by test/fixtures.mjs from the web JS; not edited by hand.
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
