import Foundation
import Observation
import Testing
@testable import Notchmeter

/// Sessions found without the hook, merged with the hook's (SessionTracker.detected): they appear, they go with
/// their process, the hook always wins, and a working guess never claims a wait or holds the Mac awake.
@Suite struct DetectedSessionMerging {
    init() { Localization.use(language: "en") }

    let t0 = DateParsing.iso8601("2026-09-24T12:00:00Z")!

    func found(_ key: String, tool: ToolID = .claude, exact: Bool = true, project: String? = "notchmeter", busy: Bool = false,
               lastActivity: TimeInterval = -60, busySince: Date? = nil, name: String? = nil, model: String? = nil) -> DetectedSession {
        DetectedSession(key: key, tool: tool, exact: exact, project: project, branch: "main", model: model, name: name,
                        started: t0.addingTimeInterval(-3600), lastActivity: busy ? t0 : t0.addingTimeInterval(lastActivity), busy: busy, busySince: busySince,
                        terminal: TerminalRef(bundleID: "com.apple.Terminal", tty: "/dev/ttys004"))
    }

    func hook(_ event: String, session: String, tool: ToolID = .claude, project: String? = "notchmeter", type: String? = nil) -> Hook.Message {
        Hook.Message(event: event, needsInput: Hook.needsInput(event: event, notificationType: type), sessionID: session, project: project,
                     notificationType: type, tool: tool)
    }

    /// A Claude Cowork task and a process the scan found in the same project are one row, not two: the task's row,
    /// read from its log, accounts for the process-keyed row the way a hook's session does, whichever came first
    /// (0.9.0 added both readers).
    @Test func aCoworkTaskAccountsForAScannedProcessInItsProject() {
        let process = found("detected-40-1", exact: false, project: "Research", busy: true)
        let task = CoworkSessions.Observation(id: "local_1", title: "Compare vendors", project: "Research", lastWrite: t0.addingTimeInterval(-2),
                                              turn: CoworkSessions.Turn(began: t0.addingTimeInterval(-70), end: nil, open: true))
        var tracker = SessionTracker()
        tracker.detected([process], now: t0)
        #expect(tracker.all.count == 1)
        tracker.observeCowork([task], now: t0)
        tracker.detected([process], now: t0.addingTimeInterval(3))
        #expect(tracker.all.count == 1, "one row for the project, the task's")
        #expect(tracker.all.first?.source == .coworkLog)
        var reversed = SessionTracker()
        reversed.observeCowork([task], now: t0)
        reversed.detected([process], now: t0.addingTimeInterval(3))
        #expect(reversed.all.count == 1)
        #expect(reversed.all.first?.source == .coworkLog)
    }

    @Test func aFoundSessionIsARowMarkedDetected() throws {
        var tracker = SessionTracker()
        let change = tracker.detected([found("s1", busy: true, busySince: t0.addingTimeInterval(-40), name: "Fix the card", model: "Opus 5.5")], now: t0)
        #expect(change.added == ["s1"])
        #expect(change.working == ["s1"])
        #expect(change.workingChanged)
        let session = try #require(tracker.all.first)
        #expect(session.source == .detected)
        #expect(session.state == .working(since: t0.addingTimeInterval(-40)), "Claude Code's own status change dates the turn")
        #expect(session.turnStarted == t0.addingTimeInterval(-40))
        #expect(session.displayTitle == "Fix the card")
        #expect(session.model == "Opus 5.5")
        #expect(session.branch == "main")
        #expect(session.terminal?.tty == "/dev/ttys004")
        #expect(tracker.knownCount == nil, "a scan is no hook: nothing is proven about a count")
        #expect(tracker.scanned == ["s1"])
    }

    /// A detected session is working or idle, never waiting: no process signal proves an assistant is holding a
    /// prompt open. And a guess does not keep the Mac out of sleep.
    @Test func aDetectedSessionNeverWaitsAndNeverHoldsTheMacAwake() {
        var tracker = SessionTracker()
        tracker.detected([found("s1", busy: true)], now: t0)
        #expect(tracker.waiting.isEmpty)
        #expect(tracker.working.count == 1)
        #expect(tracker.hookWorking.isEmpty)
        tracker.apply(hook("UserPromptSubmit", session: "hooked"), now: t0)
        #expect(tracker.hookWorking.map(\.id) == ["hooked"])
    }

