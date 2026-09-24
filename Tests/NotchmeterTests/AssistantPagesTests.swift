import AppKit
import Foundation
import Testing
@testable import Notchmeter

/// Each assistant's own Settings page (SettingsPane.agent): its four switches are real preferences, kept as off-sets
/// under keys of their own beside the app-wide ones they sit under, and the store honours each for that assistant
/// alone — session reading, answering from the notch, limit notices and session notices.
@MainActor @Suite struct AssistantPageSwitches {
    let t0 = DateParsing.iso8601("2026-09-24T12:00:00Z")!

    func withSuite(_ name: String, _ body: (UserDefaults) throws -> Void) rethrows {
        let suite = "NotchmeterTests.AssistantPages.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    func store(_ defaults: UserDefaults, providers: [any UsageProvider] = [], configure: (Preferences) -> Void = { _ in }) -> UsageStore {
        let prefs = Preferences(defaults: defaults)
        prefs.notifyWaiting = true
        prefs.notifyFinished = true
        configure(prefs)
        return UsageStore(prefs: prefs, providers: providers, cache: ReadingCache(defaults: defaults), defaults: defaults, drainLog: nil, reportFile: nil)
    }

    func request(_ id: String, session: String, tool: ToolID) -> Hook.Message {
        var message = Hook.Message(event: "PermissionRequest", needsInput: true, sessionID: session, tool: tool)
        message.request = Hook.Request(id: id, kind: .permission(tool: "Bash", summary: "ls", detail: nil, suggestions: []))
        return message
    }

    // MARK: - The preferences

    /// A fresh install stores nothing and every assistant is on for all four; an assistant a later version adds is
    /// on too, because the sets name what is off. The app-wide keys keep the names they always had.
    @Test func everySwitchStartsOnAndPersistsUnderItsOwnKey() {
        withSuite("persist") { defaults in
            let prefs = Preferences(defaults: defaults)
            for tool in ToolID.allCases {
                #expect(prefs.readsSessions(of: tool))
                #expect(prefs.answersFromNotch(tool))
                #expect(prefs.notifiesLimits(of: tool))
                #expect(prefs.notifiesSessions(of: tool))
            }
            #expect(defaults.object(forKey: "sessionReadingOffTools") == nil, "nothing is written until a page is touched")
            prefs.sessionReadingOff = Preferences.switching(prefs.sessionReadingOff, .cursor, on: false)
            prefs.notchAnswersOff = Preferences.switching(prefs.notchAnswersOff, .codex, on: false)
            prefs.limitNoticesOff = Preferences.switching(prefs.limitNoticesOff, .copilot, on: false)
            prefs.sessionNoticesOff = Preferences.switching(prefs.sessionNoticesOff, .claude, on: false)
            #expect(defaults.stringArray(forKey: "sessionReadingOffTools") == ["cursor"])
            #expect(defaults.stringArray(forKey: "answerFromNotchOffTools") == ["codex"])
            #expect(defaults.stringArray(forKey: "limitNoticesOffTools") == ["copilot"])
            #expect(defaults.stringArray(forKey: "sessionNoticesOffTools") == ["claude"])
            #expect(defaults.object(forKey: "answerFromNotch") == nil, "the app-wide switch is its own key, untouched")
            let reloaded = Preferences(defaults: defaults)
            #expect(!reloaded.readsSessions(of: .cursor) && reloaded.readsSessions(of: .codex))
            #expect(!reloaded.answersFromNotch(.codex) && reloaded.answersFromNotch(.claude))
            #expect(!reloaded.notifiesLimits(of: .copilot) && reloaded.notifiesLimits(of: .claude))
            #expect(!reloaded.notifiesSessions(of: .claude) && reloaded.notifiesSessions(of: .codex))
            // A name no assistant answers to (a build that knew one this one does not) is dropped on load.
            defaults.set(["cursor", "someday"], forKey: "sessionReadingOffTools")
            #expect(Preferences(defaults: defaults).sessionReadingOff == [.cursor])
        }
    }

