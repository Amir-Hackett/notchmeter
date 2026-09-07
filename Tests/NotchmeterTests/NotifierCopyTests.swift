import Foundation
import Testing
@testable import Notchmeter

/// The banner copy for a session event names the session's tool, so a Cursor turn is announced as Cursor's and a
/// Claude Code turn reads exactly as it always has. `copy(for:session:)` is pure so the English is pinned without
/// Notification Center.
@Suite struct NotifierCopy {
    init() { Localization.use(language: "en") }

    let t0 = DateParsing.iso8601("2026-09-01T12:00:00Z")!

    func session(_ tool: ToolID, project: String? = "proj") -> AgentSession {
        AgentSession(id: tool == .claude ? "c1" : "\(tool.rawValue):c1", tool: tool, project: project, state: .idle, started: t0, lastEvent: t0, turnStarted: nil)
    }

    @Test func aFinishIsNamedAfterTheToolThatFinished() {
        #expect(ResetText.duration(600) == "10m")
        let cursor = Notifier.copy(for: .finished(turn: 600), session: session(.cursor))
        #expect(cursor.title == "Cursor finished")
        #expect(cursor.body == "Cursor finished a 10m turn in proj.")
        let claude = Notifier.copy(for: .finished(turn: 600), session: session(.claude))
        #expect(claude.title == "Claude Code finished")
        #expect(claude.body == "Claude Code finished a 10m turn in proj.", "Claude Code's banner reads as it always has")
        #expect(Notifier.copy(for: .finished(turn: 90), session: session(.cursor, project: nil)).body == "Cursor finished a 1m turn in a session.")
    }

    @Test func aWaitIsClaudesBecauseOnlyClaudeCanWait() {
        let claude = Notifier.copy(for: .waiting(blocking: true), session: session(.claude))
        #expect(claude.title == "Claude Code is waiting")
        #expect(claude.body == "Claude Code is waiting in proj.")
    }
}

/// One banner per session per ten minutes for a wait the session has stopped for. Nothing bounded that exemption
/// when it was written: the app is never told a permission prompt was answered (docs/hooks.md), the owner runs the
/// default permission mode, and a repo with no allow rules stops a session as often as the work needs. The clock is
/// injected throughout, so none of this sleeps.
@Suite struct WaitBannerCeiling {
    let t0 = DateParsing.iso8601("2026-09-01T12:00:00Z")!
    let terminal = "com.googlecode.iterm2"

    func held(_ blocking: Bool = true, frontmost: String? = "com.googlecode.iterm2", quiet: Bool = false, host: String? = nil,
              terminalRule: Bool = true, last: Date? = nil, at seconds: TimeInterval) -> Bool {
        Notifier.shouldSuppress(event: .waiting(blocking: blocking), frontmost: frontmost, quiet: quiet, host: host,
                                terminalRule: terminalRule, lastBlockingBanner: last, now: t0.addingTimeInterval(seconds))
    }

    @Test func theSecondBlockingWaitInsideTenMinutesIsHeld() {
        #expect(!held(last: nil, at: 0), "the first one still breaks through the terminal rule")
        #expect(held(last: t0, at: 1))
        #expect(held(last: t0, at: 599))
        #expect(!held(last: t0, at: 600), "the wait itself has expired by now, and so has its allowance")
        #expect(!held(last: t0, at: 6000))
        // A clock stepped backwards mutes nothing: a stamp in the future is a correction, not a banner a moment ago.
        #expect(!held(last: t0.addingTimeInterval(300), at: 0))
        #expect(!Notifier.within(t0.addingTimeInterval(1), of: t0))
        #expect(Notifier.within(t0, of: t0))
    }

    @Test func theCeilingGatesTheExemptionAndNothingElse() {
        // Off the terminal path the banner goes out exactly as it did before the ceiling existed.
        #expect(!held(frontmost: "com.apple.Safari", last: t0, at: 60))
        #expect(!held(frontmost: nil, last: t0, at: 60))
        #expect(!held(host: "mini", last: t0, at: 60), "a remote session is never suppressed, so never capped")
        #expect(!held(terminalRule: false, last: t0, at: 60))
        #expect(held(quiet: true, last: nil, at: 0), "quiet hours are still first and answer for the ceiling too")
        // The idle nudge never reaches the ceiling: it stays suppressed with a stamp and without one.
        #expect(held(false, last: nil, at: 60))
        #expect(held(false, last: t0, at: 60))
        #expect(Notifier.shouldSuppress(event: .finished(turn: 600), frontmost: terminal, quiet: false, lastBlockingBanner: t0, now: t0))
    }

