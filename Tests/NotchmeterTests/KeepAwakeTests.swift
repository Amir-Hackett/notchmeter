import Foundation
import Testing
@testable import Notchmeter

/// The store's half of keep-awake: the rule is pinned in DisplayIdentityTests, but the bug lived above it, in
/// how the store learned which power source it was on.
@Suite struct KeepAwake {
    init() { Localization.use(language: "en") }

    let t0 = DateParsing.iso8601("2026-09-01T12:00:00Z")!

    /// `onBattery` was refreshed by the minute tick alone, and the tick is parked while the display sleeps or the
    /// screen is locked, so a Mac unplugged in that state stayed held awake on battery against the "also on
    /// battery" setting until somebody woke the display. The store now takes the power source from IOKit's
    /// transition callback through one writer; this drives that writer with the tick parked and expects the
    /// assertion to go with the charger and come back with it.
    @MainActor @Test func unpluggingReleasesTheAssertionWhileTheTickIsParked() {
        let suite = "NotchmeterTests.keepAwakeBattery"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = Preferences(defaults: defaults)
        prefs.keepAwake = true
        prefs.keepAwakeOnBattery = false
        let store = UsageStore(prefs: prefs, providers: [], cache: ReadingCache(defaults: defaults), defaults: defaults,
                               drainLog: nil, reportFile: nil)
        var holds: [Bool] = []
        store.awakeChanged = { holds.append($0) }
        store.hookReceived(Hook.Message(event: "UserPromptSubmit", needsInput: false, sessionID: "a"), now: t0)
        #expect(store.keepingAwake, "a working session on mains holds the assertion")
        // `start()` was never called, so no tick is running: the transition callback is the only thing that can move
        // the power source, which is the state the bug needed.
        store.setOnBattery(true)
        #expect(!store.keepingAwake, "the charger came out and the setting says not on battery")
        #expect(store.onBattery)
        store.setOnBattery(true)
        let afterUnplug = [true, false]
        #expect(holds == afterUnplug, "the same source reported twice is not a second release")
        store.setOnBattery(false)
        #expect(store.keepingAwake, "plugged back in mid-run, the assertion is held again rather than left to the tick")
        let afterReplug = [true, false, true]
        #expect(holds == afterReplug)
    }

    /// With the override on, the power source moving is not the assertion's business; it stays held both ways.
    @MainActor @Test func theBatteryOverrideKeepsTheAssertionAcrossTheTransition() {
        let suite = "NotchmeterTests.keepAwakeOverride"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = Preferences(defaults: defaults)
        prefs.keepAwake = true
        prefs.keepAwakeOnBattery = true
        let store = UsageStore(prefs: prefs, providers: [], cache: ReadingCache(defaults: defaults), defaults: defaults,
                               drainLog: nil, reportFile: nil)
        var holds: [Bool] = []
        store.awakeChanged = { holds.append($0) }
        store.hookReceived(Hook.Message(event: "UserPromptSubmit", needsInput: false, sessionID: "a"), now: t0)
        store.setOnBattery(true)
        store.setOnBattery(false)
        let heldOnce = [true]
        #expect(holds == heldOnce)
        #expect(store.keepingAwake)
    }
}
