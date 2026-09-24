import AppKit
import SwiftUI
import Testing
@testable import Notchmeter

/// The card the panel shows for a request: what the excerpt's lines are tinted, how a question's choices become
/// the answer the hook prints, and that the card fits the panel's column with a long excerpt held to its frame.
@Suite struct PromptCardRules {
    let t0 = DateParsing.iso8601("2026-09-01T12:00:00Z")!

    func session(_ pending: PendingRequest? = nil, title: String? = nil, terminal: TerminalRef? = nil, state: AgentSession.State = .waiting(since: Date())) -> AgentSession {
        var session = AgentSession(id: "s", project: "notchmeter", state: state, started: t0, lastEvent: t0, turnStarted: t0, branch: "feat/two-way")
        session.pending = pending
        session.title = title
        session.terminal = terminal
        return session
    }

    @Test func anEditsLinesAreTintedByTheirSign() {
        let lines = PromptCard.lines(of: "- let a = 1\n+ let a = 2\n  context\n-not a removal\n")
        #expect(lines.map(\.tint) == [.removed, .added, .plain, .plain, .plain])
        #expect(lines.map(\.text) == ["- let a = 1", "+ let a = 2", "  context", "-not a removal", ""])
        let long = (1...400).map { "line \($0)" }.joined(separator: "\n")
        #expect(PromptCard.lines(of: long).count == PromptCard.detailLineCap)
        #expect(PromptCard.detailLinesShown == 8)
        #expect(PromptCard.detailFrameHeight == 120)
    }

    @Test func theAnswerNamesEachQuestionByItsTextAndJoinsAMultiSelect() {
        let questions = [
            PendingRequest.Question(text: "Which layout?", header: "Layout", options: [.init(label: "Rows"), .init(label: "Grid")]),
            PendingRequest.Question(text: "Which colours?", options: [.init(label: "Red"), .init(label: "Green"), .init(label: "Blue")], multiSelect: true),
            PendingRequest.Question(text: "Skipped?", options: [.init(label: "Yes")]),
        ]
        let answers = PromptCard.answers(questions: questions, chosen: [0: [1], 1: [2, 0], 2: [7]])
        #expect(answers == ["Which layout?": "Grid", "Which colours?": "Red, Blue"], "a choice outside the options is not an answer, and a question with none is left out")
        #expect(PromptCard.answers(questions: questions, chosen: [:]).isEmpty)
    }

    /// The card is offered the panel's column and comes out exactly that wide, at either panel width, for a
    /// permission with a long excerpt and for a question; a long excerpt scrolls inside its frame rather than
    /// growing the card past the panel's cap.
    @MainActor @Test func theCardFitsTheColumnAndALongExcerptIsHeldToItsFrame() {
        let short = PendingRequest(id: "r1", kind: .permission(tool: "Bash", summary: "swift build", detail: "swift build", suggestions: ["swift build:*"]), since: t0)
        let long = PendingRequest(id: "r2", kind: .permission(tool: "Write", summary: "/tmp/x.swift", detail: (1...60).map { "+ line \($0)" }.joined(separator: "\n"), suggestions: []), since: t0)
        let question = PendingRequest(id: "r3", kind: .question([
            PendingRequest.Question(text: "Where should the card go?", header: "Layout", options: [
                .init(label: "Under the advice", description: "Between the strip and the tool cards"),
                .init(label: "Above the cost", description: "First on the panel"),
            ]),
        ]), since: t0)
        for width in PanelWidth.allCases {
            let column = width.points - 2 * NotchExpandedView.contentHorizontalPadding
            let shortSize = size(of: short, width: column)
            let longSize = size(of: long, width: column)
            let questionSize = size(of: question, width: column)
            #expect(shortSize.width == column, "\(width): a short card is exactly the column")
            #expect(longSize.width == column, "\(width): a long excerpt does not widen the card")
            #expect(questionSize.width == column, "\(width): a question is exactly the column")
            let eightLinesOrSo = PromptCard.detailFrameHeight + 200
            #expect(longSize.height - shortSize.height < eightLinesOrSo, "\(width): sixty lines of excerpt are held to the \(Int(PromptCard.detailFrameHeight)) pt frame")
            #expect(longSize.height > shortSize.height)
        }
    }