    @Test func onlyADeliveredBlockingBannerSpendsTheAllowance() {
        var memory = WaitBannerMemory()
        func verdict(_ blocking: Bool = true, frontmost: String? = "com.googlecode.iterm2", quiet: Bool = false,
                     session: String = "a", at seconds: TimeInterval) -> WaitBannerMemory.Verdict {
            memory.verdict(for: .waiting(blocking: blocking), session: session, frontmost: frontmost, quiet: quiet,
                           host: nil, terminalRule: true, now: t0.addingTimeInterval(seconds))
        }
        #expect(verdict(at: 0) == .send)
        #expect(verdict(at: 120) == .capped(sinceLast: 120))
        #expect(verdict(at: 300) == .capped(sinceLast: 300), "a held banner never restamps: it is measured from the one that went out")
        #expect(verdict(at: 660) == .send)
        #expect(verdict(at: 700) == .capped(sinceLast: 40))
        #expect(verdict(false, frontmost: "com.apple.Safari", at: 800) == .send, "the idle nudge a browser let through")
        #expect(verdict(at: 900) == .capped(sinceLast: 240), "240, not 100: that nudge did not spend the blocking allowance")
        #expect(verdict(false, at: 950) == .held, "the nudge is held by the terminal rule, never by the ceiling")
        #expect(verdict(quiet: true, session: "b", at: 950) == .held, "a quiet hour is not a cap, and does not spend the allowance")
        // A banner delivered with a browser in front still records: the stamp is when this session last interrupted
        // the user, which does not depend on where they were looking when it did.
        #expect(verdict(frontmost: "com.apple.Safari", session: "b", at: 1000) == .send)
        #expect(verdict(session: "b", at: 1060) == .capped(sinceLast: 60))
        // And the ceiling gates the exemption, not the notification: the same session with the same live stamp,
        // one second later, banners anyway once the terminal is not the app in front.
        #expect(verdict(frontmost: "com.apple.Safari", session: "b", at: 1061) == .send)
    }

    @Test func everySessionHasAnAllowanceOfItsOwnAndSpentStampsAreDropped() {
        var memory = WaitBannerMemory()
        func verdict(_ session: String, at seconds: TimeInterval) -> WaitBannerMemory.Verdict {
            memory.verdict(for: .waiting(blocking: true), session: session, frontmost: terminal, quiet: false,
                           host: nil, terminalRule: true, now: t0.addingTimeInterval(seconds))
        }
        for index in 0 ..< 50 {
            #expect(verdict("s\(index)", at: Double(index) * 60) == .send, "another session's prompt is another blocked piece of work")
        }
        // Fifty sessions over fifty minutes: only the ten inside the last interval are still holding anything back,
        // which is what bounds the table across a long uptime.
        #expect(memory.stamps.count == 10)
        #expect(verdict("s49", at: 2941) == .capped(sinceLast: 1))
        #expect(verdict("fresh", at: 2941) == .send)
    }

    /// The allowance outlives the banner it counts. `UsageStore.withdrawWaiting` takes the notice down at every
    /// clearing event, and a clearing event is exactly what lets the next prompt raise a banner at all — so a memory
    /// that handed the allowance back when the wait ended would cap nothing whatever. The `Stop` that ends the wait
    /// arrives here as the finished turn, and must leave the stamp where it is.
    @Test func theWaitEndingDoesNotBuyAFreshBanner() {
        var memory = WaitBannerMemory()
        func verdict(_ event: Notifier.SessionEvent, at seconds: TimeInterval) -> WaitBannerMemory.Verdict {
            memory.verdict(for: event, session: "a", frontmost: terminal, quiet: false, host: nil, terminalRule: true,
                           now: t0.addingTimeInterval(seconds))
        }
        #expect(verdict(.waiting(blocking: true), at: 0) == .send)
        // The answer, then the Stop: the banner is withdrawn from Notification Center around here, and the finished
        // turn behind it is held by the terminal rule as it always was.
        #expect(verdict(.finished(turn: 600), at: 30) == .held)
        #expect(memory.stamps.count == 1, "the allowance is not handed back when the wait ends")
        #expect(verdict(.waiting(blocking: true), at: 60) == .capped(sinceLast: 60))
    }

    /// The shape the ceiling exists for: a repo with no allow rules prompting through an hour of work, a terminal in
    /// front throughout, each prompt a fresh `startedWaiting` behind its own clearing event. Six an hour is per
    /// session: two sessions prompting like this earn twelve between them.
    @Test func anHourOfPromptingIsBoundedAtSixBannersPerSession() {
        var memory = WaitBannerMemory()
        var sent = 0
        for minute in stride(from: 0, through: 58, by: 2) {
            let verdict = memory.verdict(for: .waiting(blocking: true), session: "a", frontmost: terminal, quiet: false,
                                         host: nil, terminalRule: true, now: t0.addingTimeInterval(Double(minute) * 60))
            if verdict == .send { sent += 1 }
        }
        #expect(sent == 6, "thirty prompts through one hour of default permission mode, six banners for that session")
        #expect(memory.stamps.count == 1)
    }
}