    /// Answering from the notch is the one gate that is the whole rule in one call: the app-wide switch, the
    /// assistant's sessions read, and its page's own switch.
    @Test func answeringFromTheNotchNeedsTheAppWideSwitchItsSessionsAndItsPage() {
        withSuite("answers") { defaults in
            let prefs = Preferences(defaults: defaults)
            #expect(prefs.answersFromNotch(.codex))
            prefs.notchAnswersOff = [.codex]
            #expect(!prefs.answersFromNotch(.codex))
            #expect(prefs.answersFromNotch(.claude))
            prefs.notchAnswersOff = []
            prefs.sessionReadingOff = [.claude]
            #expect(!prefs.answersFromNotch(.claude), "a request from sessions that are not read cannot be shown")
            prefs.sessionReadingOff = []
            prefs.answerFromNotch = false
            #expect(ToolID.allCases.allSatisfy { !prefs.answersFromNotch($0) })
        }
    }

    @Test func switchingMovesOneAssistantAndLeavesTheRest() {
        let off: Set<ToolID> = [.codex]
        #expect(Preferences.switching(off, .cursor, on: false) == [.codex, .cursor])
        #expect(Preferences.switching(off, .codex, on: true).isEmpty)
        #expect(Preferences.switching(off, .claude, on: true) == [.codex], "switching on what is on changes nothing")
    }

    /// The page offers *Answer from the notch* only where the hook has an event to answer.
    @Test func onlyAnAssistantWhoseHookCanBeAnsweredOffersIt() {
        #expect(ToolID.allCases.filter(\.hasAnswerableHook) == [.claude, .codex, .copilot])
    }

    // MARK: - Session reading

    /// Off, an event is kept out of the tracker entirely — no row, no wait, no notice, no hook counted as heard —
    /// and a request is answered nothing at once so the terminal asks. The oracle hears only the name and that
    /// the sessions are not read. Another assistant's events go on as before.
    @Test func anAssistantWhoseSessionsAreNotReadLeavesNothingInTheTracker() throws {
        try withSuite("readingOff") { defaults in
            let store = store(defaults) { $0.sessionReadingOff = [.codex] }
            var raised: [String] = []
            store.deliverSessionEvent = { _, session in raised.append(session.id) }
            var facts: [[String: Any]] = []
            store.emitHookFacts = { facts.append($0) }
            let (reply, peer) = try StoreDecisions.pair()
            defer { close(peer) }
            store.hookReceived(request("r1", session: "c1", tool: .codex), now: t0, reply: reply)
            #expect(reply.isAnswered, "the terminal asks at once")
            #expect(StoreDecisions.read(peer).isEmpty, "answered with nothing but the hang-up")
            #expect(store.sessions.all.isEmpty)
            #expect(store.sessions.knownCount(of: .codex) == nil, "a hook the app does not read is not a hook heard")
            #expect(raised.isEmpty)
            #expect(facts.count == 1)
            #expect(facts.first?["sessions"] as? String == "off")
            #expect(facts.first?["tool"] as? String == "codex")
            #expect(Set(facts.first?.keys.map { $0 } ?? []) == ["name", "tool", "sessions"], "no session, project or request reaches the oracle")

            store.hookReceived(Hook.Message(event: "UserPromptSubmit", needsInput: false, sessionID: "a1", project: "notchmeter"), now: t0)
            #expect(store.sessions.all.map(\.id) == ["a1"], "Claude Code's sessions are read as before")
            #expect(store.sessions.knownCount(of: .claude) == 1)
        }
    }

    /// Switching reading off takes what the tracker already holds of that assistant: its rows, its wait's notice,
    /// its request (the reply released, so the terminal asks), a glance about it, and its hook as heard. Another
    /// assistant's sessions stay.
    @Test func switchingReadingOffForgetsWhatIsAlreadyHeld() throws {
        try withSuite("forget") { defaults in
            let store = store(defaults)
            var withdrawn: [String] = []
            store.removeNotifications = { withdrawn += $0 }
            var ended: [String] = []
            store.promptEnded = { ended.append($0) }
            let (reply, peer) = try StoreDecisions.pair()
            defer { close(peer) }
            store.hookReceived(request("r1", session: "c1", tool: .codex), now: t0, reply: reply)
            store.hookReceived(Hook.Message(event: "UserPromptSubmit", needsInput: false, sessionID: "c2", tool: .codex), now: t0)
            store.hookReceived(Hook.Message(event: "UserPromptSubmit", needsInput: false, sessionID: "a1"), now: t0)
            let waiting = try #require(store.sessions.all.first { $0.id == "codex:c1" })
            store.attentionNotice = AttentionNotice(session: waiting, event: .waiting(blocking: true, kind: .permission))
            #expect(store.sessions.count == 3)
            #expect(!reply.isAnswered)

            store.forgetSessions(of: .codex)
            #expect(store.sessions.all.map(\.id) == ["a1"])
            #expect(store.sessions.knownCount(of: .codex) == nil)
            #expect(store.sessions.pending(now: t0).isEmpty)
            #expect(reply.isAnswered, "the parked request is handed back")
            #expect(ended == ["r1"])
            #expect(withdrawn.contains(Notifier.identifier(session: "codex:c1", kind: "waiting")))
            #expect(store.attentionNotice == nil)
            let before = store.sessions
            store.forgetSessions(of: .codex)
            #expect(store.sessions == before, "a second forget has nothing to take")
        }
    }

