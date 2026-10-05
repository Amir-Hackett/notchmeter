import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Notchmeter

/// The open panel's order (PanelLayout), its header's count (PanelHeader.count), the two-beat open's timings
/// (PanelMotion) and what the oracle says an opening drew (PanelReporter.fields).
@Suite struct PanelLayoutTests {
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    func session(_ id: String, _ state: AgentSession.State, pending: Bool = false, finished: Bool = false) -> AgentSession {
        var session = AgentSession(id: id, project: "p", state: state, started: now.addingTimeInterval(-600),
                                   lastEvent: now.addingTimeInterval(-10), turnStarted: nil)
        if pending { session.pending = PendingRequest(id: "r-\(id)", kind: .question([]), since: now) }
        if finished { session.finished = ToolSignal.Finish(turn: 120, at: now.addingTimeInterval(-5)) }
        return session
    }

    func order(prompt: Bool = false, sessions: Bool = true, lead: Bool, advice: Bool = true) -> [String] {
        PanelLayout.parts(prompt: prompt, spend: true, advice: advice, sessions: sessions, sessionsLead: lead,
                          connect: false, tools: [.claude, .codex], addTool: false).map(\.name)
    }

    @Test func aWorkingWaitingOrHoldingSessionLeads() {
        #expect(PanelLayout.sessionsLead([session("a", .working(since: now))]))
        #expect(PanelLayout.sessionsLead([session("a", .idle), session("b", .waiting(since: now))]))
        #expect(PanelLayout.sessionsLead([session("a", .idle, pending: true)]))
    }

    /// Idle and just-finished sessions leave the Cost card on top: the finish has already been said by the ring.
    @Test func idleAndFinishedSessionsDoNotLead() {
        #expect(!PanelLayout.sessionsLead([]))
        #expect(!PanelLayout.sessionsLead([session("a", .idle), session("b", .idle, finished: true)]))
    }

    @Test func theSessionsCardMovesAboveCostOnlyWhileItLeads() {
        let quiet = ["header", "cost", "advice", "sessions", "tool:claude", "tool:codex", "footer"]
        let leading = ["header", "sessions", "cost", "advice", "tool:claude", "tool:codex", "footer"]
        #expect(order(lead: false) == quiet)
        #expect(order(lead: true) == leading)
    }

    /// A request still outranks the sessions; a card that is off never appears, leading or not.
    @Test func aRequestSitsAboveTheLeadAndAnOffCardStaysOff() {
        #expect(Array(order(prompt: true, lead: true).prefix(3)) == ["header", "prompt", "sessions"])
        #expect(!order(sessions: false, lead: true).contains("sessions"))
        #expect(order(sessions: false, lead: true).first == "header")
    }

    @Test func theHeaderCountsSessionsAndSaysNothingForNone() {
        #expect(PanelHeader.count(0) == nil)
        #expect(PanelHeader.count(1) == "1 session")
        #expect(PanelHeader.count(3) == "3 sessions")
    }

    /// The stagger's beats are 50–60 ms apart, the whole run from first start to last settled is under 300 ms,
    /// every part has settled within the 0.4 s open counted from the panel appearing (so a change to `landing` is
    /// caught), and the close is 60–70 % of the open.
    @Test func theOpenStaggersWithinItsBudgetAndTheCloseIsQuicker() {
        #expect(PanelMotion.step >= 0.05 && PanelMotion.step <= 0.06)
        let run = PanelMotion.delay(index: 50) - PanelMotion.delay(index: 0) + PanelMotion.fade
        #expect(run < PanelMotion.budget)
        #expect(PanelMotion.budget <= 0.3)
        let settled = PanelMotion.delay(index: 50) + PanelMotion.fade
        #expect(settled == PanelMotion.settled)
        #expect(settled <= PanelMotion.settleBudget)
        #expect(PanelMotion.settleBudget <= 0.4)
        #expect(PanelMotion.lastStaggered >= 2, "the top three parts each get a beat")
        #expect(PanelMotion.delay(index: 1) > PanelMotion.delay(index: 0))
        #expect(PanelMotion.delay(index: -3) == PanelMotion.delay(index: 0))
        let share = PanelMotion.close / PanelMotion.open
        #expect(share >= 0.6 && share <= 0.7)
    }

