import AppKit
import Foundation
import Testing
@testable import Notchmeter

/// The panel's controls that make it the reader's own: how many session rows before "+N more" and what each row
/// leads with, what the closed notch shows while working and while quiet, scrolling a ring onto another window,
/// a switch per display, and the week of spend on the Cost row.

private let t0 = DateParsing.iso8601("2026-09-01T12:00:00Z")!

private func session(_ id: String, project: String? = "notchmeter", branch: String? = "main", title: String? = nil, host: String? = nil,
                     state: AgentSession.State = .idle, lastEvent: TimeInterval = 0, pending: PendingRequest? = nil) -> AgentSession {
    var session = AgentSession(id: id, project: project, state: state, started: t0, lastEvent: t0.addingTimeInterval(lastEvent), turnStarted: nil,
                               branch: branch, host: host)
    session.title = title
    session.pending = pending
    return session
}

// MARK: - Rows at once

@Suite struct SessionRowsAtOnce {
    @Test func theCardDrawsAsManyRowsAsTheSettingAsksThenCountsTheRest() {
        let sessions = (0..<12).map { session("s\($0)", lastEvent: TimeInterval($0)) }
        for cap in Preferences.sessionRowChoices {
            let (rows, more) = SessionsCard.rows(sessions, hideTitles: false, jump: false, now: t0, cap: cap)
            #expect(rows.count == cap)
            let left = 12 - cap
            #expect(more == left)
        }
        let (few, none) = SessionsCard.rows(Array(sessions.prefix(3)), hideTitles: false, jump: false, now: t0, cap: 10)
        #expect(few.count == 3)
        #expect(none == 0, "fewer sessions than the cap leave nothing to count")
        #expect(SessionsCard.rows(sessions, hideTitles: false, jump: false, now: t0).rows.count == SessionsCard.rowCap, "the default is the old six")
    }

    @Test func aStoredCountSnapsToTheNearestChoice() {
        #expect(Preferences.sessionRowChoices == [4, 6, 8, 10])
        #expect(Preferences.sessionRowChoice(6) == 6)
        #expect(Preferences.sessionRowChoice(7) == 6, "a tie goes to the lower")
        #expect(Preferences.sessionRowChoice(9) == 8)
        #expect(Preferences.sessionRowChoice(1) == 4)
        #expect(Preferences.sessionRowChoice(40) == 10)
    }

    @MainActor @Test func theCountAndTheLeadAreKeptAndReadBack() {
        let suite = "NotchmeterTests.PanelControls.rows"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = Preferences(defaults: defaults)
        #expect(prefs.sessionRows == 6)
        #expect(prefs.sessionRowLead == .title)
        prefs.sessionRows = 9
        #expect(prefs.sessionRows == 8, "a count off the list is snapped as it is written")
        prefs.sessionRowLead = .project
        let again = Preferences(defaults: defaults)
        #expect(again.sessionRows == 8)
        #expect(again.sessionRowLead == .project)
    }
}

// MARK: - What a row leads with

@Suite struct SessionRowLeadRules {
    @Test func theProjectLeadsAndTheTitleOpensTheSecondLine() {
        let titled = session("a", title: "Fix the flaky test")
        let byTitle = SessionsCard.line(of: titled, place: "iTerm", hideTitles: false, grouped: false, lead: .title)
        #expect(byTitle.title == "Fix the flaky test")
        #expect(byTitle.detail == nil)
        #expect(byTitle.branch == "main")
        let byProject = SessionsCard.line(of: titled, place: "iTerm", hideTitles: false, grouped: false, lead: .project)
        #expect(byProject.title == "notchmeter")
        #expect(byProject.detail == "Fix the flaky test")
        #expect(byProject.branch == "main")
        #expect(byProject.place == "iTerm")
    }

    @Test func underAHeaderTheBranchLeadsRatherThanTheProjectAgain() {
        let titled = session("a", title: "Fix the flaky test")
        let grouped = SessionsCard.line(of: titled, place: "iTerm", hideTitles: false, grouped: true, lead: .project)
        #expect(grouped.title == "main")
        #expect(grouped.detail == "Fix the flaky test")
        #expect(grouped.branch == nil, "the branch is the title now, not said twice")
        let noBranch = SessionsCard.line(of: session("b", branch: nil, title: "Ship it"), place: "iTerm", hideTitles: false, grouped: true, lead: .project)
        #expect(noBranch.title == "iTerm")
        #expect(noBranch.detail == "Ship it")
        let neither = SessionsCard.line(of: session("c", branch: nil, title: "Ship it"), place: nil, hideTitles: false, grouped: true, lead: .project)
        #expect(neither.title == "Ship it", "nothing but the header's project to lead with: the title leads as it would anyway")
        #expect(neither.detail == nil)
    }

