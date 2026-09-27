import Foundation
import Testing
@testable import Notchmeter

/// A window of a day or longer projected at how far it rose over the last day (RecentPace), and the rates a shorter
/// one has risen at while in use, measured from the high-water mark rather than between consecutive rows.
@Suite struct RecentPaceRules {
    init() { Localization.use(language: "en") }

    let now = DateParsing.iso8601("2026-09-27T16:07:00Z")!
    let hour: TimeInterval = 3600

    /// One row every five minutes from `from` to `to`, each carrying the figure `used` gives for its time: the log
    /// the app writes, which repeats an unmoved figure every five minutes and records the vendor's whole points.
    func rows(from: Date, to: Date, resetsAt: @escaping (Date) -> Date?, used: (Date) -> Double) -> [DrainSample] {
        stride(from: from.timeIntervalSince1970, through: to.timeIntervalSince1970, by: 300).map { seconds in
            let t = Date(timeIntervalSince1970: seconds)
            return DrainSample(t: t, used: used(t), resetsAt: resetsAt(t))
        }
    }

    // MARK: A day's rise

    @Test func aDaysRiseIsTheHighWaterMarksGrowthSoTheFlickerCountsOnce() throws {
        let reset = now.addingTimeInterval(4 * 86400)
        // 50 and 51 in turn for a whole day: the same figure read two ways, and one point of real rise at most.
        var flip = false
        let flicker = rows(from: now.addingTimeInterval(-25 * hour), to: now, resetsAt: { _ in reset }) { _ in
            flip.toggle()
            return flip ? 0.50 : 0.51
        }
        let rate = try #require(RecentPace.rate(flicker, now: now))
        #expect(abs(rate * 24 - 0.01) < 0.001, "one point over the day, not one per flip: \(rate * 24)")
    }

    @Test func aResetInsideTheDayStartsTheNewPeriodFromNothing() throws {
        let oldReset = now.addingTimeInterval(-6 * hour)
        let newReset = oldReset.addingTimeInterval(Period.week)
        let samples = [
            DrainSample(t: now.addingTimeInterval(-24 * hour), used: 0.90, resetsAt: oldReset),
            DrainSample(t: now.addingTimeInterval(-7 * hour), used: 0.94, resetsAt: oldReset),
            DrainSample(t: now.addingTimeInterval(-5 * hour), used: 0.02, resetsAt: newReset),
            DrainSample(t: now, used: 0.10, resetsAt: newReset),
        ]
        let rate = try #require(RecentPace.rate(samples, now: now))
        #expect(abs(rate * 24 - 0.14) < 1e-9, "four points before the reset and ten after it")
    }

    @Test func aLogShorterThanADayHasNoRateAndTheWindowKeepsTheEvenBurn() {
        let reset = now.addingTimeInterval(4 * 86400)
        let samples = rows(from: now.addingTimeInterval(-10 * hour), to: now, resetsAt: { _ in reset }) { _ in 0.4 }
        #expect(RecentPace.rate(samples, now: now) == nil)
        let weekly = LimitWindow(id: "seven_day", label: "Weekly", usedFraction: 0.4, resetsAt: reset, periodDuration: Period.week)
        let reading = UsageReading(tool: .claude, windows: [weekly], plan: nil, fetchedAt: now, observedAt: nil)
        let paced = RecentPace.apply(reading, samples: [DrainLog.Key(tool: .claude, window: "seven_day"): samples], now: now)
        #expect(paced.windows.first?.recentRate == nil)
    }

    @Test func aGapInTheLogWidensTheSpanRatherThanInventingADay() throws {
        let reset = now.addingTimeInterval(4 * 86400)
        let samples = [
            DrainSample(t: now.addingTimeInterval(-48 * hour), used: 0.20, resetsAt: reset),
            DrainSample(t: now, used: 0.30, resetsAt: reset),
        ]
        let rate = try #require(RecentPace.rate(samples, now: now))
        #expect(abs(rate - 0.10 / 48) < 1e-9, "ten points over the two days the Mac was asleep, not over one")
    }

    @Test func aVendorsCorrectionTakesTheMarkDownWithIt() throws {
        let reset = now.addingTimeInterval(4 * 86400)
        let samples = [
            DrainSample(t: now.addingTimeInterval(-24 * hour), used: 0.60, resetsAt: reset),
            DrainSample(t: now.addingTimeInterval(-12 * hour), used: 0.30, resetsAt: reset),
            DrainSample(t: now, used: 0.35, resetsAt: reset),
        ]
        let rate = try #require(RecentPace.rate(samples, now: now))
        #expect(abs(rate * 24 - 0.05) < 1e-9, "the rise after the correction, not nothing until 60% comes back")
    }