    @MainActor private func size(of request: PendingRequest, width: CGFloat) -> CGSize {
        let host = NSHostingView(rootView: PromptCard(session: session(request), request: request)
            .frame(width: width)
            .environment(\.density, .comfortable))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }
}

/// The Sessions card's rows: the title's fallbacks, the chips, the clock, the second line, the cap and the
/// jump rule; pure over sessions, so the panel picture cannot drift from the rule.
@Suite struct SessionsCardRows {
    let t0 = DateParsing.iso8601("2026-09-01T12:00:00Z")!
    let iterm = TerminalRef(program: "iTerm.app", bundleID: "com.googlecode.iterm2", tty: "/dev/ttys004")

    func make(_ id: String, tool: ToolID = .claude, project: String? = "notchmeter", branch: String? = "main", title: String? = nil,
              terminal: TerminalRef? = nil, host: String? = nil, state: AgentSession.State = .idle, turnStarted: Date? = nil,
              pending: PendingRequest? = nil, finished: ToolSignal.Finish? = nil, lastEvent: Date? = nil) -> AgentSession {
        var session = AgentSession(id: id, tool: tool, project: project, state: state, started: t0, lastEvent: lastEvent ?? t0, turnStarted: turnStarted, branch: branch, host: host)
        session.title = title
        session.terminal = terminal
        session.pending = pending
        session.finished = finished
        return session
    }

    /// The branch has its own line under the title since the rows grew, so the fallback title is the project alone.
    @Test func theTitleIsThePromptThenThePlaceThenTheAssistant() {
        #expect(SessionsCard.title(of: make("a", title: "Fix the tests"), hideTitles: false) == "Fix the tests")
        #expect(SessionsCard.title(of: make("a", title: "Fix the tests"), hideTitles: true) == "notchmeter", "a shared screen never shows the prompt")
        #expect(SessionsCard.title(of: make("a"), hideTitles: false) == "notchmeter")
        #expect(SessionsCard.title(of: make("a", branch: nil), hideTitles: false) == "notchmeter")
        #expect(SessionsCard.title(of: make("a", project: nil, branch: nil, host: "devbox"), hideTitles: false) == "@devbox")
        #expect(SessionsCard.title(of: make("a", tool: .codex, project: nil, branch: nil), hideTitles: false) == "Codex")
        #expect(SessionsCard.title(of: make("a", title: ""), hideTitles: false) == "notchmeter", "an empty title is no title")
    }

