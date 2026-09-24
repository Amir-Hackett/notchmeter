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

    /// *Allow always* says what it saves and where, with the rule quoted as the settings file will hold it.
    @Test func aSuggestionIsSaidInPlainWords() {
        typealias S = PendingRequest.Suggestion
        let rule = S.Grant.rules(["Bash(npm test:*)"])
        #expect(PromptCard.phrase(S(index: 0, grant: rule, place: .localSettings)) == L("Always allow %@ in this project", "Bash(npm test:*)"))
        #expect(PromptCard.phrase(S(index: 0, grant: rule, place: .projectSettings)) == L("Always allow %@ in this project, for everyone", "Bash(npm test:*)"))
        #expect(PromptCard.phrase(S(index: 0, grant: rule, place: .userSettings)) == L("Always allow %@ in every project", "Bash(npm test:*)"))
        #expect(PromptCard.phrase(S(index: 0, grant: rule, place: .session)) == L("Allow %@ for the rest of this session", "Bash(npm test:*)"))
        #expect(PromptCard.phrase(S(index: 0, grant: rule, place: nil)) == L("Always allow %@", "Bash(npm test:*)"), "an unknown destination is not guessed at")
        #expect(PromptCard.phrase(S(index: 0, grant: .rules(["Read", "Bash(ls:*)"]), place: nil)) == L("Always allow %@", "Read, Bash(ls:*)"))
        #expect(PromptCard.phrase(S(index: 0, grant: .directories(["~/src", "lib"]), place: .session))
                == L("Allow %@ for the rest of this session", L("files in %@", "~/src, lib")))
        #expect(PromptCard.phrase(S(index: 0, grant: .acceptEdits, place: .session)) == L("Allow %@ for the rest of this session", L("every file edit")))
        #expect(PromptCard.phrase(S(index: 0, grant: rule, place: .localSettings)).contains("Bash(npm test:*)"), "every language keeps the rule verbatim")
    }

    @Test func theCardOffersAtMostFourSuggestionsInTheirOrder() {
        let many = (0..<6).map { PendingRequest.Suggestion(index: $0 * 2, grant: .rules(["Bash(\($0))"]), place: .session) }
        #expect(PromptCard.offered(many).map(\.index) == [0, 2, 4, 6])
        #expect(PromptCard.offered([]).isEmpty)
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
        let short = PendingRequest(id: "r1", kind: .permission(tool: "Bash", summary: "swift build", detail: "swift build", suggestions: [
            .init(index: 0, grant: .rules(["Bash(swift build:*)", "Bash(swift test --parallel --filter SomeVeryLongSuiteName:*)"]), place: .projectSettings),
            .init(index: 1, grant: .acceptEdits, place: .session),
        ]), since: t0)
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

    @Test func theTitleIsThePromptThenThePlaceThenTheAssistant() {
        #expect(SessionsCard.title(of: make("a", title: "Fix the tests"), hideTitles: false) == "Fix the tests")
        #expect(SessionsCard.title(of: make("a", title: "Fix the tests"), hideTitles: true) == "notchmeter · main", "a shared screen never shows the prompt")
        #expect(SessionsCard.title(of: make("a"), hideTitles: false) == "notchmeter · main")
        #expect(SessionsCard.title(of: make("a", branch: nil), hideTitles: false) == "notchmeter")
        #expect(SessionsCard.title(of: make("a", project: nil, branch: nil, host: "devbox"), hideTitles: false) == "@devbox")
        #expect(SessionsCard.title(of: make("a", tool: .codex, project: nil, branch: nil), hideTitles: false) == "Codex")
        #expect(SessionsCard.title(of: make("a", title: ""), hideTitles: false) == "notchmeter · main", "an empty title is no title")
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
        #expect(rows[1].chips == ["Claude", "iTerm"])
        #expect(rows[1].title == "Working on it")
        #expect(rows[1].since == t0.addingTimeInterval(10), "the clock is the turn's start when there is one")
        #expect(rows[1].note == nil)
        #expect(rows[1].canJump)
        #expect(rows[0].chips == ["Codex", "iTerm"])
        #expect(rows[0].note == .waitingForAnswer)
        #expect(rows[3].note == .doneJump)
        #expect(rows[3].since == t0.addingTimeInterval(120), "an ended turn clocks its quiet, not the session's age")
        #expect(rows[2].chips == ["Claude", "@devbox"])
        #expect(rows[2].canJump == false, "a session on another Mac has nothing to jump to")
        let noJump = SessionsCard.rows([finished], hideTitles: false, jump: false, now: now).rows[0]
        #expect(noJump.canJump == false)
        #expect(noJump.note == .justFinished, "with the jump off a finish is reported without inviting a click")
        let noTerminal = SessionsCard.rows([make("t", state: .working(since: t0))], hideTitles: false, jump: true, now: now).rows[0]
        #expect(noTerminal.canJump == false, "a hook that named no terminal gives the row nowhere to go")
        #expect(noTerminal.chips == ["Claude"])
        let inCursor = make("c", tool: .cursor, terminal: TerminalRef(bundleID: "com.todesktop.230313mzl4w4u92"), state: .working(since: t0))
        #expect(SessionsCard.rows([inCursor], hideTitles: false, jump: true, now: now).rows[0].chips == ["Cursor"], "Cursor's agent in Cursor is one chip, not two")
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

    /// The card is offered the panel's column and comes out exactly that wide with the fixture sessions on it.
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
        #expect(suggestions.map(\.grant) == [.rules(["Bash(swift build:*)"]), .rules(["Bash(swift build:*)"])],
                "two suggestions, so the render shows the split button's chevron")
        #expect(suggestions.map(\.place) == [.localSettings, .session])
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