    @Test func onlyWindowsOfADayOrLongerArePacedThisWay() {
        let reset = now.addingTimeInterval(3 * hour)
        #expect(RecentPace.applies(to: LimitWindow(id: "seven_day", label: "Weekly", usedFraction: 0.5, resetsAt: reset, periodDuration: Period.week)))
        #expect(RecentPace.applies(to: LimitWindow(id: "monthly", label: "Monthly", usedFraction: 0.5, resetsAt: reset, periodDuration: Period.month)))
        #expect(!RecentPace.applies(to: LimitWindow(id: "five_hour", label: "Session", usedFraction: 0.5, resetsAt: reset, periodDuration: Period.fiveHours)))
        #expect(!RecentPace.applies(to: LimitWindow(id: "spend_today", label: "Today's spend", usedFraction: 0.5, resetsAt: reset, periodDuration: Period.day)))
        // Nor does such a window get the interval any more: its run-out is its projection's.
        let samples = rows(from: now.addingTimeInterval(-30 * hour), to: now, resetsAt: { _ in reset }) { t in 0.2 + 0.01 * t.timeIntervalSince(self.now.addingTimeInterval(-30 * self.hour)) / self.hour }
        #expect(RunOutInterval.estimate(samples: samples, usedFraction: 0.5, resetsAt: reset, now: now, period: Period.week) == nil)
    }

    // MARK: Pace at a recent rate

    @Test func aRecentRateProjectsFromNowToTheReset() throws {
        let reset = now.addingTimeInterval(84 * hour)
        func window(rate: Double?) -> LimitWindow {
            LimitWindow(id: "seven_day", label: "Weekly", usedFraction: 0.5, resetsAt: reset, periodDuration: Period.week, recentRate: rate)
        }
        // Half used halfway through the week: the even burn lands on 100% exactly.
        #expect(Pace.evaluate(window(rate: nil), now: now)?.status == .onTrack)
        #expect(Pace.evaluate(window(rate: 0.001), now: now)?.status == .ahead, "0.5 + 0.084 at the reset")
        #expect(Pace.evaluate(window(rate: 0.005), now: now)?.status == .onTrack, "0.5 + 0.42")
        let fast = window(rate: 0.01)
        #expect(Pace.evaluate(fast, now: now)?.status == .behind)
        let eta = try #require(Pace.secondsToRunOut(fast, now: now))
        #expect(abs(eta - 50 * hour) < 1, "half the window at a point an hour is fifty hours")
        #expect(Pace.note(for: fast, now: now)?.text == "Runs out in 2d 2h")
    }

    // MARK: The week that read as running out on a quiet Sunday morning

    /// The Claude weekly window as the drain log held it on 2026-09-27: reset Thursday 18:00, 0 to 51% by 04:25
    /// Friday, then a point every half day or so, with the vendor's figure flickering a point either way.
    func frontLoadedWeek() -> (samples: [DrainSample], reset: Date, weekly: LimitWindow, fable: LimitWindow) {
        let start = now.addingTimeInterval(-(63 * hour))
        let reset = start.addingTimeInterval(Period.week)
        let steps: [(hours: Double, used: Double)] = [(0, 0), (10.4, 0.51), (15.1, 0.52), (26.9, 0.53), (39.9, 0.54), (40.4, 0.55), (49.5, 0.56)]
        var flip = false
        let samples = rows(from: start, to: now, resetsAt: { _ in reset }) { t in
            let hours = t.timeIntervalSince(start) / self.hour
            if hours < 10.4 { return (0.51 * hours / 10.4 * 100).rounded() / 100 }
            let level = steps.last { $0.hours <= hours }!.used
            flip.toggle()
            // A point down on every other row once in a while, as the two reads of one figure disagree.
            return flip && Int(hours) % 5 == 0 ? level - 0.01 : level
        }
        let weekly = LimitWindow(id: "seven_day", label: .key("Weekly"), usedFraction: 0.56, resetsAt: reset, periodDuration: Period.week)
        let fable = LimitWindow(id: "scoped_fable", label: "Fable", usedFraction: 1, resetsAt: reset, periodDuration: Period.week, model: "Fable")
        return (samples, reset, weekly, fable)
    }

