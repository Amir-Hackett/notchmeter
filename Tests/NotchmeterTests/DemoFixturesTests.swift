import Foundation
import Testing
@testable import Notchmeter

/// The readings and cost `--render-assets` draws add up, sit in the calm state the README describes, and seed a
/// store without a provider read.
@Suite struct DemoFixtureReadings {
    @Test func costSeriesAddsUpToTheHeadlineFigures() {
        let cost = DemoFixtures.cost(now: Date())
        // Two tools that can report spend, side by side; the headline figures are their total.
        #expect(cost.providers.map(\.tool) == [.claude, .cursor])
        #expect(cost.providers.map(\.source) == [.localTranscripts, .billingExport])
        #expect(abs(cost.today - cost.providers.reduce(0) { $0 + $1.totals(.today).cost }) < 1e-9)
        #expect(cost.provider(.cursor)?.burnMultiple == nil)
        #expect(cost.daily.count == 30)
        #expect(abs(cost.daily.reduce(0) { $0 + $1.cost } - cost.last30Days) < 0.01)
        #expect(cost.daily.last?.cost == cost.today)
        #expect(cost.daily.dropLast().last?.cost == cost.yesterday)
        #expect(cost.burnMultiple.map { $0 >= Advisor.burnThreshold } == true)
    }

    @Test func everyRingIsQuietAndOnPace() {
        let now = Date()
        let windows = DemoFixtures.readings(now: now).flatMap(\.windows)
        #expect(Presence.level(windows: windows, awaitingInput: false, now: now) == .quiet)
        for window in windows where window.usedFraction != nil && window.periodDuration != nil {
            #expect(Pace.status(for: window, now: now) == .ahead)
        }
    }

    @MainActor @Test func seedsAStoreWithoutAProviderRead() {
        let now = Date()
        let (store, prefs) = DemoFixtures.store(now: now)
        #expect(store.visibleTools == [.claude, .codex, .cursor])
        #expect(store.readyReadings.count == 3)
        #expect(store.nextUpdate != nil)
        #expect(store.advice.contains { $0.id == "burn/claude" })
        #expect(prefs.resetDisplay == .countdown)
    }
}

/// The GIF's open is DynamicNotchKit's spring sampled over the morph.
@Suite struct NotchMorph {
    @Test func theOpeningSpringStartsAtRestOvershootsOnceAndSettles() {
        let samples = (0..<24).map { AssetRenderer.bounce(Double($0) / 23) }
        #expect(abs(samples[0]) < 0.001)
        #expect(samples.max()! > 1)
        #expect(abs(samples[23] - 1) < 0.01)
    }
}