    @Test func hiddenTitlesAndUntitledRowsAreTheSameEitherWay() {
        let titled = session("a", title: "Secret plan")
        for lead in SessionRowLead.allCases {
            let hidden = SessionsCard.line(of: titled, place: nil, hideTitles: true, grouped: false, lead: lead)
            #expect(hidden.title == "notchmeter")
            #expect(hidden.detail == nil, "a shared screen never shows the prompt, on either line")
            let untitled = SessionsCard.line(of: session("b"), place: nil, hideTitles: false, grouped: false, lead: lead)
            #expect(untitled.title == "notchmeter")
            #expect(untitled.detail == nil)
        }
        let remote = SessionsCard.line(of: session("r", title: "Deploy", host: "devbox"), place: nil, hideTitles: false, grouped: false, lead: .project)
        #expect(remote.title == "notchmeter@devbox")
        #expect(remote.host == nil, "the title already carries the host")
    }

    @Test func theRowsCarryTheLeadThrough() {
        let rows = SessionsCard.rows([session("a", title: "Fix it")], hideTitles: false, jump: false, now: t0, lead: .project).rows
        #expect(rows.first?.title == "notchmeter")
        #expect(rows.first?.detail == "Fix it")
        let plain = SessionsCard.rows([session("a", title: "Fix it")], hideTitles: false, jump: false, now: t0).rows
        #expect(plain.first?.title == "Fix it")
        #expect(plain.first?.detail == nil)
    }
}

// MARK: - The closed notch

@Suite struct ClosedNotchRules {
    @Test func activeIsWorkingWaitingARequestOrALitSignal() {
        let pending = PendingRequest(id: "r", kind: .permission(tool: "Bash", summary: "ls", detail: nil, suggestions: []), since: t0)
        #expect(!ClosedNotch.active(sessions: [], signalled: false))
        #expect(!ClosedNotch.active(sessions: [session("idle")], signalled: false))
        #expect(ClosedNotch.active(sessions: [session("w", state: .working(since: t0))], signalled: false))
        #expect(ClosedNotch.active(sessions: [session("q", state: .waiting(since: t0))], signalled: false))
        #expect(ClosedNotch.active(sessions: [session("p", pending: pending)], signalled: false))
        #expect(ClosedNotch.active(sessions: [session("idle")], signalled: true), "a finished turn's tick counts")
    }