    @Test func aWeekSpentOnItsFirstNightAndQuietSinceIsNotRunningOut() throws {
        let (samples, reset, weekly, fable) = frontLoadedWeek()
        // The even burn alone calls it behind: 56% used 37.5% of the way through.
        #expect(Pace.status(for: weekly, now: now) == .behind)
        let reading = UsageReading(tool: .claude, windows: [weekly, fable], plan: nil, fetchedAt: now, observedAt: nil)
        let paced = RecentPace.apply(reading, samples: [DrainLog.Key(tool: .claude, window: "seven_day"): samples], now: now)
        let week = try #require(paced.windows.first { $0.id == "seven_day" })
        let rate = try #require(week.recentRate)
        #expect(rate * 24 < 0.04, "a few points over the last day, not the first night's pace: \(rate * 24)")
        #expect(Pace.status(for: week, now: now) == .ahead)
        #expect(Pace.note(for: week, now: now)?.text.hasSuffix("left at reset") == true)
        #expect(NotificationScheduler.stage(for: week, now: now, rate: 0.12, runOut: nil) == nil,
                "no Will run out, whatever the last busy hour measured")
        // The advice: no forecast for the week, and the model that is actually out, with where to go instead, first.
        var context = Advisor.Context(readings: [paced], now: now)
        context.drainRates = ["claude/seven_day": 0.12]
        let lines = Advisor.advise(context)
        #expect(!lines.contains { $0.id == "run-out/claude/seven_day" }, "\(lines.map(\.text))")
        #expect(lines.first?.id == "model/claude/scoped_fable")
        #expect(lines.first?.priority == .danger)
        #expect(lines.first?.text.hasPrefix("Fable weekly is 100%. Overall weekly is 56%.") == true)
        _ = reset
    }

    @Test func aModelUsedUpLeadsEvenARealForecast() throws {
        let (_, reset, weekly, fable) = frontLoadedWeek()
        let busy = weekly.pacing(at: 0.02)
        #expect(Pace.status(for: busy, now: now) == .behind)
        let reading = UsageReading(tool: .claude, windows: [busy, fable], plan: nil, fetchedAt: now, observedAt: nil)
        let lines = Advisor.advise(Advisor.Context(readings: [reading], timeFormat: .twentyFourHour, now: now))
        #expect(lines.map(\.id).prefix(2) == ["model/claude/scoped_fable", "run-out/claude/seven_day"])
        // Twenty-two hours at two points an hour, named once, from the projection the ring was coloured by.
        let eta = try #require(Pace.secondsToRunOut(busy, now: now))
        #expect(abs(eta - 22 * hour) < 1)
        #expect(eta < reset.timeIntervalSince(now))
    }

    // MARK: The session's rates

    @Test func aOnePointStepAfterAQuietStretchReadsAsItsRealPace() {
        let reset = now.addingTimeInterval(2 * hour)
        let start = now.addingTimeInterval(-3 * hour)
        // A point every twenty minutes, logged every five: three points an hour, which the old pairwise rate read
        // as twelve (one point over the five minutes before each step).
        let samples = rows(from: start, to: now, resetsAt: { _ in reset }) { t in
            0.10 + (t.timeIntervalSince(start) / 1200).rounded(.down) / 100
        }
        let rates = RunOutInterval.hourlyRates(samples, since: start).map(\.perHour)
        #expect(!rates.isEmpty)
        #expect(rates.allSatisfy { abs($0 - 0.03) < 0.0001 }, "\(rates)")
    }

    @Test func theFlickerIsNotCountedAsFreshRisesAndABreakSaysNothingAboutThePace() {
        let reset = now.addingTimeInterval(2 * hour)
        let start = now.addingTimeInterval(-2 * hour)
        var flip = false
        let flicker = rows(from: start, to: now, resetsAt: { _ in reset }) { _ in
            flip.toggle()
            return flip ? 0.50 : 0.51
        }
        #expect(RunOutInterval.hourlyRates(flicker, since: start).count <= 1, "at most the first crossing, once")
        let afterABreak = [
            DrainSample(t: start, used: 0.10, resetsAt: reset),
            DrainSample(t: start.addingTimeInterval(90 * 60), used: 0.10, resetsAt: reset),
            DrainSample(t: start.addingTimeInterval(95 * 60), used: 0.11, resetsAt: reset),
        ]
        #expect(RunOutInterval.hourlyRates(afterABreak, since: start).isEmpty, "a point after an hour and a half idle is not a pace")
    }

    // MARK: The status line

    @Test func theStatusLinePacesTheWeekAsTheAppDoes() throws {
        let (samples, _, weekly, _) = frontLoadedWeek()
        let reading = RecentPace.apply(UsageReading(tool: .claude, windows: [weekly], plan: nil, fetchedAt: now, observedAt: nil),
                                       samples: [DrainLog.Key(tool: .claude, window: "seven_day"): samples], now: now)
        let rate = try #require(reading.windows.first?.recentRate)
        let report = UsageReport(tools: [.claude: .ready(reading)], cost: nil, advice: [], now: now)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("notchmeter-recent-pace-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("report-v1.json")
        try report.json.write(to: file)
        let extras = Statusline.Extras.read(reportFile: file, history: nil, now: now.addingTimeInterval(60))
        let read = try #require(extras.recentRates["seven_day"])
        #expect(abs(read - rate) < 0.0001)
        // The payload's own weekly window, which carries no history: red at the even burn, calm at the app's pace.
        #expect(Statusline.tint(for: weekly, now: now) == .danger)
        #expect(Statusline.tint(for: weekly.pacing(at: read), now: now) == .none)
    }
}