    /// An idle session quiet for longer than an idle hook session is kept is not news at launch; a working one is.
    @Test func aLongIdleSessionIsNotAddedButAWorkingOneIs() {
        var tracker = SessionTracker()
        let change = tracker.detected([found("old", lastActivity: -SessionTracker.idleAfter - 1), found("busy", busy: true),
                                       found("recent", lastActivity: -120)], now: t0)
        #expect(change.added == ["busy", "recent"])
        #expect(tracker.sessions["old"] == nil)
    }

    @Test func aRowGoesWithItsProcess() {
        var tracker = SessionTracker()
        tracker.detected([found("s1"), found("codex:detected-5-1", tool: .codex, exact: false)], now: t0)
        let change = tracker.detected([found("s1")], now: t0.addingTimeInterval(3))
        #expect(change.removed == ["codex:detected-5-1"])
        #expect(tracker.count == 1)
        #expect(tracker.detected([], now: t0.addingTimeInterval(6)).removed == ["s1"])
        #expect(tracker.count == 0)
        #expect(tracker.scanned.isEmpty)
    }

    /// The hook's first event for a session the scan found takes it over under the same id, keeping its start and
    /// the turn the scan saw running; from then on the scan leaves it alone, whatever it finds.
    @Test func theHooksFirstEventTakesTheRowOver() throws {
        var tracker = SessionTracker()
        tracker.detected([found("s1", busy: true, busySince: t0.addingTimeInterval(-300))], now: t0)
        let outcome = tracker.apply(hook("Stop", session: "s1"), now: t0.addingTimeInterval(10))
        let session = try #require(tracker.sessions["s1"])
        #expect(session.source == .hook)
        #expect(session.started == t0.addingTimeInterval(-3600), "the row is the same session, started when the scan says")
        #expect(outcome.finished?.turn == 310, "the turn the scan saw start ends on the hook's word")
        #expect(!tracker.scanned.contains("s1"))
        // The scan still sees the process, now busy again by its guess: the hook's idle stands.
        tracker.detected([found("s1", busy: true)], now: t0.addingTimeInterval(13))
        #expect(tracker.sessions["s1"]?.state == .idle)
        #expect(tracker.sessions["s1"]?.source == .hook)
        // And the process going does not take the hook's session with it; the hook's SessionEnd or the clock does.
        tracker.detected([], now: t0.addingTimeInterval(16))
        #expect(tracker.sessions["s1"] != nil)
    }

    /// A session the hook reported before the scan found it is the hook's, whatever the scan says of it.
    @Test func aSessionTheHookAlreadyHasIsNotTheScans() {
        var tracker = SessionTracker()
        tracker.apply(hook("UserPromptSubmit", session: "s1"), now: t0)
        let change = tracker.detected([found("s1")], now: t0.addingTimeInterval(3))
        #expect(change.isEmpty)
        #expect(tracker.sessions["s1"]?.isWorking == true)
        #expect(tracker.sessions["s1"]?.source == .hook)
        // Set aside, the hook's session is still the hook's: the scan does not put a detected copy in its place.
        tracker.dismiss("s1")
        #expect(tracker.detected([found("s1", busy: true)], now: t0.addingTimeInterval(6)).isEmpty)
        #expect(tracker.sessions["s1"] == nil)
    }