    /// The preference itself drives the forgetting, through the store's observation, the way titles off clears
    /// titles: the switch alone is enough, whatever the next event from that assistant may be.
    @Test func thePreferenceAloneForgetsTheSessions() async throws {
        let suite = "NotchmeterTests.AssistantPages.observed"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = store(defaults)
        store.hookReceived(Hook.Message(event: "UserPromptSubmit", needsInput: false, sessionID: "g1", tool: .antigravity), now: t0)
        #expect(store.sessions.count == 1)
        store.prefs.sessionReadingOff = [.antigravity]
        for _ in 0..<20 where store.sessions.count > 0 { await Task.yield() }
        #expect(store.sessions.count == 0)
    }

    /// Claude Code's status line carries the meter's windows either way, but makes no session row while Claude
    /// Code's sessions are not read: it would otherwise put back the row the switch took away.
    @Test func theStatusLineMakesNoSessionWhileClaudeCodesSessionsAreNotRead() {
        withSuite("statusline") { defaults in
            let store = store(defaults) { $0.sessionReadingOff = [.claude] }
            store.statuslineReceived(Statusline.Message(sessionID: "s1", project: "proj", model: "Opus", receivedAt: t0), now: t0)
            #expect(store.sessions.all.isEmpty)
            #expect(store.statusline?.sessionID == "s1", "the status line itself is still taken")
        }
    }

    /// The one thing an unread assistant's event still does, refresh its meter, keeps the read path's exceptions
    /// to the spacing: a rate limit or a quota resume says the figure on the ring is wrong, so the meter is read
    /// at once for either, while an ordinary event inside the spacing still waits.
    @Test func aRateLimitStillRefreshesAnUnreadAssistantsMeterAtOnce() async throws {
        let suite = "NotchmeterTests.AssistantPages.rateLimit"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let window = LimitWindow(id: "five_hour", label: "Session", usedFraction: 0.5, resetsAt: t0.addingTimeInterval(3600), periodDuration: Period.fiveHours)
        let reading = UsageReading(tool: .claude, windows: [window], plan: "Max", fetchedAt: t0, observedAt: nil)
        let store = store(defaults, providers: [FixtureProvider(reading: reading)]) { $0.sessionReadingOff = [.claude] }
        store.hookReceived(Hook.Message(event: "UserPromptSubmit", needsInput: false, sessionID: "a1"), now: t0)
        #expect(store.lastHookRefresh[.claude] == t0)
        store.hookReceived(Hook.Message(event: "Stop", needsInput: false, sessionID: "a1"), now: t0.addingTimeInterval(5))
        #expect(store.lastHookRefresh[.claude] == t0, "an ordinary event inside the spacing waits")
        store.hookReceived(Hook.Message(event: "StopFailure", needsInput: false, sessionID: "a1", failure: "rate_limit"), now: t0.addingTimeInterval(10))
        #expect(store.lastHookRefresh[.claude] == t0.addingTimeInterval(10), "a rate limit is read at once")
        store.hookReceived(Hook.Message(event: "Notification", needsInput: false, sessionID: "a1", notificationType: "quota_auto_resume_fired"),
                           now: t0.addingTimeInterval(15))
        #expect(store.lastHookRefresh[.claude] == t0.addingTimeInterval(15), "so is a quota resume")
        #expect(store.sessions.all.isEmpty, "and none of it made a row")
        // The reads the hooks started are queued on the main actor behind this test. An interactive read waits for
        // the one in flight and the rest find its slot taken, so none is left writing to the suite once it is emptied.
        await store.refresh(.claude, force: true, interactive: true)
        #expect(store.status(.claude).reading != nil)
    }

