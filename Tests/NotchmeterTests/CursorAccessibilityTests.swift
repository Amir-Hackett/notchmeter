import Foundation
import Testing
@testable import Notchmeter

/// Cursor's own cards read from a snapshot of its Accessibility tree: recognised by their buttons, never pressed
/// on a guess, and put on the right session. The trees are built by hand in the shape Cursor 3.23's chat panel
/// has (a group holding the card's words and its buttons, each button's title carrying its shortcut glyphs).
@Suite struct CursorCardDetection {
    func button(_ title: String, enabled: Bool = true) -> CursorAXNode { CursorAXNode(role: "AXButton", label: title, enabled: enabled) }
    func text(_ value: String) -> CursorAXNode { CursorAXNode(role: "AXStaticText", label: value) }
    func group(_ children: [CursorAXNode]) -> CursorAXNode { CursorAXNode(role: "AXGroup", label: nil, children: children) }

    @Test func theModeSwitchCardIsReadWithCursorsThreeOptions() throws {
        let card = group([text("Switch to Plan Mode?"), text("This needs an implementation-ready architecture"),
                          button("Always ask"), button("Skip"), button("Switch ⌘⏎")])
        let window = group([group([button("New Chat")]), card])
        let found = CursorCards.detect(in: window, title: "plan.md — enrollhere")
        #expect(found.count == 1)
        let mode = try #require(found.first)
        #expect(mode.kind == .modeSwitch)
        #expect(mode.heading == "Switch to Plan Mode?")
        #expect(mode.options.map(\.label) == ["Always ask", "Skip", "Switch"], "Cursor's own words and order, the shortcut dropped")
        #expect(mode.options.last?.path == [1, 4])
        #expect(mode.blocksTurn)
    }

    @Test func thePlanCardAndTheRunCardAreTold() throws {
        let plan = group([text("Created Plan"), text("NBSCTe holiday IVR"), text("On NB Screener…"), button("View Plan"), button("Build ⌘⏎"), button("")])
        let run = group([text("npm run deploy -- --prod"), button("Skip"), button("Run ⌘⏎")])
        let found = CursorCards.detect(in: group([plan, run]), title: "enrollhere")
        let kinds = Dictionary(uniqueKeysWithValues: found.map { ($0.kind, $0) })
        #expect(kinds[.plan]?.heading == "NBSCTe holiday IVR")
        #expect(kinds[.plan]?.options.map(\.label) == ["View Plan", "Build"])
        #expect(kinds[.plan]?.blocksTurn == false, "a plan waits for nobody")
        #expect(kinds[.run]?.heading == "npm run deploy -- --prod")
        #expect(kinds[.run]?.options.map(\.label) == ["Skip", "Run"])
    }

    @Test func aButtonBelongsToOneCardAndAStrayRunMakesNone() {
        // The mode card's Skip must not pair with an unrelated Run elsewhere in the window to invent a run card.
        let mode = group([text("Switch to Ask Mode?"), button("Skip"), button("Switch")])
        let window = group([mode, group([button("Run")])])
        let found = CursorCards.detect(in: window, title: "w")
        #expect(found.map(\.kind) == [.modeSwitch])
        #expect(CursorCards.detect(in: group([button("Run"), text("x")]), title: "w").isEmpty, "Run alone is not a card")
    }

    @Test func aDisabledButtonIsNotOffered() throws {
        let card = group([text("ls"), button("Skip"), button("Run", enabled: false)])
        let found = try #require(CursorCards.detect(in: card, title: "w").first)
        #expect(found.options.map(\.label) == ["Skip"])
    }

    @Test func theSameCardKeepsItsIDAndTheNextOneDoesNot() throws {
        let a = try #require(CursorCards.detect(in: group([text("ls"), button("Skip"), button("Run")]), title: "w").first)
        let again = try #require(CursorCards.detect(in: group([text("ls"), button("Skip"), button("Run")]), title: "w").first)
        let other = try #require(CursorCards.detect(in: group([text("rm x"), button("Skip"), button("Run")]), title: "w").first)
        #expect(a.id == again.id)
        #expect(a.id != other.id, "a press re-reads the card and refuses when it is no longer the same one")
    }