    @Test func eachPhaseShowsItsOwnChoiceAndNothingYieldsWhileUrgent() {
        #expect(ClosedNotch.shows(phase: .work, whileWorking: .agents, whenQuiet: .nothing, urgent: false) == .agents)
        #expect(ClosedNotch.shows(phase: .quiet, whileWorking: .agents, whenQuiet: .nothing, urgent: false) == .nothing)
        #expect(ClosedNotch.shows(phase: .quiet, whileWorking: .agents, whenQuiet: .nothing, urgent: true) == .readouts,
                "a bare notch never hides a limit running out")
        #expect(ClosedNotch.shows(phase: .work, whileWorking: .agents, whenQuiet: .nothing, urgent: true) == .agents,
                "the symbols carry the waiting mark themselves")
        #expect(ClosedNotch.shows(phase: .quiet, whileWorking: .readouts, whenQuiet: .readouts, urgent: false) == .readouts)
    }

    @Test func theWorkPhaseHoldsFiveSecondsPastTheLastActivity() throws {
        var clock = ClosedNotchClock()
        #expect(clock.phase == .quiet)
        let idle = clock.update(active: false, now: t0)
        #expect(idle == nil)
        #expect(clock.phase == .quiet, "quiet stays quiet with no hold")
        let started = clock.update(active: true, now: t0)
        #expect(started == nil)
        #expect(clock.phase == .work)
        let stopped = t0.addingTimeInterval(60)
        let first = clock.update(active: false, now: stopped)
        let recheck = try #require(first)
        #expect(recheck == stopped.addingTimeInterval(ClosedNotchClock.hold))
        #expect(clock.phase == .work, "the hold keeps the phase")
        let inside = clock.update(active: false, now: stopped.addingTimeInterval(2))
        #expect(inside == recheck, "a look inside the hold keeps the same end")
        #expect(clock.phase == .work)
        let ended = clock.update(active: false, now: recheck)
        #expect(ended == nil)
        #expect(clock.phase == .quiet)
    }

    @Test func activityInsideTheHoldCancelsIt() {
        var clock = ClosedNotchClock()
        _ = clock.update(active: true, now: t0)
        _ = clock.update(active: false, now: t0.addingTimeInterval(1))
        _ = clock.update(active: true, now: t0.addingTimeInterval(3))
        #expect(clock.phase == .work)
        let stopped = t0.addingTimeInterval(30)
        let recheck = clock.update(active: false, now: stopped)
        #expect(recheck == stopped.addingTimeInterval(ClosedNotchClock.hold), "the hold runs from the new stop, not the old one")
    }

    @Test func aGlyphTellsWaitingWorkingFinishedIdleAndNone() {
        #expect(AgentGlyphState.of(signal: .waiting(count: 2), working: true, sessions: 3) == .waiting(count: 2), "a wait outranks work")
        #expect(AgentGlyphState.of(signal: nil, working: true, sessions: 1) == .working)
        #expect(AgentGlyphState.of(signal: .finished(turn: 60), working: false, sessions: 1) == .finished)
        #expect(AgentGlyphState.of(signal: nil, working: false, sessions: 2) == .idle)
        #expect(AgentGlyphState.of(signal: nil, working: false, sessions: 0) == .none)
        #expect(AgentGlyphState.of(signal: nil, working: false, sessions: nil) == .none)
        #expect(AgentGlyphState.waiting(count: 1).signal == .waiting(count: 1))
        #expect(AgentGlyphState.working.signal == nil, "working is the bar, not a mark")
    }

    @Test func idleAndNoSessionDifferByShapeNotColourAlone() {
        #expect(AgentGlyphState.working.underMark == .bar)
        #expect(AgentGlyphState.idle.underMark == .ring, "the Sessions card's hollow idle mark, in miniature")
        #expect(AgentGlyphState.none.underMark == nil, "grey with nothing under it")
        #expect(AgentGlyphState.waiting(count: 1).underMark == nil, "a wait is the corner mark's")
        #expect(AgentGlyphState.finished.underMark == nil)
    }

    /// The store's seam: a hook event puts the notch to work, a stop starts the hold, the hold's own booked look
    /// ends it with nothing else changing, and what the notch shows follows the phase.
    @MainActor @Test func aHookEventPutsTheNotchToWorkAndTheHoldEndsIt() async throws {
        let suite = "NotchmeterTests.PanelControls.closedStore"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        // A minute in the wall clock's past: the hold's booked look sleeps until the hold ends and then reads the
        // real clock, so a hold that began back then is over the moment the look runs.
        let start = Date().addingTimeInterval(-60)
        let (store, prefs) = DemoFixtures.store(now: start, moment: .idle, suite: suite)
        prefs.closedWhileWorking = .agents
        prefs.closedWhenQuiet = .readouts
        #expect(store.closedNotchPhase == .quiet, "every session idle, nothing lit")
        #expect(store.closedNotchShows == .readouts)
        #expect(store.agentGlyphState(.claude, now: start) == .idle)
        let prompt = Hook.Message(event: "UserPromptSubmit", needsInput: false, sessionID: "s", project: "notchmeter")
        let stop = Hook.Message(event: "Stop", needsInput: false, sessionID: "s", project: "notchmeter")
        store.hookReceived(prompt, now: start)
        #expect(store.closedNotchPhase == .work)
        #expect(store.closedNotchShows == .agents)
        #expect(store.agentGlyphState(.claude, now: start) == .working)
        // A ten-second turn: too short for the finished tick (ToolSignal.finishedAfter), so only the hold keeps
        // the phase once it stops.
        let stopped = start.addingTimeInterval(10)
        store.hookReceived(stop, now: stopped)
        #expect(store.closedNotchPhase == .work, "the hold")
        #expect(store.agentGlyphState(.claude, now: stopped) == .idle)
        store.updateClosedNotch(now: stopped.addingTimeInterval(ClosedNotchClock.hold - 1))
        #expect(store.closedNotchPhase == .work, "a look inside the hold")
        store.updateClosedNotch(now: stopped.addingTimeInterval(ClosedNotchClock.hold))
        #expect(store.closedNotchPhase == .quiet)
        #expect(store.closedNotchShows == .readouts)
        // Again, and this time nothing looks until the hold's own booked look does: the look is booked for the
        // hold's end, a tenth of a second on from the last look here, and reads the wall clock when it runs.
        let again = stopped.addingTimeInterval(20)
        store.hookReceived(prompt, now: again)
        store.hookReceived(stop, now: again.addingTimeInterval(1))
        #expect(store.closedNotchPhase == .work)
        store.updateClosedNotch(now: again.addingTimeInterval(1 + ClosedNotchClock.hold - 0.1))
        #expect(store.closedNotchPhase == .work)
        let deadline = Date().addingTimeInterval(3)
        while store.closedNotchPhase == .work, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(store.closedNotchPhase == .quiet, "the booked look ended the hold by itself")
    }

    @MainActor @Test func theModesAreKeptAndDefaultToTheReadouts() {
        let suite = "NotchmeterTests.PanelControls.closed"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = Preferences(defaults: defaults)
        #expect(prefs.closedWhileWorking == .readouts)
        #expect(prefs.closedWhenQuiet == .readouts)
        prefs.closedWhileWorking = .agents
        prefs.closedWhenQuiet = .nothing
        let again = Preferences(defaults: defaults)
        #expect(again.closedWhileWorking == .agents)
        #expect(again.closedWhenQuiet == .nothing)
    }
}