    // MARK: - Answering from the notch

    /// One assistant's page off: its request is answered nothing at once and is not held, while another
    /// assistant's request still parks for the notch.
    @Test func anAssistantsOwnAnswerSwitchHandsOnlyItsRequestsBack() throws {
        try withSuite("answerOff") { defaults in
            let store = store(defaults) { $0.notchAnswersOff = [.codex] }
            var prompted: [String] = []
            store.promptRequested = { _, request in prompted.append(request.id) }
            let codex = try StoreDecisions.pair()
            defer { close(codex.peer) }
            let claude = try StoreDecisions.pair()
            defer { close(claude.peer) }
            store.hookReceived(request("r-codex", session: "c1", tool: .codex), now: t0, reply: codex.reply)
            store.hookReceived(request("r-claude", session: "a1", tool: .claude), now: t0, reply: claude.reply)
            #expect(codex.reply.isAnswered)
            #expect(!claude.reply.isAnswered)
            #expect(prompted == ["r-claude"])
            #expect(store.sessions.pending(now: t0).map(\.request.id) == ["r-claude"])
            #expect(store.sessions.all.first { $0.id == "codex:c1" }?.isWaiting == true, "the wait is still shown, as with the app-wide switch off")
        }
    }

    // MARK: - Notices

    /// One assistant's session notices off: its waits and finished turns raise nothing, another's still do.
    @Test func anAssistantsSessionNoticesSwitchSilencesOnlyIt() {
        withSuite("sessionNotices") { defaults in
            let store = store(defaults) {
                $0.sessionNoticesOff = [.codex]
                $0.finishedAfterMinutes = 1
            }
            var raised: [String] = []
            store.deliverSessionEvent = { event, session in
                switch event {
                case .waiting: raised.append("wait \(session.id)")
                case .finished: raised.append("finish \(session.id)")
                }
            }
            for (tool, id) in [(ToolID.codex, "c1"), (.claude, "a1")] {
                store.hookReceived(Hook.Message(event: "UserPromptSubmit", needsInput: false, sessionID: id, tool: tool), now: t0)
                store.hookReceived(Hook.Message(event: "Notification", needsInput: true, sessionID: id, notificationType: "permission_prompt", tool: tool),
                                   now: t0.addingTimeInterval(1))
                store.hookReceived(Hook.Message(event: "Stop", needsInput: false, sessionID: id, tool: tool), now: t0.addingTimeInterval(120))
            }
            #expect(raised == ["wait a1", "finish a1"])
            #expect(store.sessions.all.count == 2, "the sessions are still read and shown")
        }
    }

    /// One assistant's limit notices off: a reading behind pace plans nothing for it and is not remembered as
    /// told, so switching the page back on reports it; another assistant's reading behind pace is told at once.
    @Test func anAssistantsLimitNoticesSwitchLeavesItOutOfThePlan() async throws {
        let suite = "NotchmeterTests.AssistantPages.limits"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date()
        func reading(_ tool: ToolID) -> UsageReading {
            UsageReading(tool: tool, windows: [LimitWindow(id: "session", label: "Session", usedFraction: 0.9, resetsAt: now.addingTimeInterval(4 * 3600),
                                                           periodDuration: Period.fiveHours)],
                         plan: nil, fetchedAt: now, observedAt: nil)
        }
        let store = store(defaults, providers: [FixtureProvider(reading: reading(.codex)), FixtureProvider(reading: reading(.cursor))]) {
            $0.limitNoticesOff = [.codex]
        }
        var told: [ToolID] = []
        store.deliverAlerts = { told += $0.map(\.tool) }
        await store.refresh(.codex, force: true)
        await store.refresh(.cursor, force: true)
        #expect(!told.isEmpty)
        #expect(!told.contains(.codex), "the page's switch kept Codex out: \(told)")
        #expect(told.contains(.cursor))
        told = []
        store.prefs.limitNoticesOff = []
        await store.refresh(.codex, force: true)
        #expect(told.contains(.codex), "nothing was remembered as told while it was off")
    }

