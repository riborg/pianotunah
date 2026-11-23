import Foundation

/// TEMPORARY: switches for finding what keeps the main window's toolbar
/// laying itself out (the flickering », a sluggish app from launch). Each
/// takes one part out of the window in a Debug build, set from Terminal
/// before ⌘R:
///
///     defaults write io.github.riborg.pianotunah probe.plainTitle -bool YES
///     defaults delete io.github.riborg.pianotunah probe.plainTitle
///
/// Keys: plainTitle, noInspectorButton, noInspector, noNewPiano,
/// noOverlay, noTuner. Remove this file once the cause is found.
enum ToolbarProbe {
    static func on(_ key: String) -> Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "probe." + key)
        #else
        false
        #endif
    }
}