    /// A session only the status line made (the Welcome flow installs it even when the hook is declined) keeps the
    /// status line's figures and takes the scan's working or idle, since the status line never reports a turn; the
    /// card marks it and offers the hook as for a detected row, and the hook's first event makes it the hook's.
    @Test func aStatusLineRowTakesTheScansStateUntilTheHookSpeaks() throws {
        var tracker = SessionTracker()
        tracker.statusline(sessionID: "s1", project: "notchmeter", model: "Opus", sessionName: "named by Claude", contextUsed: 0.4, now: t0)
        #expect(tracker.sessions["s1"]?.source == .statusline)
        #expect(tracker.sessions["s1"]?.isDetected == true)
        let change = tracker.detected([found("s1", busy: true, busySince: t0.addingTimeInterval(-20), name: "from the transcript", model: "Opus 5.5")],
                                      now: t0.addingTimeInterval(3))
        #expect(change.working == ["s1"] && change.added.isEmpty, "the row was already there; it is working now")
        let session = try #require(tracker.sessions["s1"])
        #expect(session.isWorking && session.turnStarted == t0.addingTimeInterval(-20))
        #expect(session.model == "Opus" && session.contextUsed == 0.4 && session.sessionName == "named by Claude", "the status line's own figures stand")
        #expect(session.source == .statusline)
        #expect(tracker.hookWorking.isEmpty, "a guess does not keep the Mac awake")
        let (rows, _) = SessionsCard.rows(tracker.all, hideTitles: false, jump: false, now: t0.addingTimeInterval(3))
        #expect(rows.first?.detected == true)
        #expect(SessionsCard.upgradeTool(rows, installed: []) == .claude)
        // The hook's first event takes it over, ending the turn the scan saw start.
        let outcome = tracker.apply(hook("Stop", session: "s1"), now: t0.addingTimeInterval(10))
        #expect(tracker.sessions["s1"]?.source == .hook)
        #expect(outcome.finished?.turn == 30)
        #expect(tracker.detected([found("s1", busy: true)], now: t0.addingTimeInterval(13)).isEmpty)
        #expect(tracker.sessions["s1"]?.state == .idle, "from here on the hook's word stands")
        // A status line's row the scan matched to its process goes with the process, like a detected row.
        var lone = SessionTracker()
        lone.statusline(sessionID: "s2", project: "notchmeter", now: t0)
        lone.detected([found("s2", busy: true)], now: t0.addingTimeInterval(3))
        #expect(lone.detected([], now: t0.addingTimeInterval(6)).removed == ["s2"])
    }

    /// Claude Code sends `SessionEnd` while its process and session file are still there, so a scan inside that
    /// window finds the ended session again; it is left alone for `endedGrace`, unless a session file started
    /// after the end says a new session has the same id.
    @Test func aSessionEndIsNotUndoneByTheNextScan() {
        var tracker = SessionTracker()
        tracker.apply(hook("UserPromptSubmit", session: "s1"), now: t0)
        tracker.apply(hook("SessionEnd", session: "s1"), now: t0.addingTimeInterval(10))
        #expect(tracker.count == 0)
        #expect(tracker.detected([found("s1", busy: true)], now: t0.addingTimeInterval(11)).isEmpty, "the process on its way out is not a new row")
        #expect(tracker.sessions["s1"] == nil)
        let resumed = DetectedSession(key: "s1", tool: .claude, exact: true, project: "notchmeter", started: t0.addingTimeInterval(12),
                                      lastActivity: t0.addingTimeInterval(13), busy: true)
        #expect(tracker.detected([resumed], now: t0.addingTimeInterval(13)).added == ["s1"], "a file started after the end is a new session")
        var later = SessionTracker()
        later.apply(hook("SessionEnd", session: "s2"), now: t0)
        later.expire(now: t0.addingTimeInterval(SessionTracker.endedGrace))
        #expect(later.ended.isEmpty, "the grace is pruned with the rest")
        #expect(later.detected([found("s2", busy: true)], now: t0.addingTimeInterval(SessionTracker.endedGrace)).added == ["s2"])
    }

    /// A hook session set aside by the clock is proof of nothing: Cursor and Codex send no end when a chat is
    /// closed, and a dead one that still accounted for a process hid a live cursor-agent in the same project for
    /// four hours. One set aside by the user, or working, still accounts for its process inside `idleAfter`.
    @Test func aHookSessionSetAsideByTheClockNoLongerAccountsForAProcess() {
        var tracker = SessionTracker()
        tracker.apply(hook("Stop", session: "conv-1", tool: .cursor), now: t0)
        let process = found("cursor:detected-9-1", tool: .cursor, exact: false, busy: true)
        #expect(tracker.detected([process], now: t0.addingTimeInterval(3)).isEmpty, "the live hook session accounts for the process")
        tracker.expire(now: t0.addingTimeInterval(SessionTracker.idleAfter))
        #expect(tracker.sessions["cursor:conv-1"] == nil && tracker.dismissed["cursor:conv-1"] != nil)
        #expect(tracker.detected([process], now: t0.addingTimeInterval(SessionTracker.idleAfter + 3)).added == ["cursor:detected-9-1"])
        // Removed by hand while working, a hook session still accounts for its process: the row does not come back
        // as a detected twin the moment it is removed.
        var removed = SessionTracker()
        removed.apply(hook("UserPromptSubmit", session: "conv-2", tool: .cursor), now: t0)
        removed.dismiss("cursor:conv-2")
        #expect(removed.detected([process], now: t0.addingTimeInterval(3)).isEmpty)
    }