    @Test func headingsAreBounded() throws {
        let long = String(repeating: "a", count: 500) + "\nsecond line"
        let card = try #require(CursorCards.detect(in: group([text(long), button("Skip"), button("Run")]), title: "w").first)
        #expect((card.heading?.count ?? 0) <= CursorCards.headingLimit + 1)
        #expect(card.heading?.contains("second") == false)
    }

    @Test func normalizationDropsShortcutGlyphs() {
        #expect(CursorCards.normalized("Switch ⌘⏎") == "Switch")
        #expect(CursorCards.normalized("  Run   ⌥⌘↩︎ ") == "Run")
        #expect(CursorCards.normalized("⌘") == nil)
        #expect(CursorCards.normalized(nil) == nil)
    }

    @Test func aWindowIsMatchedToItsSession() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        func session(_ id: String, _ project: String?, _ last: TimeInterval, tool: ToolID = .cursor, host: String? = nil) -> AgentSession {
            AgentSession(id: id, tool: tool, project: project, state: .working(since: t0), started: t0, lastEvent: t0.addingTimeInterval(last), turnStarted: t0, host: host)
        }
        let sessions = [session("a", "enrollhere", 1), session("b", "enrollhere", 5), session("c", "notchmeter", 9), session("d", "enrollhere", 20, tool: .claude)]
        #expect(CursorCards.session(for: "plan.md — enrollhere", among: sessions) == "b", "the most recent of the workspace's chats")
        #expect(CursorCards.session(for: "notchmeter", among: sessions) == "c")
        #expect(CursorCards.session(for: "elsewhere", among: sessions) == nil, "several chats and no name: no guess")
        #expect(CursorCards.session(for: "elsewhere", among: [session("a", nil, 1)]) == "a", "the only Cursor chat there is")
        #expect(CursorCards.session(for: "x", among: [session("r", "x", 1, host: "devbox")]) == nil, "a remote chat's window is not on this Mac")
    }

    @Test func buildFindsOnlyAnUnambiguousPlanCard() {
        func plan(_ name: String) -> CursorCard { CursorCard(kind: .plan, window: "w", heading: name, options: [.init(label: "Build", path: [0])]) }
        #expect(CursorCards.planCard(named: "A", in: [plan("A"), plan("B")])?.heading == "A")
        #expect(CursorCards.planCard(named: "C", in: [plan("A"), plan("B")]) == nil, "two plans and neither is this one: nothing is pressed")
        #expect(CursorCards.planCard(named: nil, in: [plan("A")])?.heading == "A")
    }
}

/// The tracker's side: a card proves a wait, a held command is a request, and a plan's state follows its tasks.
@Suite struct CursorControlTracking {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let key = SessionTracker.key(tool: .cursor, session: "c1", host: nil)

    func started() -> SessionTracker {
        var tracker = SessionTracker()
        _ = tracker.apply(Hook.Message(event: "UserPromptSubmit", needsInput: false, sessionID: "c1", project: "proj", tool: .cursor), now: t0)
        return tracker
    }

    @Test func aCardLightsTheWaitAndItsGoingOrTheNextSignOfLifeEndsIt() throws {
        var tracker = started()
        let shown = tracker.cursorCardShown(key, now: t0.addingTimeInterval(5))
        #expect(shown != nil)
        #expect(tracker.sessions[key]?.isWaiting == true)
        let repeated = tracker.cursorCardShown(key, now: t0.addingTimeInterval(6))
        #expect(repeated == nil, "the same wait is announced once")
        let gone = tracker.cursorCardGone(key, now: t0.addingTimeInterval(7))
        #expect(gone)
        #expect(tracker.sessions[key]?.isWorking == true)

        _ = tracker.cursorCardShown(key, now: t0.addingTimeInterval(8))
        let alarms = tracker.sessions[key]?.quietFalseAlarms
        _ = tracker.apply(Hook.Message(event: "afterAgentThought", needsInput: false, sessionID: "c1", tool: .cursor), now: t0.addingTimeInterval(9))
        #expect(tracker.sessions[key]?.isWorking == true)
        #expect(tracker.sessions[key]?.quietFalseAlarms == alarms, "a wait the card proved is no false alarm")
        #expect(tracker.sessions[key]?.cardWait == false)
    }

