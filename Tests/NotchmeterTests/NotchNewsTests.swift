import Foundation
import Testing
@testable import Notchmeter

/// The news the collapsed notch announces: which hook messages make any, what reason they carry, when a second
/// one is worth showing, what the peek says while the screen is shared, where its words go beside the notch, and
/// what the glow under it is doing. All of it is pure, so it is pinned without a menu bar or a window.
@Suite struct NotchNewsRules {
    init() { Localization.use(language: "en") }

    let t0 = DateParsing.iso8601("2026-09-01T12:00:00Z")!

    func message(_ event: String, session: String = "a", project: String? = "notchmeter", type: String? = nil,
                 tool: ToolID = .claude, request: PendingRequest.Kind? = nil) -> Hook.Message {
        var message = Hook.Message(event: event, needsInput: Hook.needsInput(event: event, notificationType: type) || request != nil,
                                   sessionID: session, project: project, notificationType: type, tool: tool)
        if let request { message.request = Hook.Request(id: UUID().uuidString, kind: request) }
        return message
    }

    func news(_ reason: NotchNews.Reason, session: String = "a", ago: TimeInterval = 0, project: String? = "notchmeter") -> NotchNews {
        NotchNews(reason: reason, sessionID: session, tool: .claude, project: project, at: t0.addingTimeInterval(-ago))
    }

    /// Feeds the tracker a sequence of (event, seconds before t0) and returns the news the last one makes.
    func newsAfter(_ steps: [(Hook.Message, TimeInterval)]) -> NotchNews? {
        var tracker = SessionTracker()
        var last: NotchNews?
        for (message, ago) in steps {
            let now = t0.addingTimeInterval(-ago)
            let outcome = tracker.apply(message, now: now)
            last = NotchNews.from(message, outcome: outcome, now: now)
        }
        return last
    }

    // MARK: - The reason

    @Test func aRequestNamesItsOwnReason() {
        #expect(NotchNews.reason(event: "PermissionRequest", notificationType: nil, request: .permission(tool: "Bash", summary: "ls", detail: nil, suggestions: [])) == .approval)
        #expect(NotchNews.reason(event: "PreToolUse", notificationType: nil, request: .question([])) == .question)
    }