    /// A process-keyed row cannot be matched by id, so each hook session of the same assistant and project accounts
    /// for one process, the busiest first; only the rest are rows. Two Codex sessions in one repository, one of them
    /// reporting through the hook, are one hook row and one detected row.
    @Test func aHookSessionAccountsForOneProcessOfItsProject() {
        var tracker = SessionTracker()
        tracker.apply(hook("UserPromptSubmit", session: "thread-1", tool: .codex), now: t0)
        let codex = [found("codex:detected-5-1", tool: .codex, exact: false, busy: true),
                     found("codex:detected-6-1", tool: .codex, exact: false, lastActivity: -30),
                     found("codex:detected-7-1", tool: .codex, exact: false, project: "scout", lastActivity: -30)]
        let change = tracker.detected(codex, now: t0)
        #expect(change.added == ["codex:detected-6-1", "codex:detected-7-1"], "the busy process is the one the hook is hearing from")
        #expect(tracker.only(.codex).count == 3)
    }

    /// A new hook session takes its project's process-keyed twin off at once, rather than both rows standing until
    /// the next scan.
    @Test func aNewHookSessionTakesItsTwinOffAtOnce() {
        var tracker = SessionTracker()
        tracker.detected([found("cursor:detected-9-1", tool: .cursor, exact: false, busy: true),
                          found("cursor:detected-10-1", tool: .cursor, exact: false, project: "scout", busy: true)], now: t0)
        tracker.apply(hook("UserPromptSubmit", session: "conv-1", tool: .cursor), now: t0.addingTimeInterval(1))
        #expect(tracker.sessions["cursor:detected-9-1"] == nil)
        #expect(tracker.sessions["cursor:detected-10-1"] != nil, "another project's process is not this session")
        #expect(!tracker.scanned.contains("cursor:detected-9-1"))
        // The next scan agrees: the hook's session still accounts for that process.
        let change = tracker.detected([found("cursor:detected-9-1", tool: .cursor, exact: false, busy: true),
                                       found("cursor:detected-10-1", tool: .cursor, exact: false, project: "scout", busy: true)], now: t0.addingTimeInterval(3))
        #expect(change.added.isEmpty && change.removed.isEmpty)
    }

    @Test func theHooksSessionEndTakesADetectedRowOff() {
        var tracker = SessionTracker()
        tracker.detected([found("s1", busy: true)], now: t0)
        tracker.apply(hook("SessionEnd", session: "s1"), now: t0.addingTimeInterval(1))
        #expect(tracker.count == 0)
        #expect(tracker.scanned.isEmpty)
    }

    /// Removed mid-turn, a detected row stays off for the rest of that turn and comes back with the next, the way a
    /// removed hook session comes back with its next event; removed idle, it comes back on any sign of life since.
    @Test func aRemovedRowComesBackWithItsNextTurn() {
        var tracker = SessionTracker()
        tracker.detected([found("s1", busy: true)], now: t0)
        #expect(tracker.dismiss("s1").removed)
        #expect(tracker.detected([found("s1", busy: true)], now: t0.addingTimeInterval(3)).isEmpty, "still the turn it was removed in")
        #expect(tracker.sessions["s1"] == nil)
        tracker.detected([found("s1", lastActivity: 5)], now: t0.addingTimeInterval(6))
        #expect(tracker.sessions["s1"] == nil, "the turn ended; it stays off until the next")
        let back = tracker.detected([found("s1", busy: true)], now: t0.addingTimeInterval(9))
        #expect(back.added == ["s1"])
        #expect(tracker.sessions["s1"]?.isWorking == true)

        var idle = SessionTracker()
        idle.detected([found("s2", lastActivity: -60)], now: t0)
        idle.dismiss("s2")
        #expect(idle.detected([found("s2", lastActivity: -60)], now: t0.addingTimeInterval(3)).isEmpty)
        #expect(idle.detected([found("s2", lastActivity: 2)], now: t0.addingTimeInterval(6)).added == ["s2"])
    }