    @Test func aHeldCommandIsARequestNotASignOfLife() throws {
        var tracker = started()
        var held = Hook.Message(event: "beforeShellExecution", needsInput: true, sessionID: "c1", tool: .cursor)
        held.request = Hook.Request(id: "r1", kind: .permission(tool: "Shell", summary: "Run ls", detail: nil, suggestions: []))
        let outcome = tracker.apply(held, now: t0.addingTimeInterval(1))
        #expect(outcome.requested?.request.id == "r1")
        #expect(tracker.sessions[key]?.pending?.id == "r1")
        #expect(tracker.sessions[key]?.isWaiting == true)
        let card = tracker.cursorCardShown(key, now: t0.addingTimeInterval(2))
        #expect(card == nil, "a request the notch holds is not also a card wait")
    }

    @Test func aPlanIsReadyThenBuildingThenDone() {
        func plan(_ statuses: [TodoPlan.Status]) -> TodoPlan {
            TodoPlan(items: statuses.enumerated().map { TodoPlan.Item(id: "\($0.offset)", content: "t", status: $0.element) })
        }
        #expect(CursorPlanState.of(plan([.pending, .pending]), built: false) == .ready)
        #expect(CursorPlanState.of(plan([.pending, .pending]), built: true) == .building)
        #expect(CursorPlanState.of(plan([.inProgress, .pending]), built: false) == .building, "a task started is a build, whoever pressed it")
        #expect(CursorPlanState.of(plan([.completed, .cancelled]), built: true) == .completed, "cancelled is out of the count")
        #expect(CursorPlanState.of(plan([.cancelled, .cancelled]), built: false) == .cancelled)
        #expect(CursorPlanState.of(plan([.completed, .blocked]), built: true) == .building, "blocked is still outstanding")
        #expect(CursorPlanState.of(nil, built: false) == .ready)
    }

    @Test func aBuildPromptMarksThePlanBuiltAndANewPlanStartsOver() {
        var tracker = started()
        var build = Hook.Message(event: "UserPromptSubmit", needsInput: false, sessionID: "c1", tool: .cursor)
        build.planFile = "/p/a.plan.md"
        _ = tracker.apply(build, now: t0.addingTimeInterval(1))
        #expect(tracker.sessions[key]?.planBuilt == true)
        var listed = Hook.Message(event: "PostToolUse", needsInput: false, sessionID: "c1", tool: .cursor)
        listed.planFile = "/p/b.plan.md"
        _ = tracker.apply(listed, now: t0.addingTimeInterval(2))
        #expect(tracker.sessions[key]?.planFile == "/p/b.plan.md")
        #expect(tracker.sessions[key]?.planBuilt == false, "another plan has not been built")
    }

    @Test func modeAndBackgroundReachTheRow() throws {
        var tracker = SessionTracker()
        var start = Hook.Message(event: "SessionStart", needsInput: false, sessionID: "c1", project: "proj", tool: .cursor)
        start.composerMode = "plan"
        start.background = true
        _ = tracker.apply(start, now: t0)
        let rows = SessionsCard.rows(tracker.all, hideTitles: false, jump: false, now: t0).rows
        let row = try #require(rows.first)
        #expect(row.mode == "plan")
        #expect(row.background)
        start.composerMode = "agent"
        _ = tracker.apply(start, now: t0)
        #expect(SessionsCard.rows(tracker.all, hideTitles: false, jump: false, now: t0).rows.first?.mode == nil, "plain Agent mode needs no chip")
    }
}