    @Test func withoutARequestTheVendorsVocabularySaysWhichErrandItIs() {
        #expect(NotchNews.reason(event: "Notification", notificationType: "permission_prompt", request: nil) == .approval)
        #expect(NotchNews.reason(event: "Notification", notificationType: "ToolPermission", request: nil) == .approval)
        #expect(NotchNews.reason(event: "PermissionRequest", notificationType: nil, request: nil) == .approval)
        #expect(NotchNews.reason(event: "Elicitation", notificationType: nil, request: nil) == .question)
        #expect(NotchNews.reason(event: "Notification", notificationType: "elicitation_dialog", request: nil) == .question)
        #expect(NotchNews.reason(event: "Notification", notificationType: "agent_needs_input", request: nil) == .question)
        #expect(NotchNews.reason(event: "Notification", notificationType: nil, request: nil) == .waiting,
                "A wait the vendor gives no type for is still a wait; it is only not named.")
    }

    @Test func theIdleNudgeIsNotNews() {
        #expect(NotchNews.reason(event: "Notification", notificationType: Hook.idleNotificationType, request: nil) == nil,
                "It says the user went quiet after a finish the strip already announced.")
    }

    // MARK: - Which messages make news

    @Test func aWaitBeginningIsNewsAndItsRepeatOnTheSameWaitIsNot() {
        let prompt = message("UserPromptSubmit")
        let asked = message("Notification", type: "permission_prompt")
        let news = newsAfter([(prompt, 60), (asked, 0)])
        #expect(news?.reason == .approval)
        #expect(news?.sessionID == "a")
        #expect(news?.project == "notchmeter")
        #expect(news?.at == t0)
        #expect(newsAfter([(prompt, 60), (asked, 10), (asked, 0)]) == nil,
                "A session already waiting has not started to: the tracker reports no new wait, so there is no news.")
    }

    @Test func aHeldRequestIsNewsWithItsKind() {
        let news = newsAfter([(message("UserPromptSubmit"), 60), (message("PreToolUse", request: .question([])), 0)])
        #expect(news?.reason == .question)
    }

    @Test func aLongTurnFinishingIsNewsAndAShortOneIsNot() {
        let long = newsAfter([(message("UserPromptSubmit"), 120), (message("Stop"), 0)])
        #expect(long?.reason == .finished)
        #expect(long?.sessionID == "a")
        let short = newsAfter([(message("UserPromptSubmit"), ToolSignal.finishedAfter - 1), (message("Stop"), 0)])
        #expect(short == nil, "A turn that ended while the user was still watching it is not news, the rule the ring keeps.")
    }

    @Test func activityThatIsNeitherIsNotNews() {
        #expect(newsAfter([(message("SessionStart"), 10), (message("UserPromptSubmit"), 0)]) == nil)
    }

    // MARK: - When a second one is due

    @Test func theFirstNewsIsAlwaysDue() {
        #expect(NotchNews.isDue(news(.approval), showing: nil, last: nil, now: t0))
    }

    @Test func theSameSessionForTheSameReasonIsARepeatForThirtySeconds() {
        let earlier = news(.approval, ago: NotchNews.repeatAfter - 1)
        #expect(!NotchNews.isDue(news(.approval), showing: nil, last: earlier, now: t0))
        let older = news(.approval, ago: NotchNews.repeatAfter)
        #expect(NotchNews.isDue(news(.approval), showing: nil, last: older, now: t0))
        #expect(NotchNews.isDue(news(.approval, session: "b"), showing: nil, last: earlier, now: t0), "Another session is news of its own.")
        #expect(NotchNews.isDue(news(.question), showing: nil, last: earlier, now: t0), "Another errand is news of its own.")
    }

    @Test func aWaitOnScreenIsNotReplacedByAFinishButAFinishIsByAWait() {
        let waiting = news(.approval, session: "b", ago: 1)
        #expect(!NotchNews.isDue(news(.finished), showing: waiting, last: waiting, now: t0))
        let finished = news(.finished, session: "b", ago: 1)
        #expect(NotchNews.isDue(news(.question), showing: finished, last: finished, now: t0))
        #expect(NotchNews.isDue(news(.finished), showing: nil, last: waiting, now: t0),
                "Once the wait's peek is down, the finish is shown.")
    }

    // MARK: - The words

    @Test func thePeekNamesTheProjectAndTheReason() {
        let words = news(.approval).words(hidesFigures: false)
        #expect(words.name == "notchmeter")
        #expect(words.reason == "Needs approval")
        #expect(words.reasonSymbol == "hand.raised.fill")
        #expect(words.toolSymbol == ToolID.claude.symbolName)
        #expect(words.spoken == "Claude Code, notchmeter, Needs approval")
        #expect(news(.question).words(hidesFigures: false).reason == "Question")
        #expect(news(.finished).words(hidesFigures: false).reason == "Finished")
        #expect(news(.finished).words(hidesFigures: false).reasonSymbol == "checkmark.circle.fill")
    }

    @Test func whileTheScreenIsSharedThePeekSaysOnlyTheReason() {
        let words = news(.approval).words(hidesFigures: true)
        #expect(words.name == nil)
        #expect(words.reason == "Needs approval")
        #expect(words.spoken == "Claude Code, Needs approval")
        #expect(!words.spoken.contains("notchmeter"), "The announcement is read aloud over a shared screen as well.")
    }

    @Test func aSessionWithNoProjectHasNoName() {
        #expect(news(.finished, project: nil).words(hidesFigures: false).name == nil)
        #expect(news(.finished, project: "").words(hidesFigures: false).name == nil)
    }

    // MARK: - Where the words go

    @Test func theNameGoesLeftOfTheNotchAndTheReasonRightOfIt() {
        let layout = NotchPeek.layout(room: .init(leading: 200, trailing: 90), hasName: true)
        #expect(layout?.leading == [.tool, .name])
        #expect(layout?.trailing == [.reason])
        #expect(layout?.leadingWidth == NotchPeek.cap, "No half takes more than the cap, however much room there is.")
        #expect(layout?.trailingWidth == 90, "A half takes no more than the gap Auto measured on its side.")
    }

    @Test func aSideTooNarrowGivesItsWordsToTheOther() {
        // The menus run past the notch on the left: the whole peek goes right of it.
        let right = NotchPeek.layout(room: .init(leading: -252, trailing: 120), hasName: true)
        #expect(right?.leading == [])
        #expect(right?.trailing == [.tool, .name, .reason])
        #expect(right?.leadingWidth == 0)
        let left = NotchPeek.layout(room: .init(leading: 120, trailing: 20), hasName: true)
        #expect(left?.leading == [.tool, .name, .reason])
        #expect(left?.trailing == [])
    }

    @Test func withNoRoomEitherSideThereIsNoPeek() {
        #expect(NotchPeek.layout(room: .init(leading: 30, trailing: 30), hasName: true) == nil)
    }

    @Test func withNoNameTheLeftKeepsTheToolsSymbol() {
        let layout = NotchPeek.layout(room: .init(leading: 30, trailing: 120), hasName: false)
        #expect(layout?.leading == [.tool], "A symbol fits where a word would not.")
        #expect(layout?.trailing == [.reason])
    }

    @Test func unmeasuredRoomIsTheCapEitherSide() {
        let layout = NotchPeek.layout(room: .unmeasured, hasName: true)
        #expect(layout?.leadingWidth == NotchPeek.cap)
        #expect(layout?.trailingWidth == NotchPeek.cap)
    }

    // MARK: - The glow

    @Test func aWaitBloomsBlueThenSettlesToAnEmberWhileItStands() {
        let wait = news(.approval, ago: 1)
        #expect(NotchGlow.state(news: wait, waiting: true, enabled: true, now: t0) == .bloom(.calm))
        let stale = news(.approval, ago: NotchGlow.bloomFor)
        #expect(NotchGlow.state(news: stale, waiting: true, enabled: true, now: t0) == .ember)
        #expect(NotchGlow.state(news: stale, waiting: false, enabled: true, now: t0) == nil, "Answered: the light goes.")
    }

    @Test func aFinishBloomsSoftAndGoes() {
        #expect(NotchGlow.state(news: news(.finished, ago: 2), waiting: false, enabled: true, now: t0) == .bloom(.soft))
        #expect(NotchGlow.state(news: news(.finished, ago: 3), waiting: false, enabled: true, now: t0) == nil)
    }

    @Test func switchedOffThereIsNoLight() {
        #expect(NotchGlow.state(news: news(.approval), waiting: true, enabled: false, now: t0) == nil)
        #expect(NotchGlow.name(nil) == "none")
        #expect(NotchGlow.name(.bloom(.calm)) == "bloom-calm")
        #expect(NotchGlow.name(.ember) == "ember")
    }

    // MARK: - The symbol in the rings

    @Test func theSymbolSitsInTheMiddleOfOneRingAndBesideAnyMore() {
        guard case .centre(let one) = CompactRings.glyph(rings: 1) else {
            Issue.record("One ring leaves the whole middle free, even quiet.")
            return
        }
        #expect(one >= CompactRings.smallestCentreGlyph)
        #expect(CompactRings.glyph(rings: 2) == .beside(CompactRings.besideGlyph),
                "The quiet two-ring nest leaves a hole under six points, and the place is the quiet nest's in both states.")
        #expect(CompactRings.glyph(rings: 3) == .beside(CompactRings.besideGlyph), "Three rings leave a hole the size of a dot.")
    }

    /// Beside the nest the symbol has room of its own, which the fit measures; in the middle it takes none.
    @Test func theSymbolBesideTheRingsWidensTheReadoutAndTheOneInsideDoesNot() {
        #expect(CompactRings.width(rings: 1, symbol: true) == CompactRings.side)
        #expect(CompactRings.width(rings: 2, symbol: false) == CompactRings.side)
        #expect(CompactRings.width(rings: 2, symbol: true) > CompactRings.side)
        #expect(CompactRings.width(rings: 3, symbol: true) == CompactRings.width(rings: 2, symbol: true))
    }

    // MARK: - Opening on the session

    @Test func thePointerReachingThePeekOpensOnItsSession() {
        #expect(NotchNews.opensOnSession(.dwell), "Under On hover the dwell opens the panel before a click can land.")
        #expect(NotchNews.opensOnSession(.click))
        #expect(NotchNews.opensOnSession(.swipe))
        #expect(!NotchNews.opensOnSession(.hotkey), "The hotkey was not aimed at the words.")
        #expect(!NotchNews.opensOnSession(.glance))
        #expect(!NotchNews.opensOnSession(.notification))
    }

    @Test func thePanelOpensOnTheSessionsRequestElseItsCardElseWhole() {
        #expect(NotchNews.opening(for: "a", pendingSessions: ["b", "a"], known: true) == .request)
        #expect(NotchNews.opening(for: "a", pendingSessions: ["b"], known: true) == .notice,
                "Another session's request does not make this one's.")
        #expect(NotchNews.opening(for: "a", pendingSessions: [], known: false) == .whole, "A session gone in the meantime.")
    }

    @Test func theFocusedSessionsRequestIsDrawnInPlaceOfTheNewest() {
        #expect(PanelLead.request(pendingSessions: [], focus: "a") == nil)
        #expect(PanelLead.request(pendingSessions: ["b", "a"], focus: nil) == 0, "Unfocused, the newest.")
        #expect(PanelLead.request(pendingSessions: ["b", "a"], focus: "a") == 1)
        #expect(PanelLead.request(pendingSessions: ["b", "a"], focus: "gone") == 0)
    }

    @Test func theFocusedSessionsCardOutranksAnotherSessionsRequest() {
        #expect(PanelLead.noticeLeads(notice: "a", pendingSessions: [], promptOnly: false, focus: nil))
        #expect(!PanelLead.noticeLeads(notice: "a", pendingSessions: ["b"], promptOnly: false, focus: nil),
                "A glance's card still gives way to a request.")
        #expect(PanelLead.noticeLeads(notice: "a", pendingSessions: ["b"], promptOnly: false, focus: "a"))
        #expect(!PanelLead.noticeLeads(notice: "a", pendingSessions: ["b"], promptOnly: true, focus: "a"))
        #expect(!PanelLead.noticeLeads(notice: nil, pendingSessions: [], promptOnly: false, focus: "a"))
    }

    // MARK: - VoiceOver and timing

    @Test func aSplitPeekIsOneButtonToVoiceOver() {
        let layout = NotchPeek.layout(room: .init(leading: 120, trailing: 120), hasName: true)
        let speaking = [layout?.leading, layout?.trailing].compactMap { $0 }.filter(NotchPeek.speaks)
        #expect(speaking.count == 1, "Only the half with the reason is an element; the other is hidden.")
        #expect(NotchPeek.speaks([.tool, .name, .reason]))
        #expect(!NotchPeek.speaks([.tool, .name]))
    }

    @Test func thePeekStaysASecondLongerUnderReduceMotion() {
        #expect(NotchNews.shownFor(motionReduced: false) == NotchNews.shownFor)
        let longer: TimeInterval = NotchNews.shownFor + 1
        #expect(NotchNews.shownFor(motionReduced: true) == longer)
    }
}