// MARK: - Scroll a ring onto another window

@Suite struct RingCycleRules {
    init() { Localization.use(language: "en") }

    let windows = ["five_hour", "seven_day", "scoped_fable"]

    @Test func aStepMovesTheOuterRingAndWrapsAtBothEnds() {
        #expect(RingCycle.next(drawn: ["five_hour"], candidates: windows, step: 1) == ["seven_day"])
        #expect(RingCycle.next(drawn: ["scoped_fable"], candidates: windows, step: 1) == ["five_hour"], "past the last is the first")
        #expect(RingCycle.next(drawn: ["five_hour"], candidates: windows, step: -1) == ["scoped_fable"], "before the first is the last")
    }

    @Test func anInnerRingOnTheNewWindowSwapsSoNothingShowsTwice() {
        #expect(RingCycle.next(drawn: ["five_hour", "seven_day"], candidates: windows, step: 1) == ["seven_day", "five_hour"])
        #expect(RingCycle.next(drawn: ["five_hour", "seven_day"], candidates: windows, step: -1) == ["scoped_fable", "seven_day"])
    }

    @Test func nothingToCycleIsNoChange() {
        #expect(RingCycle.next(drawn: ["five_hour"], candidates: ["five_hour"], step: 1) == nil)
        #expect(RingCycle.next(drawn: ["five_hour"], candidates: windows, step: 0) == nil)
        #expect(RingCycle.next(drawn: ["gone"], candidates: windows, step: 1) == ["five_hour"], "an outer ring off the list starts at the first")
        #expect(RingCycle.next(drawn: ["gone"], candidates: windows, step: -1) == ["scoped_fable"])
        #expect(RingCycle.next(drawn: [], candidates: windows, step: 1) == ["five_hour"])
    }

    @Test func onlyWindowsWithAFigureAreOffered() {
        let figure = LimitWindow(id: "a", label: "A", usedFraction: 0.2, resetsAt: nil)
        let none = LimitWindow(id: "b", label: "B", usedFraction: nil, resetsAt: nil)
        #expect(RingCycle.candidates([figure, none]).map(\.id) == ["a"])
    }

    @Test func theLabelNamesTheWindowItsFigureAndItsSource() {
        let weekly = LimitWindow(id: "seven_day", label: .key("Weekly"), usedFraction: 0.62, resetsAt: nil)
        #expect(RingCycle.label(weekly, display: .used, hideFigures: false) == "Weekly · 62% used")
        #expect(RingCycle.label(weekly, display: .left, hideFigures: false) == "Weekly · 38% left")
        #expect(RingCycle.label(weekly, display: .used, hideFigures: true) == "Weekly", "no figure while the screen is shared")
        let inferred = LimitWindow(id: "budget", label: "Budget", usedFraction: 0.4, resetsAt: nil, source: .localEstimate)
        #expect(RingCycle.label(inferred, display: .used, hideFigures: false) == "Budget · 40% used · inferred")
    }

    @MainActor @Test func aCycleIsKeptAsTheRingChoiceAndSaidToTheOracle() throws {
        let suite = "NotchmeterTests.PanelControls.cycle"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let (store, prefs) = DemoFixtures.store(now: Date(), suite: suite)
        let reading = try #require(store.status(.claude).reading)
        #expect(prefs.ringWindows(of: reading).map(\.id) == ["five_hour", "seven_day"])
        let moved = store.cycleRing(.claude, by: 1, cause: .scroll)
        #expect(moved?.id == "seven_day")
        #expect(prefs.ringWindows[.claude] == ["seven_day", "five_hour"], "the two rings swap; neither is lost")
        #expect(prefs.ringWindows(of: reading).map(\.id) == ["seven_day", "five_hour"])
        #expect(store.cycleRing(.cursor, by: 1, cause: .scroll) == nil, "Cursor's fixture has nothing with a figure to cycle to")
    }
}