    @Test func eachRowCarriesItsChipsClockStatusAndNote() {
        let now = t0.addingTimeInterval(130)
        let pending = PendingRequest(id: "r", kind: .permission(tool: "Bash", summary: "ls", detail: nil, suggestions: []), since: t0)
        let working = make("w", title: "Working on it", terminal: iterm, state: .working(since: t0), turnStarted: t0.addingTimeInterval(10))
        let waiting = make("q", tool: .codex, terminal: iterm, state: .waiting(since: t0), turnStarted: t0, pending: pending)
        let finished = make("f", terminal: iterm, finished: ToolSignal.Finish(turn: 60, at: t0.addingTimeInterval(120)),
                            lastEvent: t0.addingTimeInterval(120))
        let remote = make("r", host: "devbox", state: .working(since: t0))
        let (rows, more) = SessionsCard.rows([finished, working, waiting, remote], hideTitles: false, jump: true, now: now)
        #expect(more == 0)
        #expect(rows.map(\.id) == ["q", "w", "r", "f"], "what needs the reader, then what runs (newest first), then what just ended")
        #expect(rows.map(\.status) == [.waiting, .working, .working, .finished])
        #expect(rows[1].chips == ["Claude"], "the assistant is the one chip; the terminal moved to the second line")
        #expect(rows[1].place == "iTerm")
        #expect(rows[1].branch == "main")
        #expect(rows[1].host == nil)
        #expect(rows[1].title == "Working on it")
        #expect(rows[1].since == t0.addingTimeInterval(10), "the clock is the turn's start when there is one")
        #expect(rows[1].note == nil)
        #expect(rows[1].canJump)
        #expect(rows[0].chips == ["Codex"])
        #expect(rows[0].place == "iTerm")
        #expect(rows[0].needsYou, "the row holding a request takes the wash and the bar")
        #expect(!rows[1].needsYou)
        #expect(rows[0].note == .waitingForAnswer)
        #expect(rows[3].note == .doneJump)
        #expect(rows[3].since == t0.addingTimeInterval(120), "an ended turn clocks its quiet, not the session's age")
        #expect(rows[2].chips == ["Claude"])
        #expect(rows[2].host == nil, "two projects are live, so the row sits under the \"notchmeter@devbox\" header, which names the host")
        #expect(rows[2].title == "main", "untitled under a header: the branch, not the project again")
        #expect(rows[2].branch == nil)
        #expect(rows[2].place == nil)
        #expect(rows[2].canJump == false, "a session on another Mac has nothing to jump to")
        let noJump = SessionsCard.rows([finished], hideTitles: false, jump: false, now: now).rows[0]
        #expect(noJump.canJump == false)
        #expect(noJump.note == .justFinished, "with the jump off a finish is reported without inviting a click")
        let noTerminal = SessionsCard.rows([make("t", state: .working(since: t0))], hideTitles: false, jump: true, now: now).rows[0]
        #expect(noTerminal.canJump == false, "a hook that named no terminal gives the row nowhere to go")
        #expect(noTerminal.chips == ["Claude"])
        #expect(noTerminal.place == nil)
        let inCursor = make("c", tool: .cursor, terminal: TerminalRef(bundleID: "com.todesktop.230313mzl4w4u92"), state: .working(since: t0))
        let cursorRow = SessionsCard.rows([inCursor], hideTitles: false, jump: true, now: now).rows[0]
        #expect(cursorRow.chips == ["Cursor"])
        #expect(cursorRow.place == nil, "Cursor's agent in Cursor names Cursor once, not twice")
    }

    /// A reference is not a jump: `TERM_PROGRAM=vscode` with no bundle id and no app ancestor is a reference the
    /// resolver answers nothing for, and a row with nowhere to go is a row and not a button.
    @Test func aReferenceTheResolverCannotUseIsARowAndNotAButton() {
        let now = t0.addingTimeInterval(130)
        let programOnly = TerminalRef(program: "vscode")
        #expect(TerminalJump.resolve(programOnly) == .none)
        let row = SessionsCard.rows([make("v", terminal: programOnly, finished: ToolSignal.Finish(turn: 60, at: t0.addingTimeInterval(120)))],
                                    hideTitles: false, jump: true, now: now).rows[0]
        #expect(row.canJump == false)
        #expect(row.note == .justFinished, "the finish is reported without inviting a click that would do nothing")
    }

    @Test func sixRowsAndThenACount() {
        let sessions = (0..<9).map { make("s\($0)", lastEvent: t0.addingTimeInterval(TimeInterval($0))) }
        let (rows, more) = SessionsCard.rows(sessions, hideTitles: false, jump: true, now: t0)
        #expect(rows.count == SessionsCard.rowCap)
        #expect(SessionsCard.rowCap == 6)
        let left = 3
        #expect(more == left)
        #expect(rows.map(\.id) == ["s0", "s1", "s2", "s3", "s4", "s5"], "the order is the caller's, which is the tracker's newest first")
    }

