import Foundation
import Testing
@testable import Notchmeter

/// The lines a Cowork task's log (`audit.jsonl`) writes, in the shape the Agent SDK writes them: the type first,
/// a subtype for results, and `_audit_timestamp` on every line.
enum CoworkLines {
    static func stamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func prompt(_ text: String, at date: Date, replay: Bool = false, synthetic: Bool = false, parent: String? = nil) -> String {
        let flags = (replay ? #","isReplay":true"# : "") + (synthetic ? #","isSynthetic":true"# : "")
        let parentValue = parent.map { #""\#($0)""# } ?? "null"
        return #"{"type":"user","uuid":"u","session_id":"s","parent_tool_use_id":\#(parentValue),"message":{"role":"user","content":"\#(text)"}\#(flags),"_audit_timestamp":"\#(stamp(date))"}"#
    }

    static func blocksPrompt(at date: Date) -> String {
        #"{"type":"user","uuid":"u","session_id":"s","parent_tool_use_id":null,"message":{"role":"user","content":[{"type":"text","text":"look at this"},{"type":"image","source":{}}]},"_audit_timestamp":"\#(stamp(date))"}"#
    }

    static func toolResult(at date: Date) -> String {
        #"{"type":"user","uuid":"u","session_id":"s","parent_tool_use_id":null,"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]},"_audit_timestamp":"\#(stamp(date))"}"#
    }

    static func assistant(at date: Date) -> String {
        #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"working on it"}]},"parent_tool_use_id":null,"session_id":"s","uuid":"a","request_id":"r","_audit_timestamp":"\#(stamp(date))"}"#
    }

    static func status(at date: Date) -> String {
        #"{"type":"system","subtype":"status","status":null,"uuid":"x","session_id":"s","_audit_timestamp":"\#(stamp(date))"}"#
    }

    static func result(at date: Date, seconds: Double, subtype: String = "success", error: Bool = false) -> String {
        #"{"type":"result","subtype":"\#(subtype)","is_error":\#(error),"duration_ms":\#(Int(seconds * 1000)),"result":"done","session_id":"s","_audit_timestamp":"\#(stamp(date))"}"#
    }

    static func turn(_ lines: [String]) -> CoworkSessions.Turn {
        var turn = CoworkSessions.Turn()
        for line in lines { turn.read(Data(line.utf8)) }
        return turn
    }
}

/// The task's record: only the named keys are kept, whatever else the file holds.
@Suite struct CoworkRecord {
    @Test func keepsTheTitleTheFirstFolderTheLastActivityAndTheArchiveFlagAndNothingElse() throws {
        let record: [String: Any] = [
            "sessionId": "local_1", "cliSessionId": "abc", "title": "Compare the vendors\nand then more", "cwd": "/sessions/gifted-dreamy-knuth",
            "userSelectedFolders": ["", "/Users/me/Documents/Research", "/Users/me/Desktop"], "createdAt": 1_790_000_000_000,
            "lastActivityAt": 1_790_000_123_456, "isArchived": false, "systemPrompt": "a very long prompt", "emailAddress": "me@example.com",
            "accountName": "Me",
        ]
        let parsed = try #require(CoworkSessions.metadata(from: JSONSerialization.data(withJSONObject: record)))
        let expected = CoworkSessions.Metadata(title: "Compare the vendors", folder: "/Users/me/Documents/Research",
                                               lastActivity: Date(timeIntervalSince1970: 1_790_000_123.456), archived: false)
        #expect(parsed == expected)
    }

    @Test func aLongTitleIsCutAsAPromptLineIsAndAMissingOneIsNil() throws {
        let long = String(repeating: "word ", count: 40)
        let parsed = try #require(CoworkSessions.metadata(from: JSONSerialization.data(withJSONObject: ["title": long, "isArchived": true])))
        #expect(parsed.title == Hook.title(fromPrompt: long))
        #expect(parsed.title?.hasSuffix("…") == true)
        #expect(parsed.archived)
        #expect(parsed.folder == nil)
        let bare = try #require(CoworkSessions.metadata(from: JSONSerialization.data(withJSONObject: ["title": "  "])))
        #expect(bare.title == nil)
        #expect(bare.lastActivity == nil)
        #expect(CoworkSessions.metadata(from: Data("{not json".utf8)) == nil)
    }
}

/// What the task's log says of its turns, a line at a time.
@Suite struct CoworkLog {
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func aPromptOpensATurnAndTheResultLineEndsItWithItsOwnDuration() throws {
        let running = CoworkLines.turn([CoworkLines.prompt("hi", at: t0), CoworkLines.assistant(at: t0.addingTimeInterval(2)),
                                        CoworkLines.toolResult(at: t0.addingTimeInterval(5))])
        #expect(running.open)
        #expect(running.began == t0)
        #expect(running.end == nil)
        let ended = CoworkLines.turn([CoworkLines.prompt("hi", at: t0), CoworkLines.assistant(at: t0.addingTimeInterval(2)),
                                      CoworkLines.result(at: t0.addingTimeInterval(90), seconds: 89.5)])
        #expect(!ended.open)
        #expect(ended.began == t0)
        let end = try #require(ended.end)
        #expect(end.at == t0.addingTimeInterval(90))
        #expect(end.duration == 89.5)
        #expect(!end.failed)
    }

    /// Only the user's own words start a turn: a turn replayed on resume, an attachment the app added, a
    /// subagent's prompt and a tool's result are not prompts. A prompt made of blocks (text and an image) is.
    @Test func onlyTheUsersOwnWordsStartATurn() {
        let ended = [CoworkLines.prompt("first", at: t0), CoworkLines.result(at: t0.addingTimeInterval(10), seconds: 10)]
        for line in [CoworkLines.prompt("again", at: t0.addingTimeInterval(20), replay: true),
                     CoworkLines.prompt("attached", at: t0.addingTimeInterval(20), synthetic: true),
                     CoworkLines.prompt("sub", at: t0.addingTimeInterval(20), parent: "toolu_1"),
                     CoworkLines.toolResult(at: t0.addingTimeInterval(20)),
                     CoworkLines.status(at: t0.addingTimeInterval(20))] {
            let turn = CoworkLines.turn(ended + [line])
            #expect(!turn.open, "\(line) reopened the turn")
            #expect(turn.began == t0)
        }
        let blocks = CoworkLines.turn(ended + [CoworkLines.blocksPrompt(at: t0.addingTimeInterval(30))])
        #expect(blocks.open)
        #expect(blocks.began == t0.addingTimeInterval(30))
        // The end before it is kept, so a turn that ended between two reads is still seen to have ended.
        #expect(blocks.end?.at == t0.addingTimeInterval(10))
    }

    /// A model step after an end, with no prompt seen, is a turn that began no later than that step.
    @Test func aModelStepAfterAnEndReopensTheTurnFromItsOwnTime() {
        let turn = CoworkLines.turn([CoworkLines.result(at: t0, seconds: 5), CoworkLines.assistant(at: t0.addingTimeInterval(40))])
        #expect(turn.open)
        #expect(turn.began == t0.addingTimeInterval(40))
    }

    /// A request to the user is the last thing the log says until the next line, which is its answer.
    @Test func aRequestIsAskingUntilTheNextLine() {
        let request = #"{"type":"system","subtype":"permission_request","uuid":"p","session_id":"s","tool_name":"AskUserQuestion","tool_input":{},"_audit_timestamp":"\#(CoworkLines.stamp(t0))"}"#
        let response = #"{"type":"system","subtype":"permission_response","uuid":"q","session_id":"s","tool_name":"AskUserQuestion","decision":"once","granted":true,"_audit_timestamp":"\#(CoworkLines.stamp(t0.addingTimeInterval(40)))"}"#
        let asking = CoworkLines.turn([CoworkLines.prompt("hi", at: t0.addingTimeInterval(-5)), request])
        #expect(asking.asking)
        #expect(asking.open)
        let answered = CoworkLines.turn([CoworkLines.prompt("hi", at: t0.addingTimeInterval(-5)), request, response])
        #expect(!answered.asking)
        #expect(answered.open)
    }

    @Test func anErrorEndsTheTurnAsAFailure() {
        for line in [CoworkLines.result(at: t0, seconds: 3, subtype: "error_during_execution"),
                     CoworkLines.result(at: t0, seconds: 3, error: true)] {
            let turn = CoworkLines.turn([CoworkLines.prompt("hi", at: t0.addingTimeInterval(-3)), line])
            #expect(!turn.open)
            #expect(turn.end?.failed == true)
        }
    }

    /// A log with neither a prompt nor an end in view (read from the middle of a turn) is open, from nobody knows
    /// when: whether it runs is the clock's to say.
    @Test func theMiddleOfATurnIsOpenWithNoStart() {
        let turn = CoworkLines.turn([CoworkLines.assistant(at: t0), CoworkLines.toolResult(at: t0.addingTimeInterval(1))])
        #expect(turn.open)
        #expect(turn.began == nil)
    }

    /// Chunks split lines anywhere; a line is read once it is whole, and one that outgrows the limit (a tool's
    /// output) is skipped whole without losing the lines after it.
    @Test func chunksAreReadLineByLineAndAnOverlongLineIsSkipped() {
        let text = [CoworkLines.prompt("hi", at: t0), CoworkLines.result(at: t0.addingTimeInterval(9), seconds: 9)].joined(separator: "\n") + "\n"
        let bytes = Data(text.utf8)
        for split in [1, 17, bytes.count / 2, bytes.count - 1] {
            var turn = CoworkSessions.Turn()
            var partial = Data()
            var skipping = false
            turn.read(bytes.prefix(split), partial: &partial, skipping: &skipping)
            turn.read(bytes.suffix(from: split), partial: &partial, skipping: &skipping)
            #expect(!turn.open, "split at \(split)")
            #expect(turn.end?.duration == 9)
            #expect(partial.isEmpty)
        }
        let huge = #"{"type":"user","message":{"content":""# + String(repeating: "x", count: CoworkSessions.lineLimit + 10) + #""}}"#
        var turn = CoworkSessions.Turn()
        var partial = Data()
        var skipping = false
        let prompt = CoworkLines.prompt("after", at: t0.addingTimeInterval(20)) + "\n"
        let stream = Data((huge + "\n" + prompt).utf8)
        turn.read(stream.prefix(CoworkSessions.lineLimit / 2), partial: &partial, skipping: &skipping)
        turn.read(stream.dropFirst(CoworkSessions.lineLimit / 2).prefix(CoworkSessions.lineLimit), partial: &partial, skipping: &skipping)
        turn.read(stream.dropFirst(CoworkSessions.lineLimit / 2 + CoworkSessions.lineLimit), partial: &partial, skipping: &skipping)
        #expect(turn.began == t0.addingTimeInterval(20))
        #expect(partial.isEmpty)
    }
}

/// The rule that puts a Cowork task on the Sessions card: working while its log is written with a turn open, a
/// finish only at the log's own end line, never a wait.
@Suite struct CoworkTracking {
    init() { Localization.use(language: "en") }

    let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    let key = CoworkSessions.key("local_1")

    func task(_ turn: CoworkSessions.Turn, wrote ago: TimeInterval, at now: Date, id: String = "local_1", title: String? = "Compare vendors",
              project: String? = "Research") -> CoworkSessions.Observation {
        CoworkSessions.Observation(id: id, title: title, project: project, lastWrite: now.addingTimeInterval(-ago), turn: turn)
    }

    func running(since began: Date?) -> CoworkSessions.Turn { CoworkSessions.Turn(began: began, end: nil, open: true) }

    func ended(began: Date?, at: Date, seconds: TimeInterval?, failed: Bool = false) -> CoworkSessions.Turn {
        CoworkSessions.Turn(began: began, end: CoworkSessions.Turn.End(at: at, duration: seconds, failed: failed), open: false)
    }

    @Test func aTaskWrittenToWithATurnOpenIsAClaudeSessionAtWorkClockedFromItsPrompt() throws {
        var tracker = SessionTracker()
        let outcome = tracker.observeCowork([task(running(since: t0.addingTimeInterval(-70)), wrote: 3, at: t0)], now: t0)
        let session = try #require(tracker.sessions[key])
        #expect(session.tool == .claude)
        #expect(session.source == .coworkLog)
        #expect(session.assistantName == "Cowork")
        #expect(session.productName == "Claude Cowork")
        #expect(session.project == "Research")
        #expect(session.displayTitle == "Compare vendors")
        #expect(session.terminal?.bundleID == CoworkSessions.bundleID)
        #expect(session.state == .working(since: t0.addingTimeInterval(-70)))
        #expect(session.lastEvent == t0.addingTimeInterval(-3))
        #expect(outcome.changes.map(\.kind) == [.seen, .working])
        #expect(tracker.isWorking(.claude))
        // A file is no proof about Claude Code's hook, so the calm rule's count stays unknown.
        #expect(tracker.knownCount(of: .claude) == nil)
        #expect(!tracker.hookSeen)
    }

    @Test func theLogsEndLineFinishesTheTurnForItsOwnDuration() throws {
        var tracker = SessionTracker()
        let began = t0.addingTimeInterval(-300)
        tracker.observeCowork([task(running(since: began), wrote: 2, at: t0)], now: t0)
        let later = t0.addingTimeInterval(10)
        let outcome = tracker.observeCowork([task(ended(began: began, at: t0.addingTimeInterval(8), seconds: 307), wrote: 2, at: later)], now: later)
        let session = try #require(tracker.sessions[key])
        #expect(session.state == .idle)
        #expect(outcome.finished.count == 1)
        #expect(outcome.finished.first?.turn == 307)
        #expect(outcome.changes == [SessionTracker.CoworkChange(session: key, kind: .finished, turn: 307)])
        let finish = try #require(tracker.finish(of: .claude, now: later))
        #expect(finish.at == t0.addingTimeInterval(8))
        #expect(finish.turn == 307)
        // With no duration on the line, the turn is the end less the start the row was given.
        var bare = SessionTracker()
        bare.observeCowork([task(running(since: began), wrote: 2, at: t0)], now: t0)
        let plain = bare.observeCowork([task(ended(began: began, at: t0.addingTimeInterval(8), seconds: nil), wrote: 2, at: later)], now: later)
        #expect(plain.finished.first?.turn == 308)
    }

    /// A turn that goes quiet with no end line claims nothing: it is idle, not finished, and never a wait.
    @Test func aTurnThatGoesQuietWithoutAnEndIsIdleAndNotFinished() throws {
        var tracker = SessionTracker()
        tracker.observeCowork([task(running(since: t0.addingTimeInterval(-60)), wrote: 1, at: t0)], now: t0)
        let quiet = t0.addingTimeInterval(CoworkSessions.busyWindow + 5)
        let outcome = tracker.observeCowork([task(running(since: t0.addingTimeInterval(-60)), wrote: CoworkSessions.busyWindow + 4, at: quiet)], now: quiet)
        #expect(tracker.sessions[key]?.state == .idle)
        #expect(outcome.finished.isEmpty)
        #expect(outcome.changes.map(\.kind) == [.idle])
        #expect(tracker.finish(of: .claude, now: quiet) == nil)
        #expect(tracker.waiting.isEmpty)
        // It works again when its log moves again, clocked from the same prompt.
        let resumed = quiet.addingTimeInterval(20)
        tracker.observeCowork([task(running(since: t0.addingTimeInterval(-60)), wrote: 1, at: resumed)], now: resumed)
        #expect(tracker.sessions[key]?.state == .working(since: t0.addingTimeInterval(-60)))
    }

    /// Stopped at a request to the user: idle once the request has stood past the grace (an "always" rule answers
    /// faster), never a wait; working again on the same clock when the log moves on, and its end line still finishes
    /// it, even when the answer and the end fall between two reads.
    @Test func aTurnStoppedAtARequestIsIdleAndStillFinishesAtItsEndLine() throws {
        var tracker = SessionTracker()
        let began = t0.addingTimeInterval(-60)
        var asking = running(since: began)
        asking.asking = true
        tracker.observeCowork([task(asking, wrote: CoworkSessions.askGrace - 1, at: t0)], now: t0)
        #expect(tracker.sessions[key]?.isWorking == true, "a request answered inside the grace is not a stop")
        let stopped = t0.addingTimeInterval(10)
        let outcome = tracker.observeCowork([task(asking, wrote: 10 + CoworkSessions.askGrace - 1, at: stopped)], now: stopped)
        #expect(tracker.sessions[key]?.state == .idle)
        #expect(outcome.changes.map(\.kind) == [.idle])
        #expect(tracker.waiting.isEmpty)
        let answered = stopped.addingTimeInterval(60)
        let end = CoworkSessions.Turn.End(at: answered.addingTimeInterval(-1), duration: 128, failed: false)
        let finished = tracker.observeCowork([task(CoworkSessions.Turn(began: began, end: end, open: false), wrote: 1, at: answered)], now: answered)
        #expect(finished.finished.first?.turn == 128)
        #expect(tracker.sessions[key]?.finish(now: answered) != nil)
    }

    @Test func aTurnThatResumesAfterAQuietSpellKeepsItsClock() {
        var tracker = SessionTracker()
        tracker.observeCowork([task(running(since: nil), wrote: 1, at: t0)], now: t0)
        let quiet = t0.addingTimeInterval(CoworkSessions.busyWindow + 10)
        tracker.observeCowork([task(running(since: nil), wrote: CoworkSessions.busyWindow + 5, at: quiet)], now: quiet)
        #expect(tracker.sessions[key]?.state == .idle)
        let back = quiet.addingTimeInterval(5)
        tracker.observeCowork([task(running(since: nil), wrote: 1, at: back)], now: back)
        #expect(tracker.sessions[key]?.state == .working(since: t0), "the clock the row first had, not the resume")
        // A prompt after the held start is a turn of its own, clocked from it.
        let next = back.addingTimeInterval(CoworkSessions.busyWindow + 10)
        tracker.observeCowork([task(running(since: nil), wrote: CoworkSessions.busyWindow + 5, at: next)], now: next)
        let prompt = next.addingTimeInterval(2)
        tracker.observeCowork([task(running(since: prompt), wrote: 0, at: prompt.addingTimeInterval(1))], now: prompt.addingTimeInterval(1))
        #expect(tracker.sessions[key]?.state == .working(since: prompt))
    }

    @Test func aFailedTurnEndsWithoutAFinish() {
        var tracker = SessionTracker()
        tracker.observeCowork([task(running(since: t0.addingTimeInterval(-60)), wrote: 1, at: t0)], now: t0)
        let later = t0.addingTimeInterval(5)
        let outcome = tracker.observeCowork([task(ended(began: t0.addingTimeInterval(-60), at: t0.addingTimeInterval(4), seconds: 64, failed: true),
                                                  wrote: 1, at: later)], now: later)
        #expect(tracker.sessions[key]?.state == .idle)
        #expect(outcome.finished.isEmpty)
        #expect(outcome.changes.map(\.kind) == [.idle])
    }

    /// A short turn that ended and a new one that began between two reads: the end is reported, and the row is
    /// working again on the new turn's clock.
    @Test func anEndAndANewTurnBetweenTwoReadsAreBothSeen() throws {
        var tracker = SessionTracker()
        let first = t0.addingTimeInterval(-40)
        tracker.observeCowork([task(running(since: first), wrote: 1, at: t0)], now: t0)
        let later = t0.addingTimeInterval(5)
        let turn = CoworkSessions.Turn(began: t0.addingTimeInterval(4), end: .init(at: t0.addingTimeInterval(2), duration: 42, failed: false), open: true)
        let outcome = tracker.observeCowork([task(turn, wrote: 0, at: later)], now: later)
        #expect(outcome.finished.first?.turn == 42)
        #expect(outcome.changes.map(\.kind) == [.finished, .working])
        #expect(tracker.sessions[key]?.state == .working(since: t0.addingTimeInterval(4)))
        #expect(tracker.sessions[key]?.finished == nil, "a new turn clears the finish, as a prompt does")
    }

    /// The app launching after a turn ended sees an idle task, and announces nothing it did not watch run.
    @Test func aTurnThatEndedBeforeTheAppLookedIsNotAnnounced() {
        var tracker = SessionTracker()
        let outcome = tracker.observeCowork([task(ended(began: t0.addingTimeInterval(-200), at: t0.addingTimeInterval(-10), seconds: 190), wrote: 10, at: t0)],
                                            now: t0)
        #expect(tracker.sessions[key]?.state == .idle)
        #expect(outcome.finished.isEmpty)
        #expect(outcome.changes.map(\.kind) == [.seen])
    }

    /// A turn whose prompt was not among the lines read clocks from when the app first saw it running.
    @Test func aTurnWithNoPromptInViewClocksFromWhenItWasFirstSeen() {
        var tracker = SessionTracker()
        tracker.observeCowork([task(running(since: nil), wrote: 2, at: t0)], now: t0)
        #expect(tracker.sessions[key]?.state == .working(since: t0))
        var future = SessionTracker()
        future.observeCowork([task(running(since: t0.addingTimeInterval(60)), wrote: 2, at: t0)], now: t0)
        #expect(future.sessions[key]?.state == .working(since: t0), "a clock is never started in the future")
    }

    /// Leaving the read is leaving the list: an archived or long-quiet task, or every task when the Claude app quits
    /// (the store passes none). The hooks' sessions are not touched.
    @Test func aTaskNoLongerReadLeavesTheListAndTheHooksSessionsStay() {
        var tracker = SessionTracker()
        tracker.apply(Hook.Message(event: "UserPromptSubmit", needsInput: false, sessionID: "a", project: "notchmeter"), now: t0)
        tracker.observeCowork([task(running(since: t0), wrote: 1, at: t0), task(running(since: t0), wrote: 1, at: t0, id: "local_2")], now: t0)
        #expect(tracker.count == 3)
        let one = tracker.observeCowork([task(running(since: t0), wrote: 1, at: t0.addingTimeInterval(5))], now: t0.addingTimeInterval(5))
        #expect(one.changes.contains(SessionTracker.CoworkChange(session: CoworkSessions.key("local_2"), kind: .gone)))
        let none = tracker.observeCowork([], now: t0.addingTimeInterval(10))
        #expect(none.changes == [SessionTracker.CoworkChange(session: key, kind: .gone)])
        #expect(tracker.all.map(\.id) == ["a"])
        #expect(tracker.sessions["a"]?.isWorking == true)
    }

    /// Clear sets a Cowork task aside like any idle session, and the next read does not bring it back; its log
    /// being written again does.
    @Test func aTaskSetAsideStaysAsideUntilItsLogMoves() {
        var tracker = SessionTracker()
        let old = ended(began: t0.addingTimeInterval(-90), at: t0.addingTimeInterval(-60), seconds: 30)
        tracker.observeCowork([task(old, wrote: 60, at: t0)], now: t0)
        #expect(tracker.dismissIdle() == [key])
        tracker.observeCowork([task(old, wrote: 65, at: t0.addingTimeInterval(5))], now: t0.addingTimeInterval(5))
        #expect(tracker.sessions[key] == nil)
        let later = t0.addingTimeInterval(20)
        tracker.observeCowork([task(running(since: t0.addingTimeInterval(18)), wrote: 1, at: later)], now: later)
        #expect(tracker.sessions[key]?.isWorking == true)
        // A set-aside task that leaves the read is forgotten altogether rather than kept for four hours.
        tracker.dismiss(key)
        tracker.observeCowork([], now: later.addingTimeInterval(1))
        #expect(tracker.dismissed[key] == nil)
    }

    @Test func titlesOffClearsACoworkTasksTitleToo() {
        var tracker = SessionTracker()
        tracker.observeCowork([task(running(since: t0), wrote: 1, at: t0)], now: t0)
        tracker.clearTitles()
        #expect(tracker.sessions[key]?.displayTitle == nil)
    }

    @Test func theWatchReadsMoreSlowlyOnBatteryWithNothingListedAndSlowestWithNobodyAtTheScreen() {
        #expect(CoworkSessions.pollInterval(onBattery: false, lowPower: false, unattended: false, listed: true) == 5)
        #expect(CoworkSessions.pollInterval(onBattery: true, lowPower: false, unattended: false, listed: true) == 10)
        #expect(CoworkSessions.pollInterval(onBattery: false, lowPower: true, unattended: false, listed: true) == 10)
        #expect(CoworkSessions.pollInterval(onBattery: false, lowPower: false, unattended: false, listed: false) == 15)
        #expect(CoworkSessions.pollInterval(onBattery: true, lowPower: true, unattended: true, listed: true) == 30)
        #expect(CoworkSessions.pollInterval(onBattery: false, lowPower: false, unattended: true, listed: false) == 30)
        #expect(CoworkSessions.listedFor == SessionTracker.idleAfter)
    }
}

/// The reader over a folder laid out the way the Claude app lays out its tasks.
@Suite struct CoworkReading {
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    struct Folder {
        let root: URL
        let organisation: URL

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("NotchmeterTests.Cowork.\(UUID().uuidString)")
            organisation = root.appendingPathComponent("account-uuid/org-uuid")
            try FileManager.default.createDirectory(at: organisation, withIntermediateDirectories: true)
        }

        func record(_ id: String, _ fields: [String: Any], modified: Date) throws {
            let url = organisation.appendingPathComponent("\(id).json")
            try JSONSerialization.data(withJSONObject: fields).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }

        func log(_ id: String, _ lines: [String], modified: Date, append: Bool = false) throws {
            let folder = organisation.appendingPathComponent(id)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent("audit.jsonl")
            let data = Data((lines.joined(separator: "\n") + "\n").utf8)
            if append, let handle = try? FileHandle(forWritingTo: url) {
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            } else {
                try data.write(to: url)
            }
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    @Test func aLiveTaskIsReadWithItsTitleItsFolderAndItsTurnAndThenItsEnd() async throws {
        let folder = try Folder()
        defer { folder.remove() }
        try folder.record("local_1", ["title": "Compare vendors", "userSelectedFolders": ["/Users/me/Research"], "isArchived": false,
                                      "emailAddress": "me@example.com"], modified: t0)
        try folder.log("local_1", [CoworkLines.prompt("go", at: t0.addingTimeInterval(-50)), CoworkLines.assistant(at: t0.addingTimeInterval(-2))],
                       modified: t0.addingTimeInterval(-2))
        let reader = CoworkReader(root: folder.root)
        let first = await reader.poll(now: t0)
        let task = try #require(first.first)
        #expect(first.count == 1)
        #expect(task.id == "local_1")
        #expect(task.title == "Compare vendors")
        #expect(task.project == "Research")
        #expect(task.lastWrite == t0.addingTimeInterval(-2))
        #expect(task.turn.open)
        #expect(task.turn.began == t0.addingTimeInterval(-50))
        // What is appended is read from where the last read stopped.
        try folder.log("local_1", [CoworkLines.result(at: t0.addingTimeInterval(4), seconds: 54)], modified: t0.addingTimeInterval(4), append: true)
        let second = try #require(await reader.poll(now: t0.addingTimeInterval(5)).first)
        #expect(!second.turn.open)
        #expect(second.turn.end?.duration == 54)
        #expect(second.turn.began == t0.addingTimeInterval(-50))
    }

    /// An old task costs a `stat` and is not listed; an archived one is not listed either; a task with no log is
    /// dated by its record's `lastActivityAt`.
    @Test func oldAndArchivedTasksAreLeftOutAndATaskWithNoLogIsDatedByItsRecord() async throws {
        let folder = try Folder()
        defer { folder.remove() }
        try folder.record("local_old", ["title": "old"], modified: t0.addingTimeInterval(-7200))
        try folder.log("local_old", [CoworkLines.prompt("old", at: t0.addingTimeInterval(-7300))], modified: t0.addingTimeInterval(-7200))
        try folder.record("local_archived", ["title": "archived", "isArchived": true], modified: t0)
        try folder.log("local_archived", [CoworkLines.prompt("x", at: t0)], modified: t0)
        let activity = t0.addingTimeInterval(-20)
        try folder.record("local_bare", ["title": "bare", "lastActivityAt": activity.timeIntervalSince1970 * 1000], modified: activity)
        try folder.record("local_bare_old", ["title": "bare old", "lastActivityAt": (t0.timeIntervalSince1970 - 7200) * 1000],
                          modified: t0.addingTimeInterval(-7200))
        let tasks = await CoworkReader(root: folder.root).poll(now: t0)
        #expect(tasks.map(\.id) == ["local_bare"])
        #expect(tasks.first?.lastWrite == activity)
        #expect(tasks.first?.turn.open == true)
        #expect(tasks.first?.project == nil)
    }

    /// A log longer than the tail is read from the tail, its first, partial line skipped. A tail that settles
    /// nothing (no prompt, no end) is widened once, so a turn met half-way still clocks from its prompt; one that
    /// holds an end is not, since a finished turn needs no start.
    @Test func aLongLogIsReadFromItsTailAndWidenedOnlyWhenTheTailSettlesNothing() async throws {
        let folder = try Folder()
        defer { folder.remove() }
        let step = CoworkLines.status(at: t0.addingTimeInterval(-300))
        let filler = Array(repeating: step, count: CoworkSessions.tailBytes / step.utf8.count + 50)
        try folder.record("local_1", ["title": "long"], modified: t0)
        try folder.log("local_1", [CoworkLines.prompt("start", at: t0.addingTimeInterval(-600))] + filler + [CoworkLines.assistant(at: t0.addingTimeInterval(-1))],
                       modified: t0.addingTimeInterval(-1))
        try folder.record("local_2", ["title": "ended"], modified: t0)
        try folder.log("local_2", [CoworkLines.prompt("start", at: t0.addingTimeInterval(-600))] + filler + [CoworkLines.result(at: t0.addingTimeInterval(-1), seconds: 599)],
                       modified: t0.addingTimeInterval(-1))
        let tasks = await CoworkReader(root: folder.root).poll(now: t0)
        let widened = try #require(tasks.first { $0.id == "local_1" })
        #expect(widened.turn.open)
        #expect(widened.turn.began == t0.addingTimeInterval(-600))
        let ended = try #require(tasks.first { $0.id == "local_2" })
        #expect(!ended.turn.open)
        #expect(ended.turn.began == nil, "the tail held the end, so the prompt before it was never looked for")
        #expect(ended.turn.end?.duration == 599)
    }

    /// Titles off, the reader keeps no title either: dropped from a record already held, and not taken from one
    /// read afresh. On again, the record is read again once `recordSpacing` allows.
    @Test func titlesOffAreNotHeldEvenByTheReader() async throws {
        let folder = try Folder()
        defer { folder.remove() }
        try folder.record("local_1", ["title": "Secret plan"], modified: t0)
        try folder.log("local_1", [CoworkLines.prompt("go", at: t0.addingTimeInterval(-5))], modified: t0.addingTimeInterval(-1))
        let reader = CoworkReader(root: folder.root)
        #expect(await reader.poll(now: t0, titles: true).first?.title == "Secret plan")
        #expect(await reader.poll(now: t0.addingTimeInterval(1), titles: false).first?.title == nil)
        let fresh = CoworkReader(root: folder.root)
        #expect(await fresh.poll(now: t0, titles: false).first?.title == nil)
        #expect(await fresh.poll(now: t0.addingTimeInterval(1), titles: true).first?.title == nil, "not before the spacing")
        #expect(await fresh.poll(now: t0.addingTimeInterval(CoworkSessions.recordSpacing + 1), titles: true).first?.title == "Secret plan")
    }

    @Test func aMissingFolderReadsAsNoTasks() async {
        let tasks = await CoworkReader(root: URL(fileURLWithPath: "/nonexistent/NotchmeterTests/cowork")).poll(now: t0)
        #expect(tasks.isEmpty)
    }
}

/// How a Cowork task reads everywhere a session is named: the row, the banner, the news, the jump, the report and
/// the oracle.
@Suite struct CoworkSurfaces {
    init() { Localization.use(language: "en") }

    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    func tracker(project: String? = "Support", title: String? = "Summarise the tickets") -> SessionTracker {
        var tracker = SessionTracker()
        let began = t0.addingTimeInterval(-400)
        tracker.observeCowork([CoworkSessions.Observation(id: "local_1", title: title, project: project, lastWrite: t0.addingTimeInterval(-1),
                                                          turn: CoworkSessions.Turn(began: began, end: nil, open: true))], now: t0)
        tracker.observeCowork([CoworkSessions.Observation(id: "local_1", title: title, project: project, lastWrite: t0.addingTimeInterval(4),
                                                          turn: CoworkSessions.Turn(began: began, end: .init(at: t0.addingTimeInterval(4), duration: 404, failed: false),
                                                                                    open: false))], now: t0.addingTimeInterval(5))
        return tracker
    }

    @Test func theRowCarriesTheCoworkChipItsSourceAndItsFolder() throws {
        let sessions = tracker().all
        let rows = SessionsCard.rows(sessions, hideTitles: false, jump: true, now: t0.addingTimeInterval(6)).rows
        let row = try #require(rows.first)
        #expect(row.chips == ["Cowork"])
        #expect(row.source == .coworkLog)
        #expect(row.title == "Summarise the tickets")
        #expect(row.status == .finished)
        #expect(row.canJump, "a click brings the Claude app forward")
        #expect(row.note == .doneJump)
        let oracle = SessionsCard.oracleRows(SessionsCard.groups(rows, sessions: sessions))
        #expect(oracle.first?["source"] as? String == "coworkLog")
        // Titles hidden and no folder: the row still says what it is.
        let bare = tracker(project: nil).all
        #expect(SessionsCard.rows(bare, hideTitles: true, jump: false, now: t0).rows.first?.title == "Cowork")
        #expect(SessionsCard.groupName(of: bare[0]) == "Cowork")
    }

    @Test func aClickRaisesTheClaudeAppAndSaysSo() {
        let ref = TerminalRef(bundleID: CoworkSessions.bundleID)
        #expect(TerminalJump.resolve(ref) == .activate(bundleID: CoworkSessions.bundleID))
        #expect(TerminalJump.jumpHelp(ref) == "Brings the Claude app forward (Notchmeter can't open one Cowork task in it)")
        #expect(TerminalJump.jumpTitle(ref) == "Open Claude")
        #expect(TerminalJump.jumpTitle(TerminalRef(bundleID: TerminalJump.BundleID.iTerm)) == "Jump to the terminal")
    }

    @Test func theBannerAndTheNewsNameClaudeCowork() throws {
        let session = try #require(tracker().all.first)
        let copy = Notifier.copy(for: .finished(turn: 404), session: session)
        #expect(copy.title == "Claude Cowork finished")
        #expect(copy.body == "Claude Cowork finished a \(ResetText.duration(404)) turn in Support.")
        #expect(Notifier.copy(for: .finished(turn: 404), session: session, hidingFigures: true).body.hasSuffix("in a session."))
        let news = try #require(NotchNews.finished(session, turn: 404, now: t0))
        #expect(news.source == .coworkLog)
        #expect(news.reason == .finished)
        #expect(news.words(hidesFigures: false, title: session.displayTitle).spoken.hasPrefix("Claude Cowork"))
        #expect(news.words(hidesFigures: true).name == nil)
        #expect(UsageStore.peekFacts(news, action: "shown")["source"] as? String == "coworkLog")
        #expect(NotchNews.finished(session, turn: ToolSignal.finishedAfter - 1, now: t0) == nil, "a short turn is the ring's to skip")
        // A hook's news says nothing of a source.
        let hook = NotchNews(reason: .finished, sessionID: "a", tool: .claude, project: "p", at: t0)
        #expect(UsageStore.peekFacts(hook, action: "shown")["source"] == nil)
        #expect(hook.words(hidesFigures: false).spoken.hasPrefix("Claude Code"))
    }

    @Test func theReportAndTheOracleNameTheSource() throws {
        let report = UsageReport(tools: [:], cost: nil, advice: [], sessions: tracker().all, now: t0)
        let sessions = try #require(report.object["sessions"] as? [[String: Any]])
        #expect(sessions.first?["source"] as? String == "coworkLog")
        #expect(sessions.first?["tool"] as? String == "claude")
        let facts = UsageStore.coworkFacts(SessionTracker.CoworkChange(session: "cowork:local_1", kind: .finished, turn: 404.4))
        #expect(facts["action"] as? String == "finished")
        #expect(facts["turn"] as? Int == 404)
        #expect(Set(facts.keys) == ["action", "session", "turn"], "never the title or the folder")
    }

    @MainActor @Test func theStoreDropsTheTitleWhenTitlesAreOffAndAnnouncesAFinish() throws {
        let suite = "NotchmeterTests.Cowork"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = Preferences(defaults: defaults)
        #expect(prefs.coworkSessions, "on by default")
        prefs.coworkSessions = false
        #expect(!Preferences(defaults: defaults).coworkSessions)
        prefs.coworkSessions = true
        prefs.notifyFinished = true
        prefs.finishedAfterMinutes = 1
        prefs.sessionTitles = false
        let reading = UsageReading(tool: .claude, windows: [], plan: nil, fetchedAt: t0, observedAt: nil)
        let store = UsageStore(prefs: prefs, providers: [FixtureProvider(reading: reading)], cache: ReadingCache(defaults: defaults), defaults: defaults,
                               drainLog: nil, reportFile: nil)
        var delivered: [(Notifier.SessionEvent, AgentSession)] = []
        store.deliverSessionEvent = { delivered.append(($0, $1)) }
        let began = t0.addingTimeInterval(-120)
        store.coworkObserved([CoworkSessions.Observation(id: "local_1", title: "secret", project: "Support", lastWrite: t0,
                                                         turn: CoworkSessions.Turn(began: began, end: nil, open: true))], now: t0)
        let key = CoworkSessions.key("local_1")
        #expect(store.sessions.sessions[key]?.isWorking == true)
        #expect(store.sessions.sessions[key]?.displayTitle == nil)
        let later = t0.addingTimeInterval(5)
        store.coworkObserved([CoworkSessions.Observation(id: "local_1", title: "secret", project: "Support", lastWrite: later,
                                                         turn: CoworkSessions.Turn(began: began, end: .init(at: later, duration: 125, failed: false), open: false))],
                             now: later)
        #expect(delivered.count == 1)
        #expect(delivered.first?.1.id == key)
        #expect(store.latestNews?.sessionID == key)
        #expect(store.latestNews?.source == .coworkLog)
        // The watch stopping (the Claude app quit, or the setting off) is an empty read: every Cowork row goes.
        store.coworkObserved([], now: later.addingTimeInterval(1))
        #expect(store.sessions.count == 0)
    }

    /// The fixture `cowork.png` is drawn from: one task working and one just finished, both from the rule itself.
    @Test func theRenderFixtureHoldsOneWorkingAndOneFinishedTask() throws {
        var tracker = SessionTracker()
        DemoFixtures.coworkTasks(into: &tracker, now: t0)
        let research = try #require(tracker.sessions[CoworkSessions.key(DemoFixtures.coworkResearch)])
        let tickets = try #require(tracker.sessions[CoworkSessions.key(DemoFixtures.coworkTickets)])
        #expect(research.isWorking)
        #expect(tickets.finish(now: t0) != nil)
        #expect(tickets.finished?.turn == 428)
        #expect(tracker.waiting.isEmpty)
    }
}
