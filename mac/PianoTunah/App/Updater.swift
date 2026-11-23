import Foundation
import Observation
import Sparkle
import SwiftUI

/// Automatic updates from GitHub Releases with Sparkle (docs/adr/0004).
///
/// Sparkle checks the feed once a day and at launch and installs a new
/// version when the app quits; the settings are in Info.plist (project.yml).
/// Only release builds carry the EdDSA public key that Sparkle verifies
/// updates with. Without it, as in every local and CI build, the updater is
/// never started and the menu item is not shown, so a development build
/// never replaces itself with a release.
@MainActor @Observable
final class Updater {
    @ObservationIgnored private let controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observation: NSKeyValueObservation?

    /// False while a check is running, and always false when inert.
    private(set) var canCheckForUpdates = false

    /// Whether this build updates itself at all.
    var isEnabled: Bool { controller != nil }

    init(bundle: Bundle = .main) {
        let key = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            controller = nil
            return
        }
        let controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) {
            @Sendable [weak self] _, change in
            let canCheck = change.newValue ?? false
            Task { @MainActor in self?.canCheckForUpdates = canCheck }
        }
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}

/// *Check for Updates…* in the app menu, under *About Piano Tunah*. Not shown
/// in builds that do not update themselves.
struct UpdateCommands: Commands {
    let updater: Updater

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            if updater.isEnabled {
                Button {
                    updater.checkForUpdates()
                } label: {
                    Text("Check for Updates…", tableName: "Updates",
                         comment: "App menu item: look for a new version now.")
                }
                .disabled(!updater.canCheckForUpdates)
            }
        }
    }
}
