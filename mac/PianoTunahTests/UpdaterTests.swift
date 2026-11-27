import Foundation
import Testing
@testable import PianoTunah

// Which feed Sparkle reads: SUFeedURL (nil) unless "Get beta versions" is
// on and the build knows the beta feed.

@MainActor @Suite struct BetaFeed {
    private let beta = "https://raw.githubusercontent.com/riborg/pianotunah/appcast/beta.xml"

    /// A UserDefaults of the test's own, so the app's setting is untouched.
    private func defaults() throws -> UserDefaults {
        let name = "PianoTunahTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func theBetaFeedOnlyWhileBetasAreOn() throws {
        let defaults = try defaults()
        let feed = FeedChooser(betaFeed: beta, defaults: defaults)
        #expect(feed.feedURLString == nil)
        defaults.set(true, forKey: Updater.betaKey)
        #expect(feed.feedURLString == beta)
        defaults.set(false, forKey: Updater.betaKey)
        #expect(feed.feedURLString == nil)
    }

    @Test func noBetaFeedInTheBuildMeansTheReleases() throws {
        let defaults = try defaults()
        defaults.set(true, forKey: Updater.betaKey)
        #expect(FeedChooser(betaFeed: nil, defaults: defaults).feedURLString == nil)
        #expect(FeedChooser(betaFeed: "  ", defaults: defaults).betaFeed == nil)
    }

    /// Local and CI builds carry no public key: no updater, no beta setting.
    @Test func aBuildWithoutTheKeyOffersNoBetas() {
        let updater = Updater()
        #expect(!updater.isEnabled)
        #expect(!updater.offersBetas)
    }
}