/// `UsageStore.announce`: which of the peek, the glow and the VoiceOver line a piece of news gets, by the settings
/// and by what the panel is already doing.
@MainActor @Suite(.serialized) struct NotchNewsAnnouncing {
    init() { Localization.use(language: "en") }

    static let suite = "NotchmeterTests.notchNewsAnnounce"

    func makeStore(news: Bool = true, glow: Bool = true, canPeek: Bool = true) -> (UsageStore, Box) {
        let defaults = UserDefaults(suiteName: Self.suite)!
        defaults.removePersistentDomain(forName: Self.suite)
        let prefs = Preferences(defaults: defaults)
        prefs.notchNews = news
        prefs.notchGlow = glow
        let now = Date()
        let store = UsageStore(prefs: prefs, providers: DemoFixtures.readings(now: now).map { FixtureProvider(reading: $0) },
                               cache: ReadingCache(defaults: defaults), defaults: defaults, drainLog: nil, reportFile: nil)
        let box = Box()
        store.canPeek = { canPeek }
        store.announceNews = { box.spoken.append($0.spoken) }
        return (store, box)
    }

    final class Box { var spoken: [String] = [] }

    func news(_ reason: NotchNews.Reason = .approval, session: String = "a") -> NotchNews {
        NotchNews(reason: reason, sessionID: session, tool: .claude, project: "notchmeter", at: Date())
    }

