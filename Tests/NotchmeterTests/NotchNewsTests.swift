import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Notchmeter

/// The news the collapsed notch announces: which hook messages make any, what reason they carry, when a second
/// one is worth showing, what the peek says while the screen is shared, where its words go across the notch, and
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
        // An MCP server asking for input is its own errand since 0.11: the event, and the dialog's notification.
        #expect(NotchNews.reason(event: "Elicitation", notificationType: nil, request: nil) == .input)
        #expect(NotchNews.reason(event: "Notification", notificationType: "elicitation_dialog", request: nil) == .input)
        #expect(NotchNews.reason(event: "Notification", notificationType: "elicitation_url_dialog", request: nil) == .input)
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

    /// Widths as the strip would measure them: the symbols' half 40, the name `name`.
    static func measure(name: CGFloat) -> ([NotchPeek.Part]) -> CGFloat {
        { parts in parts.contains(.name) ? name : 40 }
    }

    @Test func theLineGoesAcrossTheNotch() {
        let layout = NotchPeek.layout(room: .init(leading: 271, trailing: 271), hasName: true, width: Self.measure(name: 120))
        #expect(layout.leading == [.tool, .reason])
        #expect(layout.trailing == [.name])
        #expect(layout.leadingWidth == 40)
        #expect(layout.trailingWidth == 120, "A half takes what its words need, not the whole room.")
    }

    /// The owner's screenshot (2026-10-02): a long chat's name ran past DynamicNotchKit's window and "Finished" was
    /// cut to "Fini", square, at its edge. No half is wider than the window leaves it; the name truncates instead.
    @Test func aLongNameStopsAtTheWindowsEdge() {
        let layout = NotchPeek.layout(room: NotchPeek.builtIn, hasName: true, width: Self.measure(name: 900))
        #expect(layout.trailingWidth == NotchPeek.builtIn.trailing)
    }

    @Test func withNoNameTheWholeLineIsLeftOfTheNotch() {
        let layout = NotchPeek.layout(room: NotchPeek.builtIn, hasName: false, width: Self.measure(name: 0))
        #expect(layout.leading == [.tool, .reason])
        #expect(layout.trailing == [], "The right keeps its readouts.")
        #expect(layout.trailingWidth == 0)
    }

    /// DynamicNotchKit's window is the middle half of the screen it is on, and the strip's own edge (an 8 pt inset
    /// and a 6 pt corner) sits outside a half's content.
    @Test func theRoomIsWhatTheWindowLeavesBesideTheNotch() {
        let room = NotchPeek.windowRoom(screen: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                        notch: CGRect(x: 663.5, y: 950, width: 185, height: 32))
        #expect(room == NotchPeek.Room(leading: 271.5, trailing: 271.5))
        #expect(room == NotchPeek.builtIn)
        // A second screen to the right of the first: its window is centred on that screen, not on zero.
        let second = NotchPeek.windowRoom(screen: CGRect(x: 1512, y: 0, width: 1728, height: 1117),
                                          notch: CGRect(x: 1512 + 771.5, y: 1085, width: 185, height: 32))
        #expect(second == NotchPeek.Room(leading: 325.5, trailing: 325.5))
    }

    @Test func fullNamesTheAssistantAndWhatHappened() {
        #expect(news(.finished).words(hidesFigures: false).headline == "Claude Code finished")
        #expect(news(.approval).words(hidesFigures: false).headline == "Claude Code needs approval")
        #expect(news(.question).words(hidesFigures: false).headline == "Claude Code has a question")
        #expect(news(.input).words(hidesFigures: false).headline == "Claude Code needs input")
        #expect(news(.waiting).words(hidesFigures: false).headline == "Claude Code is waiting")
        #expect(news(.blocked).words(hidesFigures: false).headline == "Claude Code was blocked")
    }

    @Test @MainActor func compactLeavesTheWordsToTheNameUnlessThereIsNone() {
        let named = news(.finished).words(hidesFigures: false)
        #expect(NotchPeekHalf.label(named, style: .full) == "Claude Code finished")
        #expect(NotchPeekHalf.label(named, style: .compact) == "", "The symbols say who and what; the name has the line.")
        let shared = news(.finished).words(hidesFigures: true)
        #expect(NotchPeekHalf.label(shared, style: .compact) == "Finished", "With no name, the reason's own word.")
        #expect(NotchPeekHalf.label(shared, style: .full) == "Claude Code finished")
    }

    @Test @MainActor func compactTakesLessOfTheStripThanFull() {
        let words = news(.finished).words(hidesFigures: false)
        let compact = NotchPeekHalf.needed(parts: [.tool, .reason], words: words, style: .compact)
        let full = NotchPeekHalf.needed(parts: [.tool, .reason], words: words, style: .full)
        #expect(compact < full)
        #expect(compact == 2 * NotchPeekHalf.padding + 2 * (NotchPeekHalf.symbolSize + 2) + NotchPeekHalf.spacing,
                "Two symbols and nothing beside them.")
    }

    @Test func theSessionsTitleNamesThePeekBeforeTheFolder() {
        let words = news(.finished, project: "enrollhere-admin-support-tools").words(hidesFigures: false, title: "Fix the queue sheet")
        #expect(words.name == "Fix the queue sheet")
        #expect(news(.finished, project: "p").words(hidesFigures: false, title: nil).name == "p", "No title, the folder.")
        #expect(news(.finished, project: "p").words(hidesFigures: false, title: "").name == "p")
        #expect(news(.finished, project: "p").words(hidesFigures: true, title: "Fix the queue sheet").name == nil,
                "While the screen is shared no name at all, title or folder.")
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

    /// Since 0.9.10 the symbol sits in the middle of the rings whatever their count: the owner saw one symbol in its
    /// ring and the next beside its nest (2026-10-02), and the nest grows to `symbolSide` to make room.
    @Test func theSymbolHasRoomInTheMiddleOfEveryNest() {
        for rings in 1...3 {
            for quiet in [false, true] {
                #expect(CompactRings.hole(rings: rings, quiet: quiet) >= 6, "\(rings) ring(s), quiet \(quiet): a hole a symbol reads in")
            }
        }
        #expect(CompactRings.nest(count: 3, quiet: false, symbol: true)[0].diameter == CompactRings.symbolSide)
        #expect(CompactRings.nest(count: 3, quiet: false)[0].diameter == CompactRings.side, "Without the symbol the nest is as it was.")
    }

    /// The symbol takes no room of its own: the readout is its box, 22 pt with the symbol and 18 without.
    @Test func theReadoutIsItsBox() {
        for rings in 1...3 {
            #expect(CompactRings.width(rings: rings, symbol: true) == CompactRings.symbolSide)
            #expect(CompactRings.width(rings: rings, symbol: false) == CompactRings.side)
        }
    }

    /// Every assistant's symbol, drawn as the rings draw it, has its visible shape centred on the rings' centre and
    /// inside the clear disc of the innermost ring, at every ring count. Rendered, not reasoned about: an SF
    /// Symbol's box is not where its ink is. The glyph is drawn four times over (it is vector, so it scales
    /// cleanly) and measured there, so the reading is in quarter points rather than in the 2x render's half-point
    /// pixels, whose rounding alone reads as a quarter to half a point off.
    @Test @MainActor func everySymbolsInkIsCentredAndInsideTheInnermostRing() throws {
        let box = CompactRings.symbolSide, magnify: CGFloat = 4
        for tool in ToolID.allCases {
            for rings in 1...3 {
                let fit = min(CompactRings.hole(rings: rings, quiet: false), CompactRings.largestGlyph)
                let content = ToolGlyph(tool: tool, fit: fit).frame(width: box, height: box)
                    .scaleEffect(magnify).frame(width: box * magnify, height: box * magnify)
                let pixels = try #require(ImageRenderer(content: content).cgImage, "\(tool) renders")
                let image = NSImage(cgImage: pixels, size: NSSize(width: box * magnify, height: box * magnify))
                let ink = try #require(SymbolInk.measure(image), "\(tool) has ink")
                let offCentre: CGFloat = max(abs(ink.offset.width), abs(ink.offset.height)) / magnify
                let diagonal: CGFloat = (ink.width * ink.width + ink.height * ink.height).squareRoot() / magnify
                #expect(offCentre <= 0.15, "\(tool), \(rings) ring(s): ink centred within 0.15 pt, off by \(offCentre)")
                // A quarter point for the antialiased edge, which the measure counts as ink.
                #expect(diagonal <= fit + 0.25, "\(tool), \(rings) ring(s): ink \(diagonal) pt across fits the clear disc of \(fit) pt")
            }
        }
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
        let layout = NotchPeek.layout(room: NotchPeek.builtIn, hasName: true, width: Self.measure(name: 120))
        let speaking = [layout.leading, layout.trailing].filter(NotchPeek.speaks)
        #expect(speaking == [[.tool, .reason]], "Only the half with the reason is an element; the name's is hidden.")
        #expect(!NotchPeek.speaks([.name]))
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

    // MARK: Settings' Test in the notch

    @Test func theNotchTestGoesThroughAnnounceAndSaysWhereItShowed() {
        let (store, box) = makeStore()
        #expect(store.testNotchNews() == "Shown beside the notch.")
        #expect(store.peek?.reason == .finished)
        #expect(store.glowNews == store.peek)
        #expect(box.spoken.count == 1, "VoiceOver hears the test as it hears real news")
        store.endPeek()
    }

    /// A second press inside `NotchNews.repeatAfter` has to show again: a test that went quiet on its second try
    /// would read as a broken strip.
    @Test func aSecondNotchTestIsNotDroppedAsARepeat() {
        let (store, box) = makeStore()
        let now = Date()
        _ = store.testNotchNews(now: now)
        store.endPeek()
        #expect(store.testNotchNews(now: now.addingTimeInterval(2)) == "Shown beside the notch.")
        #expect(box.spoken.count == 2)
        store.endPeek()
    }

    @Test func theNotchTestSaysWhyItShowedNoWords() {
        let (store, _) = makeStore(canPeek: false)
        #expect(store.testNotchNews() == "Glowing under the notch. The words need the notch closed and on screen.")
        #expect(store.peek == nil)
        let (bare, _) = makeStore(glow: false, canPeek: false)
        #expect(bare.testNotchNews().hasPrefix("The notch can't show it right now"))
        let (off, box) = makeStore(news: false, glow: false)
        #expect(off.testNotchNews() == "Show news in the notch and Glow under the notch for news are both off.")
        #expect(box.spoken.isEmpty)
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
