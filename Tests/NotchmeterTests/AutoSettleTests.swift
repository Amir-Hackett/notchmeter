import AppKit
import Foundation
import Testing
@testable import Notchmeter

/// What happens in the moment after an app comes forward. `didActivateApplicationNotification` arrives before the
/// incoming app has drawn its menu titles, so the first reading can be the outgoing app's geometry or nothing at
/// all — and caching that under the incoming app's name is what left the strip narrowed for an app whose menus are
/// short, with nothing to put it right until some other app happened to activate.
@MainActor @Suite struct AutoSettles {
    static let notch = CGRect(x: 658, y: 950, width: 195, height: 32)

    static func width(_ style: CompactStyle, _ tools: Int) -> CGFloat {
        tools > 0 ? CGFloat(tools) * (style.showsNumbers ? 60 : 30) + 12 : 0
    }

    func watcher(readings: [CGFloat?]) -> (AutoSideWatcher, Preferences, () -> Int) {
        let suite = "NotchmeterTests.AutoSettles.\(readings.count).\(readings.compactMap { $0 }.map(String.init).joined(separator: "-"))"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let prefs = Preferences(defaults: defaults)
        prefs.compactSide = .auto
        nonisolated(unsafe) var taken = 0
        let watcher = AutoSideWatcher(prefs: prefs,
                                      metrics: { CompactMetrics(notch: Self.notch, tools: 3, width: Self.width) },
                                      measure: { _ in
                                          defer { taken += 1 }
                                          return taken < readings.count ? readings[taken] : readings.last ?? nil
                                      },
                                      frontmost: { .current },
                                      settleDelays: [.milliseconds(1), .milliseconds(1), .milliseconds(1)])
        return (watcher, prefs, { taken })
    }

    /// The reading taken while the bar was still catching up is used for this fit and then dropped; the one that
    /// stops changing is the one kept, and the strip is re-fitted against it without anything else having to
    /// happen. This is the whole of "it does not go back until I click something else".
    @Test func aFirstReadingIsUsedOnceAndThenReplacedByTheOneThatSettles() async throws {
        // 900 is the outgoing app's menus running past the notch; 300 is the incoming app's, which are short.
        let (watcher, prefs, taken) = watcher(readings: [900, 300, 300])
        watcher.refresh()
        let narrowed = try #require(prefs.autoCompactFit)
        #expect(narrowed.side != .split, "a menu bar reaching to 900 leaves no room left of the notch")

        watcher.settle()
        await watcher.settlePass?.value
        let settled = try #require(prefs.autoCompactFit)
        #expect(settled.side == .split, "once the bar has settled at 300 the strip has room on both sides again")
        #expect(settled.dropped == 0)
        #expect(taken() >= 3, "the pass keeps looking until two readings agree")
    }

    /// A settled reading is cached, so returning to that app costs no Accessibility call at all.
    @Test func aSettledReadingIsRememberedAndAFreshOneIsNot() async throws {
        let (watcher, _, taken) = watcher(readings: [500, 500])
        watcher.settle()
        await watcher.settlePass?.value
        let afterSettling = taken()
        watcher.refresh()
        #expect(taken() == afterSettling, "the cached reading answers, so nothing is measured again")
    }

    /// An app that never answers leaves no entry behind: a blank must not be remembered as though it were a
    /// measurement, or the app would be treated as having no menus for the rest of the session.
    @Test func anAppThatNeverAnswersIsNotCachedAsAnAnswer() async throws {
        let (watcher, _, taken) = watcher(readings: [nil, nil, nil])
        watcher.settle()
        await watcher.settlePass?.value
        let afterSettling = taken()
        watcher.refresh()
        #expect(taken() > afterSettling, "with nothing cached the next fit has to look again")
    }
}