    /// One project, no headers; two, a header per project in the order of its most urgent row, with the rows
    /// keeping their worst-first order inside it and the count taken over every session of the project.
    @Test func rowsGroupByProjectOnlyWhenMoreThanOneIsLive() {
        let now = t0.addingTimeInterval(130)
        let pending = PendingRequest(id: "r", kind: .permission(tool: "Bash", summary: "ls", detail: nil, suggestions: []), since: t0)
        let one = [make("a", state: .working(since: t0)), make("b")]
        let single = SessionsCard.groups(SessionsCard.rows(one, hideTitles: false, jump: true, now: now).rows, sessions: one)
        #expect(single.count == 1)
        #expect(single[0].name == nil, "a single project draws no header")
        #expect(single[0].rows.map(\.id) == ["a", "b"])

        let sessions = [
            make("n-idle"),
            make("s-work", project: "scout", state: .working(since: t0)),
            make("n-wait", state: .waiting(since: t0), pending: pending),
            make("n-work", state: .working(since: t0)),
            make("remote", host: "devbox"),
        ]
        let rows = SessionsCard.rows(sessions, hideTitles: false, jump: true, now: now).rows
        #expect(rows.map(\.id) == ["n-wait", "s-work", "n-work", "n-idle", "remote"])
        let groups = SessionsCard.groups(rows, sessions: sessions)
        #expect(groups.map(\.name) == ["notchmeter", "scout", "notchmeter@devbox"], "notchmeter leads: it holds the wait")
        #expect(groups.map(\.count) == [3, 1, 1])
        #expect(groups[0].rows.map(\.id) == ["n-wait", "n-work", "n-idle"], "worst first inside the group")
        #expect(SessionsCard.groups([], sessions: []).isEmpty, "no sessions, no groups: the card draws its empty line")
    }

    /// The count covers the sessions past the cap too, so a header never undercounts its project.
    @Test func aGroupCountsTheSessionsBeyondTheCap() {
        let sessions = (0..<8).map { make("n\($0)", lastEvent: t0.addingTimeInterval(TimeInterval($0))) } + [make("s", project: "scout")]
        let (rows, more) = SessionsCard.rows(sessions, hideTitles: false, jump: true, now: t0)
        #expect(more == 3)
        let groups = SessionsCard.groups(rows, sessions: sessions)
        #expect(groups.map(\.count) == [8], "only notchmeter's six made it on; scout is counted in +3 more")
        #expect(groups[0].name == "notchmeter")
    }

    /// A row without a title of its own says something its header does not: under a project header it takes the
    /// branch (else the terminal) as its title and leaves it off the second line; with one project and no header
    /// it is the project, and a remote one's host is not said twice.
    @Test func aFallbackTitleNeverRepeatsTheHeaderOrTheHost() {
        let grouped = [make("a", terminal: iterm), make("b", branch: nil, terminal: iterm), make("c", branch: nil), make("s", project: "scout"),
                       make("t", title: "Fix it", host: "devbox", state: .working(since: t0))]
        let rows = Dictionary(uniqueKeysWithValues: SessionsCard.rows(grouped, hideTitles: false, jump: true, now: t0).rows.map { ($0.id, $0) })
        #expect(rows["a"]?.title == "main")
        #expect(rows["a"]?.branch == nil)
        #expect(rows["a"]?.place == "iTerm")
        #expect(rows["b"]?.title == "iTerm", "no branch: the terminal")
        #expect(rows["b"]?.place == nil)
        #expect(rows["c"]?.title == "notchmeter", "nothing else to say: the project, which is never blank")
        #expect(rows["t"]?.title == "Fix it")
        #expect(rows["t"]?.host == nil, "the header says @devbox")
        let hidden = SessionsCard.rows(grouped, hideTitles: true, jump: true, now: t0).rows.first { $0.id == "t" }
        #expect(hidden?.title == "main", "a shared screen hides the prompt and the header still names the project")

        let single = SessionsCard.rows([make("r", host: "devbox")], hideTitles: false, jump: true, now: t0).rows[0]
        #expect(single.title == "notchmeter@devbox")
        #expect(single.branch == "main")
        #expect(single.host == nil, "the title already carries @devbox")
        let titled = SessionsCard.rows([make("r", title: "Deploy", host: "devbox")], hideTitles: false, jump: true, now: t0).rows[0]
        #expect(titled.host == "@devbox", "a titled row alone keeps its host on the second line")
    }