    /// Its advice banners are its limit notices too: with the page's switch off, the extra-usage line a rise in
    /// Claude's credits makes stays on the strip and goes out as no banner, and is not remembered as sent, so
    /// switching the page back on sends it.
    @Test func anAssistantsLimitNoticesSwitchKeepsItsAdviceBannersIn() async throws {
        let suite = "NotchmeterTests.AssistantPages.advice"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date()
        // The last figure seen, an hour ago and lower, so this reading's is a rise and the month's first.
        let memory = ExtraUsageMemory(amountUSD: 1, seenAt: now.addingTimeInterval(-3600), risenIn: nil)
        defaults.set(try JSONEncoder().encode(memory), forKey: ExtraUsageMemory.defaultsKey)
        let reading = UsageReading(tool: .claude, windows: [
            LimitWindow(id: "five_hour", label: "Session", usedFraction: 0.2, resetsAt: now.addingTimeInterval(4 * 3600), periodDuration: Period.fiveHours),
            LimitWindow(id: "extra_usage", label: .key("Extra usage"), usedFraction: 0.05, resetsAt: nil, amountUSD: 5),
        ], plan: "Max", fetchedAt: now, observedAt: nil)
        let store = store(defaults, providers: [FixtureProvider(reading: reading)]) { $0.limitNoticesOff = [.claude] }
        var banners: [String] = []
        store.deliverAdvice = { banners += $0.map(\.id) }
        await store.refresh(.claude, force: true)
        #expect(store.advice.contains { $0.id.hasPrefix("extra/") }, "the strip still carries the line: \(store.advice.map(\.id))")
        #expect(banners.isEmpty, "the page's switch kept Claude's banner out: \(banners)")
        store.prefs.limitNoticesOff = []
        await store.refresh(.claude, force: true)
        #expect(banners.contains { $0.hasPrefix("extra/") }, "nothing was remembered as sent while it was off: \(banners)")
    }

    /// A watched reset of an assistant whose limit notices are off is neither announced nor lost before it passes,
    /// and once it has passed it goes unannounced, taking its period's notices down, so switching the page back
    /// on later cannot announce a reset that passed while it was off.
    @Test func aHeldResetIsKeptUntilItPassesAndThenDroppedUnannounced() async throws {
        let suite = "NotchmeterTests.AssistantPages.resets"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date()
        let window = LimitWindow(id: "session", label: "Session", usedFraction: 0.9, resetsAt: now.addingTimeInterval(600), periodDuration: Period.fiveHours)
        let reading = UsageReading(tool: .codex, windows: [window], plan: nil, fetchedAt: now, observedAt: nil)
        let store = store(defaults, providers: [FixtureProvider(reading: reading)]) { $0.limitNoticesOff = [.codex] }
        var told: [PaceAlert] = []
        store.deliverAlerts = { told += $0 }
        var withdrawn: [String] = []
        store.removeNotifications = { withdrawn += $0 }
        await store.refresh(.codex, force: true)
        store.checkResets(now: now.addingTimeInterval(60))
        #expect(told.isEmpty)
        #expect(withdrawn.isEmpty, "a reset still ahead is kept, not dropped")
        store.checkResets(now: now.addingTimeInterval(1200))
        #expect(told.isEmpty, "announced \(told.map(\.stage))")
        #expect(Set(withdrawn) == Set(PaceAlert.identifiers(tool: .codex, window: window)), "its period's notices come down at the reset")
        store.prefs.limitNoticesOff = []
        withdrawn = []
        store.checkResets(now: now.addingTimeInterval(1260))
        #expect(told.isEmpty, "a reset that passed while the page was off is never announced")
        #expect(withdrawn.isEmpty)
    }

    // MARK: - The page's words

