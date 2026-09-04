import AppKit
import Foundation
import Testing
@testable import Notchmeter

/// What happens in the moment after an app comes forward. `didActivateApplicationNotification` arrives before the
/// incoming app has drawn its menu titles, so the first reading can be the outgoing app's geometry or nothing at
/// all — and caching that under the incoming app's name is what left the strip narrowed for an app whose menus are
/// short, with nothing to put it right until some other app happened to activate.
/// The app the watcher believes is in front. `NSRunningApplication.current` is not usable here: for the first
/// moments of a test process it answers `bundleIdentifier` nil and `processIdentifier` −1, so
/// `AutoSideWatcher.key(for:)` refuses to name it, `menuEndX(for:)` returns nil without ever calling the scripted
/// reading, and the watcher takes its "nothing measured" path. The suite then passed or failed on how long the
/// tests before it had happened to take — it failed almost every run under `--filter` and about one full run in
/// four. Naming the app outright makes the schedule the only thing these tests measure.
private final class StubFrontmostApp: NSRunningApplication {
    override var bundleIdentifier: String? { "NotchmeterTests.frontmost" }
    override var processIdentifier: pid_t { 4242 }
}

@MainActor @Suite struct AutoSettles {
    static let notch = CGRect(x: 658, y: 950, width: 195, height: 32)

    static func width(_ run: CompactFit.Run) -> CGFloat {
        guard !run.isEmpty else { return 0 }
        return CGFloat(run.readouts.count) * (run.style.showsNumbers ? 60 : 30) + (run.overflow > 0 ? 14 : 0) + 12
    }

    /// A right-hand reading, written the way the tests read best: how far left the items reach, and whether this
    /// app's own icon was among the ones counted. `nonisolated` so it can stand as a default argument, which is
    /// evaluated at the call site rather than on the main actor.
    nonisolated static func right(_ startX: CGFloat?, ownIcon: Bool = false) -> MenuBarExtent.StatusItemsReading {
        MenuBarExtent.StatusItemsReading(startX: startX, showsOwnIcon: ownIcon)
    }

    func watcher(readings: [CGFloat?], looks: Int = 3,
                 statusItems: [MenuBarExtent.StatusItemsReading] = [AutoSettles.right(nil)]) -> (AutoSideWatcher, Preferences, () -> Int) {
        let suite = "NotchmeterTests.AutoSettles.\(readings.count).\(readings.compactMap { $0 }.map(String.init).joined(separator: "-"))"
            + ".\(statusItems.map { "\($0.startX.map(String.init) ?? "-")\($0.showsOwnIcon ? "o" : "")" }.joined(separator: "-"))"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let prefs = Preferences(defaults: defaults)
        prefs.compactSide = .auto
        nonisolated(unsafe) var taken = 0
        nonisolated(unsafe) var takenRight = 0
        let watcher = AutoSideWatcher(prefs: prefs,
                                      metrics: { CompactMetrics(notch: Self.notch, tools: 3, width: Self.width) },
                                      measure: { _ in
                                          defer { taken += 1 }
                                          return taken < readings.count ? readings[taken] : readings.last ?? nil
                                      },
                                      measureStatusItems: {
                                          defer { takenRight += 1 }
                                          return takenRight < statusItems.count ? statusItems[takenRight] : statusItems[statusItems.count - 1]
                                      },
                                      frontmost: { StubFrontmostApp() },
                                      settleDelays: Array(repeating: .milliseconds(1), count: looks))
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

    /// Notchmeter's own menu bar icon is a drawn extra like any other, and it is created after the first fit is
    /// taken. Nothing macOS announces says it arrived — creating an `NSStatusItem` is not an app launching,
    /// quitting or coming forward — so without a pass of its own the roomier reading stands until the user
    /// happens to switch apps, which is exactly "it opens one way and goes back the other way after I use the
    /// web".
    ///
    /// The script here is the case two agreeing readings cannot tell apart. The pass looks four times: the bar
    /// reads 1000 twice while the icon is still being placed, and 954 twice once it is there. A pass that settled
    /// on the first pair that agreed would keep 1000 and leave the strip arranged for a bar the app is not in.
    /// This one discards every reading taken before its own icon shows up, so only the two 954s can settle it —
    /// take the `showsOwnIcon` guard out and the last three expectations fail, which is what makes this a test of
    /// the pass rather than of the cache invalidation nobody doubted.
    @Test func theOwnIconAppearingIsMeasuredWithoutWaitingForAnAppSwitch() async throws {
        let bare = Self.right(1000), placed = Self.right(954, ownIcon: true)
        let (watcher, prefs, _) = watcher(readings: [400], looks: 4,
                                          statusItems: [bare, bare, bare, bare, placed, placed])
        prefs.compactStyle = .numbers
        watcher.refresh()
        // Items at 1000 leave 1000 - 8 - 853 = 139 pt right of the notch, and the resting split asks 132 for its
        // two readouts, so before the icon is placed both sides of the notch have room.
        #expect(prefs.autoCompactFit?.side == .split, "before the icon is placed both sides of the notch have room")
        #expect(prefs.autoCompactFit?.splitLeading == 1)

        watcher.statusItemsChanged(showingOwnIcon: true)
        await watcher.placingPass?.value
        // At 954 the right-hand gap is 93 pt, which no longer holds the 132 the resting split asks of it, so the
        // strip moves whole to the left rather than sending a readout across the notch.
        let settled = try #require(prefs.autoCompactFit)
        #expect(settled.side == .leading, "the strip fits the bar it is actually in, own icon and all")
        #expect(settled.splitLeading == nil)
        #expect(settled.dropped == 0, "nothing is given up while a whole side still holds the run")
    }
}