@Suite struct RingScrollRules {
    func wheel(_ deltaY: CGFloat) -> RingScroll.Input { RingScroll.Input(deltaX: 0, deltaY: deltaY, phase: .none, momentum: false) }
    func pad(_ deltaX: CGFloat, _ deltaY: CGFloat, _ phase: RingScroll.Phase) -> RingScroll.Input {
        RingScroll.Input(deltaX: deltaX, deltaY: deltaY, phase: phase, momentum: false)
    }

    /// Feeds a run of events and hands back each outcome, so no expectation calls a mutating method itself.
    func run(_ events: [(RingScroll.Input, TimeInterval)], verticalSwipes: Bool = true) -> [RingScroll.Outcome] {
        var scroll = RingScroll()
        return events.map { scroll.feed($0.0, verticalSwipes: verticalSwipes, at: $0.1) }
    }

    @Test func aWheelStepsOncePerSpin() {
        let outcomes = run([(wheel(-1), 0), (wheel(-1), 0.05), (wheel(-1), 0.2), (wheel(1), 0.6)])
        #expect(outcomes[0] == .init(step: 1, claimed: true))
        #expect(outcomes[1] == .init(step: nil, claimed: true), "the same spin")
        #expect(outcomes[2] == .init(step: nil, claimed: true), "still turning")
        #expect(outcomes[3] == .init(step: -1, claimed: true), "a rest ends the spin; the other way is the previous window")
    }

    @Test func aSidewaysSwipeStepsOnceAndItsMomentumNothing() {
        let momentum = RingScroll.Input(deltaX: -30, deltaY: 0, phase: .none, momentum: true)
        let outcomes = run([(pad(-10, 1, .began), 0), (pad(-16, 0, .changed), 0.02), (pad(-40, 0, .changed), 0.04), (pad(0, 0, .ended), 0.06),
                            (momentum, 0.1), (pad(12, 0, .began), 1), (pad(14, 0, .changed), 1.02)])
        #expect(outcomes[0] == .init(step: nil, claimed: true))
        #expect(outcomes[1] == .init(step: 1, claimed: true))
        #expect(outcomes[2] == .init(step: nil, claimed: true), "one step a gesture")
        #expect(outcomes[3] == .init(step: nil, claimed: true))
        #expect(outcomes[4] == .init(step: nil, claimed: true), "a flick is one window, not five")
        #expect(outcomes[5] == .init(step: nil, claimed: true))
        #expect(outcomes[6] == .init(step: -1, claimed: true), "a new gesture steps again")
    }

    @Test func aVerticalSwipeStaysASwipeUnlessSwipesAreOff() {
        let momentum = RingScroll.Input(deltaX: 0, deltaY: -30, phase: .none, momentum: true)
        let swipes = run([(pad(0, -30, .began), 0), (momentum, 0.1)])
        #expect(swipes[0] == .init(step: nil, claimed: false), "the panel's swipe down")
        #expect(swipes[1].claimed == false, "and its momentum is the swipe's too")
        let off = run([(pad(0, -30, .began), 0)], verticalSwipes: false)
        #expect(off[0] == .init(step: 1, claimed: true))
    }
}

/// The driver's seam between a scroll over a readout and the panel's swipe: the readout is offered the scroll
/// first, and a scroll it claims never also feeds the swipe, while one it does not still opens the panel.
@Suite struct RingScrollDriverRules {
    func scroll(_ deltaX: CGFloat, _ deltaY: CGFloat, _ phase: NSEvent.Phase, fingersDown: Bool = true) -> PointerEvent {
        let ringPhase: RingScroll.Phase = phase.contains(.began) ? .began : phase.contains(.ended) ? .ended : phase.isEmpty ? .none : .changed
        return PointerEvent(kind: .scroll(PointerEvent.Scroll(deltaY: deltaY, fingersDown: fingersDown, phase: phase,
                                                              ring: RingScroll.Input(deltaX: deltaX, deltaY: deltaY, phase: ringPhase, momentum: false))))
    }

    @MainActor
    func driver(ring: ToolID?) -> (hover: HoverDriver, steps: () -> [Int], outputs: () -> [HoverIntent.Output]) {
        let hover = HoverDriver(mode: .onHover)
        hover.haptics = false
        hover.regions = HoverRegions(compact: CGRect(x: 100, y: 900, width: 200, height: 30), expanded: CGRect(x: 50, y: 0, width: 300, height: 800))
        hover.pointerLocation = { CGPoint(x: 150, y: 915) }
        hover.ringAt = { _ in ring }
        var steps: [Int] = []
        hover.ringScrolled = { _, step in steps.append(step) }
        var outputs: [HoverIntent.Output] = []
        hover.perform = { output, _ in outputs.append(output) }
        return (hover, { steps }, { outputs })
    }