    /// A working row's clock moves at most once a minute, so a scan every three seconds that finds nothing new
    /// leaves the tracker equal and the store publishes nothing.
    @Test func aScanThatFindsNothingNewChangesNothing() {
        var tracker = SessionTracker()
        tracker.detected([found("s1", busy: true)], now: t0)
        let before = tracker
        var later = found("s1", busy: true)
        later.lastActivity = t0.addingTimeInterval(3)
        #expect(tracker.detected([later], now: t0.addingTimeInterval(3)).isEmpty)
        #expect(tracker == before)
        var idle = SessionTracker()
        idle.detected([found("s2", lastActivity: -90)], now: t0)
        let idleBefore = idle
        idle.detected([found("s2", lastActivity: -90)], now: t0.addingTimeInterval(3))
        #expect(idle == idleBefore)
    }

    /// The status line's name for the model is Claude Code's own; the scan's reading of the transcript does not
    /// write over it, so the row does not alternate between two spellings of one model.
    @Test func theStatusLinesModelOutranksTheScans() {
        var tracker = SessionTracker()
        tracker.detected([found("s1", busy: true, model: "Opus 5.5")], now: t0)
        #expect(tracker.sessions["s1"]?.model == "Opus 5.5")
        tracker.statusline(sessionID: "s1", project: "notchmeter", model: "Opus", contextUsed: 0.4, now: t0.addingTimeInterval(1))
        tracker.detected([found("s1", busy: true, model: "Opus 5.5")], now: t0.addingTimeInterval(3))
        #expect(tracker.sessions["s1"]?.model == "Opus")
        #expect(tracker.sessions["s1"]?.source == .detected, "the status line reports figures, not turns")
        #expect(tracker.sessions["s1"]?.contextUsed == 0.4)
    }

    @Test func turningTitlesOffDropsADetectedNameAndTheScanDoesNotBringItBack() {
        var tracker = SessionTracker()
        tracker.detected([found("s1", name: "Fix the card")], now: t0)
        tracker.clearTitles()
        tracker.detected([found("s1")], now: t0.addingTimeInterval(3))
        #expect(tracker.sessions["s1"]?.displayTitle == nil)
    }

    /// Aged out like an idle hook session, a detected one is set aside and not put back by a scan that finds it no
    /// busier than before.
    @Test func anIdleDetectedRowAgesOutAndStaysOut() {
        var tracker = SessionTracker()
        tracker.detected([found("s1", lastActivity: -60)], now: t0)
        let later = t0.addingTimeInterval(SessionTracker.idleAfter)
        tracker.expire(now: later)
        #expect(tracker.sessions["s1"] == nil)
        #expect(tracker.detected([found("s1", lastActivity: -60)], now: later.addingTimeInterval(3)).isEmpty)
        #expect(tracker.sessions["s1"] == nil)
    }
}

/// The store's half: a scan's rows reach the tracker without republishing an unchanged one, the awake assertion
/// ignores them, and the card and the report say where each session came from.
@MainActor @Suite struct DetectedSessionsInTheStore {
    let t0 = DateParsing.iso8601("2026-09-24T12:00:00Z")!

    func store(_ suite: String) -> (UsageStore, UserDefaults) {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let prefs = Preferences(defaults: defaults)
        let store = UsageStore(prefs: prefs, providers: [], cache: ReadingCache(defaults: defaults), defaults: defaults,
                               drainLog: nil, reportFile: nil)
        return (store, defaults)
    }

    func found(_ key: String, busy: Bool = true) -> DetectedSession {
        DetectedSession(key: key, tool: .claude, exact: true, project: "notchmeter", started: t0.addingTimeInterval(-600),
                        lastActivity: busy ? t0 : t0.addingTimeInterval(-60), busy: busy)
    }

