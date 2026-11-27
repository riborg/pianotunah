// swift-tools-version: 6.0
// PianoTunahCore: the app's logic in pure Swift (standard library and
// Foundation only), so it builds and tests on Linux too. See
// docs/macos-port.md and docs/adr/0003-mac-core-is-pure-swift.md.
//
// PianoTunahAudio: the microphone, the reference tone and the recording.
// Its logic (ring buffer, frame clock, tone synthesis, WAV) is pure Swift and
// tested on Linux too; the AVFoundation and Core Audio glue is compiled only
// where AVFoundation exists (step 3 of docs/macos-port.md).
import PackageDescription

let package = Package(
    name: "PianoTunahCore",
    // The core uses no recent APIs, so it asks only for macOS 15. That lets
    // CI run its tests on GitHub's macOS runners (Apple's libm, arm64),
    // which may not have macOS 27 yet. The app's own target is
    // options.deploymentTarget in project.yml.
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "PianoTunahCore", targets: ["PianoTunahCore"]),
        .library(name: "PianoTunahAudio", targets: ["PianoTunahAudio"]),
    ],
    targets: [
        .target(name: "PianoTunahCore"),
        .testTarget(
            name: "PianoTunahCoreTests",
            dependencies: ["PianoTunahCore"],
            // Written by web/test/fixtures.mjs from the web JS; not edited by hand.
            resources: [.copy("Fixtures")]
        ),
        .target(name: "PianoTunahAudio", dependencies: ["PianoTunahCore"]),
        .testTarget(name: "PianoTunahAudioTests", dependencies: ["PianoTunahAudio"]),
    ],
    swiftLanguageModes: [.v6]
)