    /// Subagents are listed oldest first by when they started; the ids are the tracker's, never shown.
    @Test func aRowListsItsSubagentsOldestFirst() {
        var session = make("a", state: .working(since: t0))
        session.agents = ["late": t0.addingTimeInterval(60), "early": t0.addingTimeInterval(5), "mid": t0.addingTimeInterval(30)]
        let row = SessionsCard.rows([session], hideTitles: false, jump: true, now: t0.addingTimeInterval(90)).rows[0]
        #expect(row.agents.map(\.id) == ["early", "mid", "late"])
        #expect(row.agents.first?.since == t0.addingTimeInterval(5))
        #expect(SessionsCard.rows([make("b")], hideTitles: false, jump: true, now: t0).rows[0].agents.isEmpty)
    }

    /// The gauge is the session's own figure or nothing: a session its status line never reported has none, and
    /// the tint steps at 70 % and 90 % with the percentage always beside it.
    @Test func theContextGaugeIsTheSessionsOwnFigureOrNothing() {
        var reported = make("a", state: .working(since: t0))
        reported.contextUsed = 0.52
        let rows = SessionsCard.rows([reported, make("b")], hideTitles: false, jump: true, now: t0).rows
        #expect(rows[0].contextUsed == 0.52)
        #expect(rows[1].contextUsed == nil, "never guessed")
        #expect(SessionsCard.contextLevel(0.52) == .quiet)
        #expect(SessionsCard.contextLevel(0.7) == .high)
        #expect(SessionsCard.contextLevel(0.9) == .full)
    }

    /// The task list rides on the row with its words while titles show, and as counts alone when they are hidden.
    @Test func theTaskListKeepsItsCountsWhenItsWordsAreHidden() {
        var session = make("a", state: .working(since: t0))
        session.todos = TodoPlan(items: [TodoPlan.Item(content: "Read the code", status: .completed),
                                         TodoPlan.Item(content: "Write the test", status: .inProgress),
                                         TodoPlan.Item(content: "Ship it", status: .pending)])
        let shown = SessionsCard.rows([session], hideTitles: false, jump: true, now: t0).rows[0]
        #expect(shown.todos?.done == 1)
        #expect(shown.todos?.total == 3)
        #expect(shown.todos?.hasContent == true)
        #expect(shown.todos?.items.map(\.content) == ["Read the code", "Write the test", "Ship it"])
        let hidden = SessionsCard.rows([session], hideTitles: true, jump: true, now: t0).rows[0]
        #expect(hidden.todos?.total == 3)
        #expect(hidden.todos?.hasContent == false, "a shared screen or titles off shows the count and nothing to open")
        #expect(hidden.todos?.items.map(\.status) == [.completed, .inProgress, .pending])
    }

    /// The oracle's picture of the card: order, group, status and the counts, never a title or a task's words.
    @Test func theOracleRowsCarryCountsAndNoWords() throws {
        var session = make("a", title: "Secret plan", state: .working(since: t0))
        session.contextUsed = 0.4
        session.agents = ["x": t0]
        session.todos = TodoPlan(items: [TodoPlan.Item(content: "Secret step", status: .completed)])
        let sessions = [session, make("b", project: "scout")]
        let rows = SessionsCard.rows(sessions, hideTitles: false, jump: true, now: t0).rows
        let fields = SessionsCard.oracleRows(SessionsCard.groups(rows, sessions: sessions))
        #expect(fields.count == 2)
        #expect(fields[0]["id"] as? String == "a")
        #expect(fields[0]["group"] as? String == "notchmeter")
        #expect(fields[0]["status"] as? String == "working")
        #expect(fields[0]["agents"] as? Int == 1)
        #expect(fields[0]["context"] as? Double == 0.4)
        let todos = try #require(fields[0]["todos"] as? [String: Int])
        #expect(todos == ["done": 1, "total": 1])
        let line = try #require(Oracle.line(event: "snapshot", fields: ["rows": fields]))
        #expect(!line.contains("Secret"))
    }