    @Test func aScanPublishesOnlyWhenItChangesSomething() {
        let suite = "NotchmeterTests.DetectedSessions.publish"
        let (store, defaults) = store(suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        func publishes(_ body: () -> Void) -> Int {
            var fired = 0
            withObservationTracking { _ = store.sessions } onChange: { fired += 1 }
            body()
            return fired
        }
        let once = 1
        let none = 0
        #expect(publishes { store.detectionReceived([found("s1")], now: t0) } == once)
        #expect(publishes { store.detectionReceived([found("s1")], now: t0.addingTimeInterval(3)) } == none)
        #expect(store.sessions.count == 1)
    }

    @Test func keepAwakeHoldsForTheHooksWorkOnly() {
        let suite = "NotchmeterTests.DetectedSessions.awake"
        let (store, defaults) = store(suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        store.prefs.keepAwake = true
        store.setOnBattery(false)
        store.detectionReceived([found("s1")], now: t0)
        store.applyAwake()
        #expect(!store.keepingAwake, "a guess does not keep the Mac out of sleep")
        store.hookReceived(Hook.Message(event: "UserPromptSubmit", needsInput: false, sessionID: "s1", project: "notchmeter"), now: t0.addingTimeInterval(1))
        #expect(store.keepingAwake, "the hook's turn does")
    }

    @Test func turningTheScanOffTakesItsRowsOff() {
        let suite = "NotchmeterTests.DetectedSessions.off"
        let (store, defaults) = store(suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        store.detectionReceived([found("s1")], now: t0)
        store.detectionReceived([], running: false, now: t0.addingTimeInterval(3))
        #expect(store.sessions.count == 0)
        #expect(store.detectionInterval() == SessionDetection.discoveryInterval)
    }

    @Test func theOracleHearsIdsOnly() {
        let fields = UsageStore.detectionFields(added: ["s1"], removed: [], working: ["s1"], adopted: ["s0"])
        #expect(Set(fields.keys) == ["added", "removed", "working", "adopted"])
        #expect(fields["adopted"] as? [String] == ["s0"])
    }

    /// The card marks a detected row, carries its model, reports its source to the oracle, and offers the hook for
    /// the first detected row whose assistant has none.
    @Test func theCardMarksADetectedRowAndOffersTheHook() throws {
        var tracker = SessionTracker()
        var withModel = found("s1")
        withModel.model = "Opus 5.5"
        tracker.detected([withModel], now: t0)
        tracker.apply(Hook.Message(event: "UserPromptSubmit", needsInput: false, sessionID: "hooked", project: "scout"), now: t0)
        let (rows, _) = SessionsCard.rows(tracker.all, hideTitles: false, jump: false, now: t0)
        let detected = try #require(rows.first { $0.id == "s1" })
        #expect(detected.detected)
        #expect(detected.model == "Opus 5.5")
        #expect(rows.first { $0.id == "hooked" }?.detected == false)
        let oracle = SessionsCard.oracleRows(SessionsCard.groups(rows, sessions: tracker.all))
        #expect(Set(oracle.compactMap { $0["source"] as? String }) == ["hook", "detected"])
        #expect(SessionsCard.upgradeTool(rows, installed: []) == .claude)
        #expect(SessionsCard.upgradeTool(rows, installed: [.claude]) == nil, "a hook already in the file needs no offer")
        #expect(SessionsCard.upgradeTool(rows.filter { !$0.detected }, installed: []) == nil)
        // A status line's row is marked like a detected one, and the oracle says which it is.
        tracker.statusline(sessionID: "lined", project: "scout", now: t0)
        let (withLined, _) = SessionsCard.rows(tracker.all, hideTitles: false, jump: false, now: t0)
        #expect(withLined.first { $0.id == "lined" }?.detected == true)
        let lined = SessionsCard.oracleRows(SessionsCard.groups(withLined, sessions: tracker.all)).first { $0["id"] as? String == "lined" }
        #expect(lined?["source"] as? String == "statusline")
    }

    @Test func theReportSaysWhereEachSessionCameFrom() throws {
        var tracker = SessionTracker()
        tracker.detected([found("s1")], now: t0)
        tracker.apply(Hook.Message(event: "SessionStart", needsInput: false, sessionID: "hooked", project: "scout"), now: t0)
        tracker.statusline(sessionID: "lined", project: "scout", now: t0)
        let report = UsageReport(tools: [:], order: ToolID.allCases, cost: nil, advice: [], sessions: tracker.all, now: t0)
        let sessions = try #require(report.object["sessions"] as? [[String: Any]])
        #expect(Set(sessions.compactMap { $0["source"] as? String }) == ["hook", "detected", "statusline"])
    }

    /// A detected Cursor row is keyed by its process, which names no conversation to look a chat name up by.
    @Test func aDetectedCursorRowIsNeverLookedUpAsAChat() {
        var session = AgentSession(id: "cursor:detected-9-1", tool: .cursor, project: "notchmeter", state: .idle, started: t0, lastEvent: t0, turnStarted: nil)
        session.source = .detected
        #expect(CursorChatNames.conversationID(of: session) == nil)
    }
}
