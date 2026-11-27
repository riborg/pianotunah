import Foundation
import Observation
import Sparkle
import SwiftUI

/// Automatic updates from GitHub Releases with Sparkle (docs/adr/0004).
///
/// Sparkle checks the feed once a day and at launch and installs a new
/// version when the app quits; the settings are in Info.plist (project.yml).
/// With "Get beta versions" on, it reads the beta feed instead
/// (`PTBetaFeedURL`), which also has the releases, so a beta tester gets
/// the next release too. Sparkle never goes back to an older build: turned
/// off, the beta stays until a release is newer.
/// Only release builds carry the EdDSA public key that Sparkle verifies
/// updates with. Without it, as in every local and CI build, the updater is
/// never started and the menu item is not shown, so a development build
/// never replaces itself with a release.
@MainActor @Observable
final class Updater {
    /// The UserDefaults key (@AppStorage) of "Get beta versions".
    nonisolated static let betaKey = "betaUpdates"

    @ObservationIgnored private let controller: SPUStandardUpdaterController?
    /// Held here: Sparkle keeps its delegate weakly.
    @ObservationIgnored private let feed: FeedChooser?
    @ObservationIgnored private var observation: NSKeyValueObservation?

    /// False while a check is running, and always false when inert.
    private(set) var canCheckForUpdates = false

    /// Whether this build updates itself at all.
    var isEnabled: Bool { controller != nil }

    init(bundle: Bundle = .main) {
        let key = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            controller = nil
            feed = nil
            return
        }
        let feed = FeedChooser(betaFeed: bundle.object(forInfoDictionaryKey: "PTBetaFeedURL") as? String)
        self.feed = feed
        let controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: feed, userDriverDelegate: nil)
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

    /// Whether this build can read the beta feed: it updates itself and
    /// knows the feed.
    var offersBetas: Bool { feed?.betaFeed != nil }

    /// "Get beta versions" was changed: turned on, look in the beta feed
    /// now, quietly, rather than at the next daily check.
    func betaChanged(_ on: Bool) {
        guard on, let controller, controller.updater.canCheckForUpdates else { return }
        controller.updater.checkForUpdatesInBackground()
    }
}

/// Which feed Sparkle reads: the beta feed while "Get beta versions" is on,
/// otherwise SUFeedURL (nil). Sparkle's delegate protocol may make the
/// class main-actor; every member is nonisolated, as they read only
/// constants and UserDefaults, which is thread-safe.
final class FeedChooser: NSObject, SPUUpdaterDelegate {
    nonisolated let betaFeed: String?
    nonisolated(unsafe) private let defaults: UserDefaults

    nonisolated init(betaFeed: String?, defaults: UserDefaults = .standard) {
        let trimmed = betaFeed?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.betaFeed = trimmed.isEmpty ? nil : trimmed
        self.defaults = defaults
    }

    /// The feed for the next check; nil for SUFeedURL.
    nonisolated var feedURLString: String? {
        defaults.bool(forKey: Updater.betaKey) ? betaFeed : nil
    }

    // Asked before every check.
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        feedURLString
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