    @Test func aListIsKeyedBySessionAndKind() {
        #expect(SessionsCard.listKey("abc", .todos) == "abc/todos")
        #expect(SessionsCard.listKey("abc", .agents) == "abc/agents")
    }

    /// The card is offered the panel's column and comes out exactly that wide with the fixture sessions on it.
    /// The empty card: hooks installed and no session, drawn as a card with its one line rather than nothing.
    @MainActor @Test func theEmptyCardDrawsItsOneLine() {
        let defaults = UserDefaults(suiteName: "NotchmeterTests.SessionsCardEmpty")!
        defaults.removePersistentDomain(forName: "NotchmeterTests.SessionsCardEmpty")
        defer { defaults.removePersistentDomain(forName: "NotchmeterTests.SessionsCardEmpty") }
        let prefs = Preferences(defaults: defaults)
        let store = UsageStore(prefs: prefs, providers: [], cache: ReadingCache(defaults: defaults), defaults: defaults, drainLog: nil, reportFile: nil)
        store.hooksInstalled = true
        let host = NSHostingView(rootView: SessionsCard(store: store, prefs: prefs, actions: NotchActions()).frame(width: 340).environment(\.density, .comfortable))
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.height > 30)
        #expect(host.fittingSize.height < 90, "one quiet line, not a placeholder the size of a row list")
    }

    @MainActor @Test func theCardFitsTheColumn() {
        let defaults = UserDefaults(suiteName: "NotchmeterTests.SessionsCard")!
        defaults.removePersistentDomain(forName: "NotchmeterTests.SessionsCard")
        defer { defaults.removePersistentDomain(forName: "NotchmeterTests.SessionsCard") }
        let prefs = Preferences(defaults: defaults)
        let store = UsageStore(prefs: prefs, providers: [], cache: ReadingCache(defaults: defaults), defaults: defaults, drainLog: nil, reportFile: nil)
        let now = Date()
        store.seed(readings: [], cost: DemoFixtures.cost(now: now), nextUpdate: now, sessions: DemoFixtures.sessions(now: now, moment: .permissionRequest), now: now)
        for width in PanelWidth.allCases {
            let column = width.points - 2 * NotchExpandedView.contentHorizontalPadding
            let host = NSHostingView(rootView: SessionsCard(store: store, prefs: prefs, actions: NotchActions()).frame(width: column).environment(\.density, .comfortable))
            host.layoutSubtreeIfNeeded()
            #expect(host.fittingSize.width == column)
            #expect(host.fittingSize.height > 40)
        }
    }
}

/// The two request moments the fixtures grew for 0.7.0 hold a request the panel can draw and a title the
/// Sessions card can show, and the two older moments still hold what they did.
@Suite struct DemoFixtureRequests {
    let now = DateParsing.iso8601("2026-09-01T15:00:00Z")!

    @Test func thePermissionMomentHoldsAPermissionAndTheQuestionMomentAQuestion() throws {
        let permission = DemoFixtures.sessions(now: now, moment: .permissionRequest)
        let pending = permission.pending(now: now)
        #expect(pending.count == 1)
        let first = try #require(pending.first)
        #expect(first.request.id == DemoFixtures.requestID)
        guard case .permission(let tool, let summary, _, let suggestions) = first.request.kind else {
            Issue.record("the permission moment holds a permission")
            return
        }
        #expect(tool == "Bash")
        #expect(summary == "swift build -c release")
        #expect(suggestions == ["swift build:*"])
        #expect(first.session.isWaiting)
        #expect(first.session.title == DemoFixtures.notchmeterTitle)
        #expect(first.session.terminal?.bundleID == "com.googlecode.iterm2")
        #expect(permission.waiting(of: .claude).count == 1)
        let question = DemoFixtures.sessions(now: now, moment: .question)
        guard case .question(let questions)? = question.pending(now: now).first?.request.kind else {
            Issue.record("the question moment holds a question")
            return
        }
        #expect(questions.count == 1)
        #expect(questions[0].options.count == 3)
        #expect(!questions[0].multiSelect)
        // The request is thirty-five seconds old, well inside the store's default hold and the socket's cap.
        #expect(now.timeIntervalSince(first.request.since) < TimeInterval(Preferences.promptHoldDefault) / 2)
    }