    /// Where a page would list an assistant's windows it says instead why there are none, in the words the
    /// overview two rows above uses: an assistant that is off or not on this Mac is not waiting for a reading.
    @Test func aPageWithNoReadingSaysWhyRatherThanWaiting() {
        withSuite("noReading") { defaults in
            let store = store(defaults)
            #expect(SettingsView.statusText(installed: store.isInstalled(.antigravity), status: store.status(.antigravity)) == L("Not installed on this Mac"),
                    "a tool with no provider reads as not installed, whatever its status says")
            #expect(SettingsView.statusText(installed: false, status: .waiting) == L("Not installed on this Mac"))
            #expect(SettingsView.statusText(installed: true, status: .off) == L("Off"))
            #expect(SettingsView.statusText(installed: true, status: .waiting) == L("Waiting for the first reading"))
            #expect(SettingsView.statusText(installed: true, status: .failed("Signed out", cached: nil)) == "Signed out")
        }
    }
}

/// `SessionTracker.forget`: one assistant's sessions, set-aside ones included, with the waits and requests the
/// store has to take down, and that assistant's hook no longer counted as heard.
@Suite struct ForgettingAnAssistant {
    let t0 = DateParsing.iso8601("2026-09-24T12:00:00Z")!

    @Test func forgetTakesOneAssistantsSessionsAndReportsItsWaitsAndRequests() {
        var tracker = SessionTracker()
        var asking = Hook.Message(event: "PermissionRequest", needsInput: true, sessionID: "c1", tool: .codex)
        asking.request = Hook.Request(id: "r1", kind: .permission(tool: "Bash", summary: "ls", detail: nil, suggestions: []))
        tracker.apply(asking, now: t0)
        tracker.apply(Hook.Message(event: "UserPromptSubmit", needsInput: false, sessionID: "c2", tool: .codex), now: t0)
        tracker.apply(Hook.Message(event: "Stop", needsInput: false, sessionID: "c2", tool: .codex), now: t0.addingTimeInterval(1))
        tracker.dismiss("codex:c2")
        tracker.apply(Hook.Message(event: "UserPromptSubmit", needsInput: false, sessionID: "a1"), now: t0)
        let forgotten = tracker.forget(.codex)
        #expect(forgotten.sessions == ["codex:c1"])
        #expect(forgotten.waiting == ["codex:c1"])
        #expect(forgotten.requests == [SessionTracker.EndedRequest(sessionID: "codex:c1", requestID: "r1")])
        #expect(tracker.all.map(\.id) == ["a1"])
        #expect(tracker.dismissed.isEmpty, "a set-aside session goes too, with nothing kept to come back")
        #expect(tracker.knownCount(of: .codex) == nil)
        #expect(tracker.knownCount(of: .claude) == 1)
        #expect(tracker.forget(.codex) == SessionTracker.Forgotten())
    }
}

/// The Settings window's shape: the assistants' pages sit under Assistants in the user's order, each is found by
/// the search at its own blocks, and every row that moved to a page is still found there.
@Suite struct AssistantPagesInSettings {
    @Test func theSidebarNestsEachAssistantsPageUnderAssistantsInTheUsersOrder() throws {
        let order: [ToolID] = [.cursor, .claude, .copilot, .codex, .antigravity]
        let sidebar = SettingsPane.sidebar(order: order)
        let assistants = try #require(sidebar.firstIndex(of: .assistants))
        let pages = Array(sidebar[(assistants + 1)...].prefix(order.count))
        #expect(pages == order.map(SettingsPane.agent))
        #expect(sidebar.filter { $0.tool == nil } == SettingsPane.app, "the app's panes keep their order around them")
        #expect(SettingsPane.allCases.count == SettingsPane.app.count + ToolID.allCases.count)
    }