    @MainActor @Test func aSidewaysGestureOverAReadoutStepsTheRingAndNoneOfItsTravelOpensThePanel() {
        let (hover, steps, outputs) = driver(ring: .claude)
        // Thirty points of vertical travel inside a sideways gesture: enough for the swipe, had it been fed.
        hover.handle(scroll(-20, 10, .began))
        hover.handle(scroll(-20, 10, .changed))
        hover.handle(scroll(-20, 10, .changed))
        hover.handle(scroll(0, 0, .ended))
        #expect(steps() == [1], "one step a gesture")
        #expect(outputs().isEmpty, "the gesture was the readout's")
        #expect(hover.state == .compact)
    }

    @MainActor @Test func aVerticalSwipeOverAReadoutStillOpensThePanel() {
        let (hover, steps, outputs) = driver(ring: .claude)
        hover.handle(scroll(0, 30, .began))
        #expect(outputs() == [.expand])
        #expect(steps().isEmpty, "the swipe is not a step")
    }

    @MainActor @Test func withSwipesOffAVerticalScrollOverAReadoutIsTheRings() {
        let (hover, steps, outputs) = driver(ring: .claude)
        hover.gestures = false
        hover.handle(scroll(0, -30, .began))
        #expect(steps() == [1])
        #expect(outputs().isEmpty)
    }

    @MainActor @Test func aScrollAwayFromTheReadoutsOrOverAnOpenPanelIsNeverTheRings() {
        let (away, awaySteps, awayOutputs) = driver(ring: nil)
        away.handle(scroll(-30, 0, .began))
        #expect(awaySteps().isEmpty, "nothing under the pointer to retarget")
        away.handle(scroll(0, 30, .changed))
        #expect(awayOutputs() == [.expand], "and the swipe is still the swipe")
        let (open, openSteps, openOutputs) = driver(ring: .claude)
        open.adopt(.expanded)
        open.handle(scroll(0, -1, []))
        #expect(openSteps().isEmpty, "a wheel over the readout with the panel open is the panel's")
        #expect(openOutputs().isEmpty)
    }
}

@Suite struct RingTargetAndLabelPlacement {
    @Test func theReadoutUnderThePointerWinsWithAFewPointsOfSlop() {
        let rects: [(tool: ToolID, rect: CGRect)] = [(.claude, CGRect(x: 100, y: 950, width: 18, height: 18)),
                                                    (.codex, CGRect(x: 123, y: 950, width: 18, height: 18))]
        #expect(RingTargets.hit(rects, CGPoint(x: 109, y: 959)) == .claude)
        #expect(RingTargets.hit(rects, CGPoint(x: 132, y: 959)) == .codex)
        #expect(RingTargets.hit(rects, CGPoint(x: 120, y: 959)) == .claude, "in both slops, the nearer centre")
        #expect(RingTargets.hit(rects, CGPoint(x: 121.5, y: 959)) == .codex, "past the first one's slop")
        #expect(RingTargets.hit(rects, CGPoint(x: 300, y: 959)) == nil)
        #expect(RingTargets.hit([], CGPoint(x: 109, y: 959)) == nil)
    }

    @Test func theLabelHangsUnderTheTopAboveTheBottomAndInboardOfASide() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let size = CGSize(width: 100, height: 24)
        let top = RingLabel.frame(ring: CGRect(x: 600, y: 950, width: 18, height: 32), size: size, edge: .top, screen: screen)
        #expect(top == CGRect(x: 559, y: 950 - RingLabel.gap - 24, width: 100, height: 24))
        let bottom = RingLabel.frame(ring: CGRect(x: 600, y: 10, width: 18, height: 18), size: size, edge: .bottom, screen: screen)
        #expect(bottom.minY == 28 + RingLabel.gap)
        let left = RingLabel.frame(ring: CGRect(x: 0, y: 480, width: 30, height: 18), size: size, edge: .left, screen: screen)
        #expect(left.minX == 30 + RingLabel.gap)
        let right = RingLabel.frame(ring: CGRect(x: 1482, y: 480, width: 30, height: 18), size: size, edge: .right, screen: screen)
        #expect(right.maxX == 1482 - RingLabel.gap)
        let corner = RingLabel.frame(ring: CGRect(x: 0, y: 950, width: 18, height: 32), size: size, edge: .top, screen: screen)
        #expect(corner.minX == 0, "kept on the screen")
    }
}

// MARK: - A switch per display