    @Test func theOlderMomentsCarryTitlesAndATerminalAndNoRequest() {
        for moment in [DemoFixtures.Moment.waiting, .justFinished] {
            let sessions = DemoFixtures.sessions(now: now, moment: moment)
            #expect(sessions.pending(now: now).isEmpty)
            #expect(sessions.all.allSatisfy { $0.title != nil && $0.terminal?.bundleID == "com.googlecode.iterm2" })
        }
    }

    @MainActor @Test func theSeededStoreShowsTheRequestOnTheRingAndInPending() {
        let (store, prefs) = DemoFixtures.store(now: now, moment: .permissionRequest)
        #expect(store.signal(.claude, now: now) == .waiting(count: 1))
        #expect(store.sessions.pending(now: now).count == 1)
        #expect(prefs.sessionsCard && prefs.answerFromNotch && prefs.jumpToTerminal && prefs.sessionTitles)
    }
}

/// The glance card (SessionAttention.glance, since 0.7.5; 0.7.4 called it *Show a card*): the card says
/// what the banner says, and its jump follows the Sessions card's rule.
@MainActor @Suite struct AttentionNoticeCard {
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    /// Since 0.7.5 the glance is the card: 0.7.4's separate "card" choice reads back as the glance.
    @Test func theGlanceIsTheCardAndAStoredCardReadsAsIt() {
        #expect(SessionAttention.allCases == [.nothing, .glance, .openPanel])
        #expect(SessionAttention.glance.title == "Glance (a card for a few seconds)")
        #expect(SessionAttention.stored("card") == .glance)
        #expect(SessionAttention.stored("glance") == .glance)
        #expect(SessionAttention.stored("openPanel") == .openPanel)
        #expect(SessionAttention.stored(nil) == .nothing)
        #expect(SessionAttention.stored("bogus") == .nothing)
    }

    @Test func theCardJumpsOnlyWhereARowWould() {
        var local = AgentSession(id: "a", tool: .claude, project: "notchmeter", state: .idle, started: t0, lastEvent: t0, turnStarted: nil)
        #expect(!NoticeCard.canJump(local, enabled: true), "no terminal, nowhere to go")
        local.terminal = TerminalRef(bundleID: "com.googlecode.iterm2")
        #expect(NoticeCard.canJump(local, enabled: true))
        #expect(!NoticeCard.canJump(local, enabled: false), "the jump setting off")
        var remote = local
        remote.host = "devbox"
        #expect(!NoticeCard.canJump(remote, enabled: true), "a session on another Mac")
    }

    @Test func theCardDrawsWithAndWithoutItsJump() {
        var session = AgentSession(id: "a", tool: .claude, project: "notchmeter", state: .idle, started: t0, lastEvent: t0, turnStarted: nil)
        session.terminal = TerminalRef(bundleID: "com.googlecode.iterm2")
        let finished = AttentionNotice(session: session, event: .finished(turn: 125))
        func height(_ card: NoticeCard) -> CGFloat {
            let renderer = ImageRenderer(content: card.frame(width: 360).environment(\.colorScheme, .dark))
            return renderer.nsImage?.size.height ?? 0
        }
        let bare = height(NoticeCard(notice: finished))
        let withJump = height(NoticeCard(notice: finished, canJump: true))
        #expect(bare > 0)
        #expect(withJump > bare, "the jump button adds a row")
        #expect(Notifier.copy(for: .finished(turn: 125), session: session).body.contains("notchmeter"))
    }
}