/// Where each Cursor feature comes from, feature by feature.
@Suite struct CursorCapabilityReport {
    @Test func eachFeatureFallsBackOnItsOwn() {
        var inputs = CursorCapabilities.Inputs()
        inputs.version = "3.23.12"
        inputs.hookInstalled = true
        inputs.hookCurrent = true
        func source(_ feature: String) -> CursorCapabilities.Source? { CursorCapabilities.entries(inputs).first { $0.feature == feature }?.source }
        #expect(source("sessions") == .hook)
        #expect(source("plans and tasks") == .localData)
        #expect(source("run approval") == .openOnly)
        #expect(source("build") == .openOnly)
        inputs.mirrorCards = true
        #expect(source("build") == .openOnly, "the switch alone is not the permission")
        inputs.trusted = true
        #expect(source("build") == .accessibility)
        #expect(source("run approval") == .accessibility)
        inputs.requireApproval = true
        #expect(source("run approval") == .hook)
        inputs.hookCurrent = false
        #expect(source("run approval") == .accessibility, "an out-of-date hook cannot hold a call")
        inputs.readsSessions = false
        #expect(CursorCapabilities.entries(inputs).map(\.source) == [.unavailable])
        #expect(CursorCapabilities.line(CursorCapabilities.Inputs()).hasPrefix("Cursor not installed: "))
    }
}

/// Cursor's numbers read safely: a malformed value is no value, never a trap, a negative count or a misread sign.
@Suite struct CursorNumberValidation {
    @Test func countsAreWholeFiniteAndNonNegative() {
        #expect(JSON.count(42) == 42)
        #expect(JSON.count(42.9) == 42)
        #expect(JSON.count("17") == 17)
        #expect(JSON.count(-1) == nil)
        #expect(JSON.count(1e300) == nil, "Int(1e300) would trap the app")
        #expect(JSON.count(Double.nan) == nil)
        #expect(JSON.count(Double.infinity) == nil)
        #expect(JSON.count("12abc") == nil)
        #expect(JSON.count(nil) == nil)
    }

    @Test func moneyKeepsItsSignAndItsDigits() {
        #expect(JSON.money("$0.05") == 0.05)
        #expect(JSON.money("$1,234.56") == 1234.56)
        #expect(JSON.money("-$0.05") == -0.05, "a refund stays a refund")
        #expect(JSON.money("0.05 (included)") == 0.05)
        #expect(JSON.money("-") == nil)
        #expect(JSON.money("1.2.3") == nil, "two decimal points are no number")
        #expect(JSON.money("") == nil)
    }

    @Test func eventTimesOutsideAnyPossibleCursorEventAreDropped() {
        #expect(CursorProvider.eventDate(1_756_728_000_000) == Date(timeIntervalSince1970: 1_756_728_000), "milliseconds")
        #expect(CursorProvider.eventDate(1_756_728_000) == Date(timeIntervalSince1970: 1_756_728_000), "seconds")
        #expect(CursorProvider.eventDate(0) == nil)
        #expect(CursorProvider.eventDate(-5) == nil)
        #expect(CursorProvider.eventDate(.infinity) == nil)
        #expect(CursorProvider.eventDate(86_400) == nil, "1970 is no Cursor event")
        #expect(CursorProvider.eventDate(9_999_999_999_999) == nil, "2286 is no Cursor event either")
    }

    @Test func aMalformedEventRowNeitherTrapsNorGoesNegative() {
        let json = #"{"usageEventsDisplay":[{"timestamp":"1756728000000","model":"m","tokenUsage":{"inputTokens":1e300,"outputTokens":-4,"cacheReadTokens":"12","totalCents":"x"}},{"timestamp":"1756728000000","model":"m","usageBasedCosts":"-$0.25"}]}"#
        let page = CursorProvider.parseUsageEvents(Data(json.utf8))
        #expect(page.events.count == 2)
        #expect(page.events[0].tokens.input == 0)
        #expect(page.events[0].tokens.output == 0)
        #expect(page.events[0].tokens.cacheRead == 12)
        #expect(page.events[0].costUSD == 0)
        #expect(page.events[1].costUSD == -0.25)
    }
}