@Suite struct DisplaySwitchRules {
    let builtIn = ScreenInfo(name: "Built-in Retina Display", key: "builtin", hasNotch: true, isMain: true, frame: CGRect(x: 0, y: 0, width: 1512, height: 982))
    let dell = ScreenInfo(name: "DELL U2723QE", key: "dell", hasNotch: false, isMain: false, frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440))
    let lg = ScreenInfo(name: "LG UltraFine", key: "lg", hasNotch: false, isMain: false, frame: CGRect(x: 4072, y: 0, width: 2560, height: 1440))

    @Test func anUnswitchedDisplayIsOnWhenItHasANotch() {
        let screens = [builtIn, dell, lg]
        #expect(DisplaySwitches.indices(screens: screens, switches: [:]) == [0])
        #expect(ScreenSelection.indices(for: .selected, screens: screens, pointer: .zero) == [0])
    }

    @Test func withNoNotchAnywhereTheMainDisplayStandsIn() {
        let main = ScreenInfo(name: "Studio Display", key: "studio", hasNotch: false, isMain: true, frame: .zero)
        #expect(DisplaySwitches.indices(screens: [dell, main], switches: [:]) == [1])
    }

    @Test func switchesTurnDisplaysOnAndOffByIdentity() {
        let screens = [builtIn, dell, lg]
        #expect(ScreenSelection.indices(for: .selected, screens: screens, pointer: .zero, switches: ["dell": true]) == [0, 1])
        #expect(ScreenSelection.indices(for: .selected, screens: screens, pointer: .zero, switches: ["dell": true, "builtin": false]) == [1])
        #expect(ScreenSelection.indices(for: .selected, screens: [lg, dell], pointer: .zero, switches: ["dell": true]) == [1],
                "a switch follows its display wherever it is in the list")
    }

    @Test func theLastDisplayOnCannotBeSwitchedOffAndAnEmptySetFallsBack() {
        let screens = [builtIn, dell]
        #expect(!DisplaySwitches.canSwitchOff(builtIn, in: screens, switches: [:]), "the only one on")
        #expect(DisplaySwitches.canSwitchOff(builtIn, in: screens, switches: ["dell": true]))
        #expect(DisplaySwitches.canSwitchOff(dell, in: screens, switches: ["dell": true]))
        // Every switched-on display unplugged: the built-in display, as a named display that is gone.
        #expect(ScreenSelection.indices(for: .selected, screens: screens, pointer: .zero, switches: ["builtin": false, "gone": true]) == [0])
    }

    /// Every switched-on display unplugged: the app is on the built-in display with its switch off, and Settings
    /// says it stands in rather than showing a switch that reads off on the one display the notch is on.
    @Test func theDisplayTheAppFellBackToStandsInWhileItsSwitchStaysOff() {
        let alone = [builtIn]
        let switches = ["builtin": false, "dell": true]
        #expect(ScreenSelection.indices(for: .selected, screens: alone, pointer: .zero, switches: switches) == [0])
        #expect(!DisplaySwitches.isOn(builtIn, in: alone, switches: switches), "the switch reads as it was left")
        #expect(DisplaySwitches.standsIn(builtIn, in: alone, switches: switches))
        #expect(!DisplaySwitches.standsIn(builtIn, in: alone, switches: [:]), "on by its notch, not standing in")
        #expect(!DisplaySwitches.standsIn(builtIn, in: [builtIn, dell], switches: switches), "the Dell is here and on")
        let desk = [dell, lg]
        let allOff = ["dell": false, "lg": false, "gone": true]
        #expect(DisplaySwitches.standsIn(dell, in: desk, switches: allOff), "no notch anywhere: the first display")
        #expect(!DisplaySwitches.standsIn(lg, in: desk, switches: allOff))
        #expect(ScreenSelection.fallback([]) == nil)
    }

    @Test func theChoiceRoundTripsAndIsOffered() {
        #expect(DisplayChoice(rawValue: "selected") == .selected)
        #expect(DisplayChoice.selected.rawValue == "selected")
        #expect(DisplayChoice.fixed.contains(.selected))
    }

    @MainActor @Test func theSwitchesAreKept() {
        let suite = "NotchmeterTests.PanelControls.displays"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = Preferences(defaults: defaults)
        #expect(prefs.displaySwitches.isEmpty)
        prefs.display = .selected
        prefs.displaySwitches["dell"] = true
        let again = Preferences(defaults: defaults)
        #expect(again.display == .selected)
        #expect(again.displaySwitches == ["dell": true])
    }
}

// MARK: - The week on the Cost row

@Suite struct WeekSpendRules {
    init() { Localization.use(language: "en") }