    /// Every row that left the Assistants list, Integrations or Privacy for a page is found on that page; one that
    /// is the same for every assistant stays where it was.
    @Test func everyMovedRowIsFoundOnItsAssistantsPage() throws {
        let entries = SettingsSearch.entries()
        func lands(_ query: String, from current: SettingsPane = .general) throws -> SettingsSearch.Hit {
            try #require(SettingsSearch.hit(for: query, current: current, in: entries), "\(query) finds nothing")
        }
        #expect(try lands("Also read Codex reset credits").pane == .agent(.codex))
        #expect(try lands("Also read Cursor's usage events").pane == .agent(.cursor))
        #expect(try lands("Also read organisation billing").pane == .agent(.copilot))
        #expect(try lands("Also poll Claude's usage endpoint").pane == .agent(.claude))
        #expect(try lands("Ask for Keychain access").sections == [.agent(.claude, .sources)])
        #expect(try lands("Also read transcripts from").sections == [.agent(.claude, .sources)])
        #expect(try lands("Claude Code status line").sections == [.agent(.claude, .hook)])
        #expect(try lands("Gemini CLI hook").pane == .agent(.antigravity))
        #expect(try lands("In the Cost card").pane == .agent(.claude))
        #expect(try lands("Keep the Mac awake").sections == [.sessions], "it counts every assistant's sessions")
        #expect(try lands("Repair a hook that points").pane == .integrations)
        // The app-wide switch comes first in the window's order; on a page that has its own, the page's is found.
        #expect(try lands("Answer from the notch").pane == .assistants)
        #expect(try lands("Answer from the notch", from: .agent(.codex)).pane == .agent(.codex))
        #expect(try lands("Answer from the notch", from: .agent(.cursor)).pane == .assistants, "Cursor's page has none to find")
        #expect(try lands("Read its sessions", from: .agent(.cursor)).sections.count == ToolID.allCases.count)
        #expect(try lands("Notify about its limits").pane == .agent(.claude))
        #expect(try lands("Where each window comes from", from: .agent(.copilot)).pane == .agent(.copilot))
    }

    /// A page holds only the rows it draws: no answer switch where the hook has nothing to answer, no Cost card
    /// switch where the assistant cannot report spend, and each second read on its own assistant alone.
    @Test func aPageIndexesOnlyTheRowsItDraws() {
        func titles(_ tool: ToolID) -> Set<String> { Set(SettingsSearch.agentEntries(tool).map(\.title)) }
        #expect(!titles(.cursor).contains(L("Answer from the notch")))
        #expect(!titles(.antigravity).contains(L("Answer from the notch")))
        #expect(titles(.copilot).contains(L("Answer from the notch")))
        #expect(!titles(.antigravity).contains(L("In the Cost card")))
        #expect(titles(.cursor).contains(L("In the Cost card")))
        #expect(!titles(.codex).contains(L("Also read Cursor's usage events")))
        #expect(titles(.claude).contains(L("Claude Code status line")))
        #expect(!titles(.codex).contains(L("Claude Code status line")))
        for tool in ToolID.allCases {
            #expect(SettingsSearch.agentEntries(tool).first?.title == tool.productName, "a page is found by its own name first")
        }
    }

    /// A search opens *Where each window comes from* only for a match inside it: the disclosure's own rows index
    /// apart from the switches under it, so "keychain" lands on Claude Code's Sources block without unfolding
    /// the window list above the picker it matched.
    @Test func onlyTheRowsInsideTheSourcesDisclosureIndexAsInsideIt() {
        let entries = SettingsSearch.entries()
        func sections(_ query: String) -> Set<SettingsSection> { SettingsSearch.sections(matching: query, in: entries) }
        #expect(sections("keychain") == [.agent(.claude, .sources)])
        #expect(sections("Also read Codex reset credits") == [.agent(.codex, .sources)])
        #expect(sections("Where each window comes from") == Set(ToolID.allCases.map { .agent($0, .sourcesDetail) }))
        #expect(sections("Readings").contains(.agent(.cursor, .sourcesDetail)))
        #expect(!sections("Readings").contains(.agent(.cursor, .sources)))
        #expect(sections("Sources").isSuperset(of: ToolID.allCases.map { .agent($0, .sources) }))
    }

    /// The user's order decides which page a row every page has lands on, as it decides the sidebar's.
    @Test func aRowEveryPageHasLandsOnTheFirstAssistantInTheUsersOrder() throws {
        let entries = SettingsSearch.entries(order: [.codex, .claude, .cursor, .antigravity, .copilot])
        let hit = try #require(SettingsSearch.hit(for: "pin to menu bar", current: .general, in: entries))
        #expect(hit.pane == .agent(.codex))
        #expect(hit.sections.count == ToolID.allCases.count)
    }

    /// Every source a window can carry has words for the page, and no two read alike.
    @Test func everyWindowSourceHasItsOwnWords() {
        let sources: [WindowSource] = [.vendorEndpoint, .statusline, .rateLimitHeaders, .localSnapshot, .localEstimate]
        let names = sources.map(\.name)
        #expect(names.allSatisfy { !$0.isEmpty })
        #expect(Set(names).count == sources.count)
    }
}