    @Test func newsGetsThePeekTheGlowAndTheAnnouncement() {
        let (store, box) = makeStore()
        store.announce(news())
        #expect(store.peek?.sessionID == "a")
        #expect(store.glowNews?.sessionID == "a")
        #expect(box.spoken.count == 1)
        store.endPeek()
    }

    @Test func aPanelOpenedOnARequestTakesThePeekButNotTheGlowOrTheAnnouncement() {
        let (store, box) = makeStore()
        store.panelOpenedForPrompt = true
        store.announce(news())
        #expect(store.peek == nil)
        #expect(store.glowNews != nil)
        #expect(box.spoken.count == 1)
    }

    /// A glance (or Open the panel) for the very message that made the news has already asked for the panel:
    /// a peek put up now would be torn down by the opening a moment later, a flash and a shown/hidden pair.
    @Test func aCardTheAttentionSettingIsOpeningTakesThePeek() {
        let (store, box) = makeStore()
        let now = Date()
        let session = AgentSession(id: "a", project: "notchmeter", state: .waiting(since: now), started: now, lastEvent: now, turnStarted: nil)
        store.attentionNotice = AttentionNotice(session: session, event: .waiting(blocking: true))
        store.announce(news())
        #expect(store.peek == nil)
        #expect(store.glowNews != nil)
        #expect(box.spoken.count == 1)
    }