    var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// A provider with one spend a day for the last `count` days, oldest first, `cost(offset)` dollars on the day
    /// `offset` days before today.
    func provider(_ tool: ToolID, now: Date, count: Int = 30, cost: (Int) -> Double) -> ProviderCost {
        let today = utc.startOfDay(for: now)
        let daily = (0..<count).reversed().map { offset in
            DailySpend(day: utc.date(byAdding: .day, value: -offset, to: today)!, cost: cost(offset), tokens: Int(cost(offset) * 1000))
        }
        return ProviderCost(tool: tool, source: .localTranscripts, ranges: [:], daily: daily, scannedAt: now)
    }

    @Test func sevenDaysEndingTodayEachSplitByAssistantInTheCardsOrder() throws {
        let now = t0
        let claude = provider(.claude, now: now) { Double($0 + 1) * 10 }
        let cursor = provider(.cursor, now: now) { $0 == 0 ? 5 : 0 }
        let week = try #require(WeekSpend.of(CostSelection(providers: [claude, cursor]), now: now, calendar: utc))
        #expect(week.days.count == WeekSpend.length)
        #expect(week.days.first?.day == utc.date(byAdding: .day, value: -6, to: utc.startOfDay(for: now)))
        #expect(week.today?.day == utc.startOfDay(for: now))
        #expect(week.today?.parts.map(\.tool) == [.claude, .cursor])
        #expect(week.today?.cost == 15)
        #expect(week.days.first?.parts.map(\.tool) == [.claude], "a day an assistant spent nothing leaves it out")
        let total = 280.0 + 5
        #expect(week.cost == total)
        #expect(week.peak(mode: .cost) == 70)
    }

    @Test func nothingSpentInTheWeekIsNoWeek() {
        let quiet = provider(.claude, now: t0) { $0 >= 7 ? 50 : 0 }
        #expect(WeekSpend.of(CostSelection(providers: [quiet]), now: t0, calendar: utc) == nil)
        #expect(WeekSpend.of(CostSelection(), now: t0, calendar: utc) == nil)
    }

    @Test func theWordsLeadWithTodayAndNameEachDaysSplit() throws {
        let now = t0
        let claude = provider(.claude, now: now) { $0 == 0 ? 118.31 : 20 }
        let cursor = provider(.cursor, now: now) { $0 == 0 ? 13 : 0 }
        let week = try #require(WeekSpend.of(CostSelection(providers: [claude, cursor]), now: now, calendar: utc))
        #expect(week.headline(mode: .cost) == "Today $131 · 7 days $251")
        let today = try #require(week.today)
        #expect(week.line(today, mode: .cost, now: now, calendar: utc) == "today · $131 · Claude Code $118, Cursor $13")
        let first = try #require(week.days.first)
        #expect(!week.line(first, mode: .cost, now: now, calendar: utc).contains("Claude Code"), "one assistant is not split")
        let lines = week.tooltip(mode: .cost, now: now, calendar: utc).split(separator: "\n")
        #expect(lines.count == 2 + WeekSpend.length)
        #expect(lines.first == "Last 7 days")
        #expect(lines[2].hasPrefix("today"), "newest first in the tooltip")
    }

    @Test func tokensModeMeasuresTokens() throws {
        let claude = provider(.claude, now: t0) { $0 == 0 ? 7400 : 1000 }
        let week = try #require(WeekSpend.of(CostSelection(providers: [claude]), now: t0, calendar: utc))
        let today = try #require(week.today)
        #expect(week.value(today, mode: .tokens) == Double(7_400_000))
        #expect(week.value(today, mode: .perMillionTokens) == 7400, "a rate has no height; the bars fall back to dollars")
        #expect(WeekSpend.figure(cost: 0, tokens: 7_400_000, mode: .tokens) == "7.4M")
    }

    /// The bars' token figure is the bare compact count, one width in every language; the sentence form beside
    /// it on the row is the translated one.
    @Test func theTokenFigureIsTheSameInEveryLanguage() throws {
        Localization.use(language: "de")
        defer { Localization.use(language: "en") }
        #expect(Money.tokens(7_400_000) == "7.4 Mio. Tokens", "the row's own figure is translated")
        #expect(WeekSpend.figure(cost: 0, tokens: 7_400_000, mode: .tokens) == "7.4M")
        #expect(WeekSpend.figure(cost: 0, tokens: 20_000, mode: .tokens) == "20K")
        let claude = provider(.claude, now: t0) { $0 == 0 ? 7400 : 1000 }
        let week = try #require(WeekSpend.of(CostSelection(providers: [claude]), now: t0, calendar: utc))
        #expect(week.headline(mode: .tokens) == "Heute 7.4M · 7 Tage 13M")
    }
}
