// swift-tools-version: 6.0
// PianoTunahCore: the app's logic in pure Swift (standard library and
// Foundation only), so it builds and tests on Linux too. See
// docs/macos-port.md and docs/adr/0003-mac-core-is-pure-swift.md.
import PackageDescription

let package = Package(
    name: "PianoTunahCore",
    // macOS 27 as a version string: with tools version 6.0 the newest named
    // version is .v15 (.v27 needs tools version 6.4).
    platforms: [.macOS("27.0")],
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