    @Test func noStripThatCanShowItMeansNoPeek() {
        let (store, box) = makeStore(canPeek: false)
        store.announce(news())
        #expect(store.peek == nil)
        #expect(store.glowNews != nil, "The glow is lit whether or not a strip can draw the words.")
        #expect(box.spoken.count == 1)
    }

    @Test func withThePeekOffOnlyTheGlowAndTheAnnouncementGo() {
        let (store, box) = makeStore(news: false)
        store.announce(news())
        #expect(store.peek == nil)
        #expect(store.glowNews != nil)
        #expect(box.spoken.count == 1)
    }

    @Test func withBothOffNothingIsAnnounced() {
        let (store, box) = makeStore(news: false, glow: false)
        store.announce(news())
        #expect(store.peek == nil)
        #expect(store.glowNews == nil)
        #expect(box.spoken.isEmpty)
    }

    @Test func aRepeatIsDroppedWholeGlowAndAnnouncementWithIt() {
        let (store, box) = makeStore()
        store.announce(news())
        store.endPeek()
        store.announce(news())
        #expect(store.peek == nil, "The same session for the same reason inside thirty seconds is a repeat.")
        #expect(box.spoken.count == 1)
        store.announce(news(session: "b"))
        #expect(store.peek?.sessionID == "b")
        #expect(store.glowNews?.sessionID == "b")
        #expect(box.spoken.count == 2)
        store.endPeek()
    }

    @Test func aFinishDroppedUnderAWaitDropsItsGlowAndAnnouncementToo() {
        let (store, box) = makeStore()
        store.announce(news(.approval, session: "b"))
        store.announce(news(.finished))
        #expect(store.peek?.reason == .approval)
        #expect(store.glowNews?.reason == .approval)
        #expect(box.spoken.count == 1)
        store.endPeek()
    }
}