    /// The header's buttons answer the pointer: lighter under it, lighter again pressed, and raised throughout
    /// under Increase Contrast.
    @Test func aHeaderButtonShowsHoverAndPress() {
        for contrast in [false, true] {
            let rest = PanelHeaderButtonStyle.fill(contrast: contrast, hovered: false, pressed: false)
            let hover = PanelHeaderButtonStyle.fill(contrast: contrast, hovered: true, pressed: false)
            let pressed = PanelHeaderButtonStyle.fill(contrast: contrast, hovered: true, pressed: true)
            #expect(rest < hover && hover < pressed)
            #expect(PanelHeaderButtonStyle.fill(contrast: contrast, hovered: false, pressed: true) == pressed)
        }
        #expect(PanelHeaderButtonStyle.fill(contrast: true, hovered: false, pressed: false)
                > PanelHeaderButtonStyle.fill(contrast: false, hovered: false, pressed: false))
    }

    /// The edge panel shows its header's tooltips while the app is inactive, which is always while the panel is
    /// open: it opens on hover and never activates the app.
    @MainActor @Test func theEdgePanelShowsTooltipsWhileTheAppIsInactive() {
        let panel = EdgePanel(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        #expect(panel.allowsToolTipsWhenApplicationIsInactive)
    }

    /// A panel a card opened is still on screen for the frames its close takes, after the collapse has cleared what
    /// it was opened on. Drawn from the store in that time it was every part, at the whole panel's height, in place
    /// of the card (0.9.17, after Allow); it draws what it was open on, and nothing once the request has ended.
    @MainActor @Test func aPanelOnItsWayClosedDrawsWhatItWasOpenOnAndNotEveryPart() throws {
        let (store, prefs) = DemoFixtures.store(now: Date(), moment: .permissionRequest, suite: "NotchmeterTests.panelLeaving")
        defer { UserDefaults.standard.removePersistentDomain(forName: "NotchmeterTests.panelLeaving") }
        let actions = NotchActions()
        let leaving = PanelLeaving()
        func panel() -> NotchExpandedView { NotchExpandedView(store: store, prefs: prefs, actions: actions, maxHeight: 10_000, leaving: leaving) }
        func height() -> CGFloat {
            let host = NSHostingView(rootView: panel())
            host.layoutSubtreeIfNeeded()
            return host.fittingSize.height
        }
        let whole = panel().shownParts, wholeHeight = height()
        #expect(whole.count > 1)

        // A request's card: the presenter takes what the panel is on as it begins to close, then the store's go.
        store.panelOpenedForPrompt = true
        #expect(panel().shownParts == [.prompt])
        let card = height()
        #expect(card < wholeHeight)
        leaving.opening = store.panelOpening
        store.panelOpenedForPrompt = false
        #expect(panel().shownParts == [.prompt], "the card it was open on, not every part")
        #expect(height() == card)
        #expect(NotchExpandedView(store: store, prefs: prefs, actions: actions).shownParts == whole, "every other build of the view reads the store")
        // Answered: the request leaves, and nothing takes its place on the way out.
        let request = try #require(store.sessions.pending(now: Date()).first?.request.id)
        store.decide(request, .allow)
        #expect(panel().shownParts.isEmpty)
        #expect(height() < card)

        // A session's card (a glance, one of Cursor's own cards) is kept the same way.
        let session = try #require(store.sessions.all.first)
        leaving.opening = nil
        store.attentionNotice = AttentionNotice(session: session, event: .waiting(blocking: true))
        #expect(panel().shownParts == [.notice])
        leaving.opening = store.panelOpening
        store.attentionNotice = nil
        #expect(panel().shownParts == [.notice])
        #expect(height() < wholeHeight)

        // The next opening is drawn from the store again: every part, without the request that was answered.
        leaving.opening = nil
        #expect(panel().shownParts == whole.filter { $0 != .prompt })
    }

    /// A notch open on one of Cursor's own cards closes because that card has left the store. What it was open on
    /// includes the card, so it closes as the card it was, and not as the bare notice, a third shorter, that the
    /// store alone gives by then.
    @MainActor @Test func aNotchOpenOnOneOfCursorsCardsClosesAsThatCard() throws {
        let (store, prefs) = DemoFixtures.store(now: Date(), moment: .cursorNotch, suite: "NotchmeterTests.cursorCardLeaving")
        defer { UserDefaults.standard.removePersistentDomain(forName: "NotchmeterTests.cursorCardLeaving") }
        prefs.cursorControl = true
        store.cursorCardsSeen(DemoFixtures.cursorNotchCards)
        let waiting = try #require(store.sessions.all.first { !(store.cursorCards[$0.id] ?? []).isEmpty })
        let card = try #require(store.cursorCards[waiting.id]?.first)
        var notice = AttentionNotice(session: waiting, event: .waiting(blocking: true))
        notice.forCursorCard = true
        store.attentionNotice = notice
        let actions = NotchActions()
        let leaving = PanelLeaving()
        func height() -> CGFloat {
            let host = NSHostingView(rootView: NotchExpandedView(store: store, prefs: prefs, actions: actions, maxHeight: 10_000, leaving: leaving))
            host.layoutSubtreeIfNeeded()
            return host.fittingSize.height
        }
        let open = height()
        #expect(store.panelOpening.noticeCards == [card])

        // The card is answered. The store says so, and the panel takes what it was open on as it is told
        // (NotchController.leave, from AppDelegate.cursorCardsChanged), before the store's own are cleared.
        store.cursorCardsChanged = { _, ended in
            guard ended.contains(waiting.id) else { return }
            leaving.opening = store.panelOpening
            store.attentionNotice = nil
        }
        store.cursorCardsSeen(DemoFixtures.cursorNotchCards.filter { $0.id != card.id })
        #expect(store.cursorCards[waiting.id] == nil, "the card has left its row")
        #expect(leaving.opening?.noticeCards == [card], "and is still what the closing panel is open on")
        #expect(height() == open, "the same card for the frames of the close")
        #expect(store.panelOpening.noticeCards.isEmpty, "nothing is kept of it once the telling is over")
    }

    @Test func anOpeningTellsTheOracleItsCardsAndEntrance() {
        let open = PanelReporter.fields(state: .expanded, cause: .dwell, parts: [.header, .sessions, .spend], staggered: true)
        #expect(open["cards"] as? [String] == ["header", "sessions", "cost"])
        #expect(open["entrance"] as? String == "staggered")
        let reduced = PanelReporter.fields(state: .expanded, cause: .dwell, parts: [.prompt], staggered: false)
        #expect(reduced["entrance"] as? String == "none")
        let closed = PanelReporter.fields(state: .compact, cause: .exit, parts: nil, staggered: true)
        #expect(closed["cards"] == nil && closed["entrance"] == nil && closed["leaving"] == nil)
        #expect(closed["state"] as? String == "compact")
        // A close under the notch says what the panel still draws on its way out: nothing after an answered
        // request's card, the one card after a glance, never `cards`.
        let answered = PanelReporter.fields(state: .compact, cause: .notification, parts: [], staggered: true)
        #expect(answered["leaving"] as? [String] == [] && answered["cards"] == nil && answered["entrance"] == nil)
        let glanced = PanelReporter.fields(state: .compact, cause: .glance, parts: [.notice], staggered: false)
        #expect(glanced["leaving"] as? [String] == ["notice"])
    }
}
