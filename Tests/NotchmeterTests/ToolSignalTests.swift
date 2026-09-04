import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Notchmeter

/// The rule behind the ring's colour: which state holds, how long a finished turn holds it, and what lets it go
/// early. All of it is pure, so it is pinned without a screen. Almost every test here is about a state going away
/// rather than about it arriving, because a colour that appears late costs a reader nothing and a colour that stays
/// after the fact costs them their trust in the whole strip.
@Suite struct SignalRules {
    init() { Localization.use(language: "en") }

    let t0 = DateParsing.iso8601("2026-09-01T12:00:00Z")!

    func finish(_ turn: TimeInterval, ago: TimeInterval) -> ToolSignal.Finish {
        ToolSignal.Finish(turn: turn, at: t0.addingTimeInterval(-ago))
    }

    func resolve(waiting: Int = 0, finish: ToolSignal.Finish? = nil, working: Bool = false, attended: Date? = nil) -> ToolSignal? {
        ToolSignal.resolve(waiting: waiting, finish: finish, working: working, attended: attended, now: t0)
    }

    func message(_ event: String, session: String = "a", project: String? = "notchmeter", type: String? = nil,
                 tool: ToolID = .claude) -> Hook.Message {
        Hook.Message(event: event, needsInput: Hook.needsInput(event: event, notificationType: type), sessionID: session,
                     project: project, notificationType: type, tool: tool)
    }

    @Test func aWaitOutranksAFinishBecauseOnlyTheWaitIsBlocking() {
        #expect(resolve() == nil)
        #expect(resolve(waiting: 1) == .waiting(count: 1))
        #expect(resolve(waiting: 2, finish: finish(600, ago: 5)) == .waiting(count: 2),
                "A session that cannot proceed without an answer has a better claim on the ring than one that has already stopped.")
    }

    @Test func aFinishedTurnHoldsTheRingForNinetySecondsAndNoLonger() {
        // The hold is 90 s, so a finish 89 s old still holds and one 91 s old does not.
        #expect(resolve(finish: finish(600, ago: 89)) == .finished(turn: 600))
        #expect(resolve(finish: finish(600, ago: 91)) == nil)
        #expect(resolve(finish: finish(600, ago: ToolSignal.heldFor)) == nil,
                "The hold is exclusive at its end: a ring released a moment late is reporting something that had already stopped being true.")
    }

    @Test func aTurnShorterThanTwentySecondsEndedWhileTheUserWasStillWatchingIt() {
        #expect(resolve(finish: finish(19, ago: 5)) == nil)
        #expect(resolve(finish: finish(ToolSignal.finishedAfter, ago: 5)) == .finished(turn: 20))
        #expect(ToolSignal.finishedAfter < 60,
                "The ring's floor is seconds and the notification's is minutes, because a banner interrupts the reader and a ring does not.")
    }

    @Test func aFinishIsReleasedWhenWorkResumesOrTheUserHasAlreadyLooked() {
        let landed = finish(600, ago: 30)
        #expect(resolve(finish: landed, working: true) == nil,
                "Something is still running, so the user is not the bottleneck and the ring has nothing to ask of them.")
        // Attended 20 s ago, which is after the finish 30 s ago: they have already seen it.
        #expect(resolve(finish: landed, attended: t0.addingTimeInterval(-20)) == nil)
        // Attended 40 s ago, before the finish: it is news they have not had.
        #expect(resolve(finish: landed, attended: t0.addingTimeInterval(-40)) == .finished(turn: 600))
    }

    @Test func nothingOnTheDrawingSideMayRetireAWait() {
        #expect(resolve(waiting: 1, working: true, attended: t0) == .waiting(count: 1),
                "A wait ends when the hook says it ended or when SessionTracker times it out at ten minutes, and never because the ring grew tired of it.")
    }

    @Test func theTrackerMarksAFinishOnEveryStopAndClearsItOnTheNextTurn() {
        var tracker = SessionTracker()
        tracker.apply(message("UserPromptSubmit"), now: t0)
        #expect(tracker.finish(of: .claude, now: t0) == nil, "a session that is working has not finished anything")
        tracker.apply(message("Stop"), now: t0.addingTimeInterval(120))
        // The turn ran 120 s and the hold runs 90 s from the Stop at t0 + 120: on at t0 + 209, over at t0 + 210.
        #expect(tracker.finish(of: .claude, now: t0.addingTimeInterval(209))?.turn == 120)
        #expect(tracker.finish(of: .claude, now: t0.addingTimeInterval(210)) == nil)
        tracker.apply(message("UserPromptSubmit"), now: t0.addingTimeInterval(150))
        #expect(tracker.finish(of: .claude, now: t0.addingTimeInterval(151)) == nil,
                "a turn that is running now is not a turn that has just ended")
    }

    @Test func theMarkIsReadFromTheClockSoASleepingMacCannotWakeToAStaleColour() {
        var tracker = SessionTracker()
        tracker.apply(message("UserPromptSubmit"), now: t0)
        tracker.apply(message("Stop"), now: t0.addingTimeInterval(60))
        // Nothing ran at all while the Mac slept; the first read after the wake is what settles it.
        #expect(tracker.finish(of: .claude, now: t0.addingTimeInterval(3 * 3600)) == nil,
                "A state that needed a timer to have fired in order to be right would be wrong every time the Mac slept.")
        tracker.expire(now: t0.addingTimeInterval(3 * 3600))
        #expect(tracker.all.first?.finished == nil, "expiry frees a mark the clock had already retired")
    }

    @Test func aStopFailureIsALimitHitAndNotAFinish() {
        var tracker = SessionTracker()
        tracker.apply(message("UserPromptSubmit"), now: t0)
        tracker.apply(Hook.Message(event: "StopFailure", needsInput: false, sessionID: "a", project: "notchmeter", failure: "rate_limit"),
                      now: t0.addingTimeInterval(60))
        #expect(tracker.finish(of: .claude, now: t0.addingTimeInterval(61)) == nil,
                "A turn that fell over on the limit has not finished, and the ring must not congratulate it.")
        #expect(tracker.limitHit(now: t0.addingTimeInterval(61)))
    }

    @Test func aSessionThatEndsOrGoesStaleTakesItsColourWithIt() {
        var tracker = SessionTracker()
        tracker.apply(message("UserPromptSubmit"), now: t0)
        tracker.apply(message("Stop"), now: t0.addingTimeInterval(60))
        tracker.apply(message("SessionEnd"), now: t0.addingTimeInterval(61))
        #expect(tracker.finish(of: .claude, now: t0.addingTimeInterval(62)) == nil,
                "A session the app can no longer see cannot still be finishing.")
        tracker.apply(message("PermissionRequest", session: "b"), now: t0.addingTimeInterval(63))
        tracker.expire(now: t0.addingTimeInterval(63 + SessionTracker.staleAfter))
        #expect(tracker.waiting(of: .claude).isEmpty,
                "A hook uninstalled mid-session leaves a wait that expires like any other.")
    }

    @Test func oneToolsSessionsNeverSpeakForAnother() {
        var tracker = SessionTracker()
        tracker.apply(message("UserPromptSubmit", session: "a"), now: t0)
        tracker.apply(message("PermissionRequest", session: "a"), now: t0.addingTimeInterval(1))
        #expect(tracker.waiting(of: .claude).map(\.id) == ["a"])
        for tool in ToolID.allCases where tool != .claude {
            #expect(tracker.waiting(of: tool).isEmpty && tracker.finish(of: tool, now: t0.addingTimeInterval(2)) == nil,
                    "A tool with no hook installed has nothing to report and must therefore report nothing.")
        }
        tracker.apply(message("PermissionRequest", session: "c", tool: .codex), now: t0.addingTimeInterval(3))
        #expect(tracker.waiting(of: .codex).map(\.id) == ["c"],
                "The moment a second hook reports, the same lamps light for it with no further change above the tracker.")
    }

    @Test func aToolThatNamesItselfSurvivesTheNotificationPayloadAndTheRemotePost() throws {
        let codex = Hook.Message(event: "PermissionRequest", needsInput: true, sessionID: "c", tool: .codex)
        // Claude names no tool, so its payload is byte for byte what the shipped hook has always posted.
        #expect(Hook.Message(event: "Stop", needsInput: false).userInfo[Hook.toolKey] == nil,
                "The one hook that ships says nothing here, and its absence already says Claude.")
        #expect(codex.userInfo[Hook.toolKey] as? String == "codex")
        #expect(try #require(Hook.Message(userInfo: codex.userInfo)) == codex)
        let posted = Data(#"{"hook_event_name":"PermissionRequest","session_id":"c","tool":"codex","host":"devbox"}"#.utf8)
        #expect(try #require(LocalAPI.hookMessage(from: posted)).tool == .codex,
                "hookMessage rebuilds the message field by field, so a field it forgets is dropped for every remote host.")
    }

    @Test func theReleaseTimerIsArmedForTheEarliestStateStillRunning() {
        var tracker = SessionTracker()
        #expect(tracker.nextRelease(now: t0) == nil, "with nothing on there is nothing to retire and no timer to hold")
        tracker.apply(message("UserPromptSubmit", session: "a"), now: t0)
        tracker.apply(message("Stop", session: "a"), now: t0)
        tracker.apply(message("UserPromptSubmit", session: "b", project: "scout"), now: t0.addingTimeInterval(29))
        tracker.apply(message("PermissionRequest", session: "b"), now: t0.addingTimeInterval(30))
        // The finish at t0 releases at t0 + 90; the wait that began at t0 + 30 releases at t0 + 630.
        #expect(tracker.nextRelease(now: t0.addingTimeInterval(31)) == t0.addingTimeInterval(SessionTracker.finishedHold))
        tracker.expire(now: t0.addingTimeInterval(SessionTracker.finishedHold))
        #expect(tracker.nextRelease(now: t0.addingTimeInterval(91)) == t0.addingTimeInterval(30 + SessionTracker.waitingTimeout),
                "Once the nearer state has gone the timer must re-arm for the next one, or the wait would outstay it.")
    }
}

/// What the ring is actually painted when the fullness rule and a signal want the same stroke, and what has to be
/// saying it alongside the colour. `@MainActor` because `RingView` is a `View` and so inherits the main actor:
/// these are its own statics, and the repo already annotates a suite rather than move drawing arithmetic off the
/// view it describes.
@MainActor @Suite struct SignalDrawing {
    init() { Localization.use(language: "en") }

    let claude = Color(red: 0.85, green: 0.47, blue: 0.34)

    @Test func aSignalTakesTheArcAndTheFullnessTintMovesToTheCap() {
        #expect(RingView.arcColour(fraction: 0.5, tool: claude, signal: nil) == claude)
        #expect(RingView.arcColour(fraction: 0.85, tool: claude, signal: nil) == Palette.warn)
        #expect(RingView.arcColour(fraction: 0.97, tool: claude, signal: nil) == Palette.danger)
        #expect(RingView.arcColour(fraction: 0.97, tool: claude, signal: .waiting(count: 1)) == Palette.calm,
                "A permission prompt is the only one of the two facts the reader can act on this second, so it takes the arc.")
        #expect(RingView.arcColour(fraction: 0.1, tool: claude, signal: .finished(turn: 600)) == Palette.calm,
                "Waiting and finishing ask the same thing of the reader, so they take one colour and are told apart by shape.")
    }

    @Test func theCapKeepsPaceFirstAndTheDisplacedTintSecond() {
        // Pace has first claim whether or not a signal holds, with the shape it has always had.
        #expect(RingView.cap(fraction: 0.5, pace: .behind, signal: nil)?.filled == true)
        #expect(RingView.cap(fraction: 0.5, pace: .onTrack, signal: .finished(turn: 600))?.color == Palette.warn)
        #expect(RingView.cap(fraction: 0.97, pace: .behind, signal: .waiting(count: 1))?.color == Palette.danger)
        // 86 % while still ahead draws no cap today; with a signal on the arc the displaced orange moves to one.
        #expect(RingView.cap(fraction: 0.86, pace: .ahead, signal: nil) == nil)
        #expect(RingView.cap(fraction: 0.86, pace: .ahead, signal: .waiting(count: 1))?.color == Palette.warn)
        #expect(RingView.cap(fraction: 0.96, pace: nil, signal: .waiting(count: 1))?.filled == true)
        #expect(RingView.cap(fraction: 0.5, pace: .ahead, signal: .waiting(count: 1)) == nil,
                "A window with room to spare has nothing for the cap to carry, and one drawn anyway would read as a warning it has not earned.")
    }

    @Test func theTrackLiftsSoAnAlmostEmptyRingStillTurns() {
        // A tool at 4 % has fifteen thousandths of a circle of arc, so the track is what carries the recolour.
        #expect(RingView.trackOpacity(signal: nil, contrast: false) == 0.22)
        #expect(RingView.trackOpacity(signal: .waiting(count: 1), contrast: false) == 0.38)
        #expect(RingView.trackOpacity(signal: nil, contrast: true) == 0.45)
        #expect(RingView.trackOpacity(signal: .waiting(count: 1), contrast: true) == 0.6,
                "Increase Contrast raises a signalled track by the same step it raises an ordinary one, so the setting keeps its meaning.")
    }

    /// `WaitingDot` draws the count in the disc past one, so for as long as the spoken value said only "waiting for
    /// your input" the figure a sighted reader could see was carried by shape alone — the same defect as a state
    /// carried by colour alone, with the channels swapped. One session keeps the bare phrase: a listener told
    /// "1 session" would wonder what the other number was.
    @Test func theSpokenValueCarriesTheWaitingCountTheDiscDraws() {
        #expect(ToolSignal.waiting(count: 1).spokenText == "waiting for your input")
        #expect(ToolSignal.waiting(count: 4).spokenText == "waiting for your input, 4 sessions")
        #expect(ToolSignal.waiting(count: 4).spokenText != ToolSignal.waiting(count: 2).spokenText,
                "two waits a reader can tell apart on the strip must be two a listener can tell apart too")
    }

    @Test func everyStateThatTakesAColourAlsoTakesAShapeAndAPhrase() {
        for state in [ToolSignal.waiting(count: 1), .finished(turn: 600)] {
            #expect(state.colour == Palette.calm, "one hue for two states, because the two states ask the same thing of the reader")
            #expect(!state.symbolName.isEmpty, "no state may rest on hue alone: whatever changes colour also changes shape")
            #expect(!state.spokenText.isEmpty, "a state a sighted reader can see must be one VoiceOver can read")
            #expect(!state.cardText.isEmpty, "the card has room for words and must use them")
        }
    }

    /// A finish lit the mark and, for one revision, lifted the presence level with it so the mark would be easier
    /// to read. That put the ring diameters on the ninety-second hold's clock — `CompactRings.nest` sizes the outer
    /// ring 14 pt quiet against 18 pt otherwise — so the calm rule answered a clock as well as a set of limits and
    /// the nest churned after every long turn. It never moved the strip: the nest shrinks inside `CompactRings`'
    /// hard 18 pt frame, which measures the same at every level, and `aSignalNeverMovesAReadoutsFootprint` below is
    /// what holds that. What this test holds is the rule itself. It runs the real store rather than the pure rule,
    /// because the rule no longer takes a finish at all and the only way left to ask the question is to give a store
    /// a finished turn and read what it says about loudness.
    @Test func aFinishedTurnLightsTheMarkAndNeverChangesHowLoudTheRingsAre() {
        let suite = "notchmeter.tests.signalPresence"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = Preferences(defaults: defaults)
        let now = Date()
        // 10 % used and ahead of pace, which is the one state Presence calls quiet.
        let reading = UsageReading(tool: .claude, windows: [
            LimitWindow(id: "session", label: "Session", usedFraction: 0.1, resetsAt: now.addingTimeInterval(4 * 3600), periodDuration: Period.fiveHours),
        ], plan: nil, fetchedAt: now, observedAt: nil)
        let store = UsageStore(prefs: prefs, providers: [], cache: ReadingCache(defaults: defaults), defaults: defaults, drainLog: nil, reportFile: nil)
        store.seed(readings: [reading], cost: .empty, nextUpdate: now.addingTimeInterval(60), now: now)
        #expect(store.presence == .quiet)
        // A turn that ran 115 s and stopped 5 s ago: past the 20 s floor and well inside the 90 s hold.
        store.hookReceived(Hook.Message(event: "UserPromptSubmit", needsInput: false, sessionID: "a"), now: now.addingTimeInterval(-120))
        store.hookReceived(Hook.Message(event: "Stop", needsInput: false, sessionID: "a"), now: now.addingTimeInterval(-5))
        #expect(store.signal(.claude) == .finished(turn: 115), "the mark is lit, so the loudness below is being asked about a live finish")
        #expect(store.presence == .quiet,
                "A finish is news beside the rings, not a change to them: the calm rule answers how much is left and how fast, and never what time it is.")
    }

    /// The compact fit rests on `CompactStripProbe` measuring what is actually drawn (commit 1baef40), so a mark
    /// that changed a readout's footprint would make the strip's fit depend on what time it is: the ninety-second
    /// hold would expire between one measurement and the next and hand the fit two different answers for the same
    /// inputs, and because the pointer arriving on the strip is what releases a finish, the shape would move out
    /// from under the pointer coming to hover it. It cannot, in any style: every mark is drawn as an overlay on the
    /// corner of what it marks — inside `CompactRings`' hard 18 pt frame, or on the corner of the digits — so none
    /// of them is an item in a row with a width. This renders the real views rather than reasoning about them,
    /// because that overlay is the only thing standing between this feature and that instability. It measured
    /// 53 → 65 pt in the numbers style and 23 → 35 pt on the API-key readout when the marks sat in the row.
    @MainActor @Test func aSignalNeverMovesAReadoutsFootprint() {
        let now = DateParsing.iso8601("2026-09-01T12:00:00Z")!
        let reading = UsageReading(tool: .claude, windows: [
            LimitWindow(id: "session", label: "Session", usedFraction: 0.04, resetsAt: now.addingTimeInterval(4 * 3600), periodDuration: Period.fiveHours),
            LimitWindow(id: "weekly", label: "Weekly", usedFraction: 0.86, resetsAt: now.addingTimeInterval(6 * 86400), periodDuration: Period.week),
        ], plan: nil, fetchedAt: now, observedAt: nil)
        for style in CompactStyle.allCases {
            let plain = Self.fittingSize(Self.readout(style: style, reading: reading, signal: nil))
            #expect(plain.width > 0 && plain.height > 0, "a readout that measured as nothing would make the comparison below meaningless")
            for state in [ToolSignal.waiting(count: 3), .finished(turn: 600)] {
                #expect(Self.fittingSize(Self.readout(style: style, reading: reading, signal: state)) == plain,
                        "A state may recolour a readout and mark it, and it may not move it: the strip's fit is measured from what is drawn (\(style.rawValue)).")
            }
            guard style.showsNumbers else { continue }
            let cost = Self.fittingSize(Self.apiKeyReadout(style: style, signal: nil))
            #expect(cost.width > 0, "a figure that measured as nothing would make the comparison below meaningless")
            for state in [ToolSignal.waiting(count: 3), .finished(turn: 600)] {
                #expect(Self.fittingSize(Self.apiKeyReadout(style: style, signal: state)) == cost,
                        "Claude Code on an API key draws the one readout with no ring to hang a mark on, and it may not buy the room by widening (\(style.rawValue)).")
            }
        }
    }

    /// The third rule the mark has to obey, after "it must be drawn" and "it must cost no width": all of it has to
    /// land inside the box that width is measured from. `CompactRings` pins its footprint with a hard 18 pt frame,
    /// and the mark's corner offset was a pair of literals tuned by eye against the 5 pt disc a single waiting
    /// session draws, and every mark overflowed it: seven points out of a centre at (9, 9) leaves the 5 pt disc a
    /// point outside two edges and a 9 pt one three points outside each. The frame itself clips nothing — a
    /// SwiftUI `.frame` measures — but it is what tells the strip the readout is 18 pt wide, so the overflow was
    /// left to whatever the strip is drawn inside, and the notch bar cut the finished tick and the two-session
    /// count into flat-topped half-moons with the checkmark's tail running off the white. Rendering the readout
    /// while the offset was still seven gives 16 × 12 px where a disc 16 across is 16 tall.
    ///
    /// It renders the real view and measures pixels, because the defect was invisible to every question a size can
    /// answer: the frame stayed 18 pt throughout, which is exactly why `aSignalNeverMovesAReadoutsFootprint` above
    /// passed against the clipped tick. Each mark is measured twice — once with room around the readout, where
    /// nothing can be cut and so the answer is the mark's true extent, and once in the bare box the strip draws.
    /// Comparing the two asks "did the box eat any of this" without the test having to know how big any mark is,
    /// which is the whole point: the last set of numbers written down here went stale when a second mark size
    /// arrived.
    @MainActor @Test func everyMarkIsDrawnRoundAndWhollyInsideTheReadoutsOwnBox() throws {
        let side = Int(CompactRings.side * Self.markScale)
        #expect(Self.raster(CompactRings(tool: .claude, status: .waiting)).map { ($0.width, $0.height) }.map { $0 == (side, side) } == true,
                "the readout must render as the box it claims to be, or the bounds below are being checked against the wrong edges")
        for signal in [ToolSignal.waiting(count: 1), .waiting(count: 3), .finished(turn: 600)] {
            let whole = try #require(Self.markBounds(signal, room: 12), "the mark drew nothing, so there is no shape to measure")
            let drawn = try #require(Self.markBounds(signal, room: 0), "the mark drew nothing inside the readout's own box")
            #expect(whole.width == whole.height,
                    "\(signal) is a disc, and a disc given room on every side comes out \(whole.width) × \(whole.height)")
            #expect(drawn.width == whole.width && drawn.height == whole.height,
                    "The box the strip measures cut \(signal) down from \(whole.width) × \(whole.height) to \(drawn.width) × \(drawn.height).")
            #expect(drawn.minX >= 0 && drawn.minY >= 0 && drawn.maxX < side && drawn.maxY < side,
                    "\(signal) drew outside the \(Int(CompactRings.side)) pt box the strip's width is measured from.")
        }
    }

    /// The other way a derived offset can be wrong: inset too far rather than not far enough. A mark pulled two
    /// points in from the corner would pass the test above — nothing of it is cut — while sitting on top of the
    /// ring nest it is meant to sit beside, and the smaller mark would drift a different distance from the larger
    /// one. Both sizes reach the corner exactly, so the box is used to the last point at either size.
    @MainActor @Test func bothMarkSizesReachTheCornerOfTheBoxExactly() throws {
        let side = Int(CompactRings.side * Self.markScale)
        let small = try #require(Self.markBounds(.waiting(count: 1), room: 0))
        let large = try #require(Self.markBounds(.finished(turn: 600), room: 0))
        #expect(large.width > small.width, "the two sizes must actually differ, or this compares a shape with itself")
        for (name, bounds) in [("a lone wait", small), ("a finished turn", large)] {
            let short = "\(name)'s mark stops \(bounds.minY) px short of the top and \(side - 1 - bounds.maxX) px short of"
                + " the trailing edge, so it has been pulled off the corner and onto the rings."
            #expect(bounds.minY == 0 && bounds.maxX == side - 1, "\(short)")
        }
    }

    static let markScale: CGFloat = 4

    /// The pixels a signal adds to a readout, as a bounding box in the rendered image. Two renders of the same
    /// `CompactRings` — one plain, one signalled with `signalColours` off so the rings are identical in both — and
    /// the box around every pixel that changed, which is the mark and nothing else. `room` pads the readout, so
    /// zero measures what survives the box the strip's width comes from and anything larger measures the mark
    /// itself; the padding is outside the readout's frame and moves neither the frame nor the mark within it.
    @MainActor static func markBounds(_ signal: ToolSignal, room: CGFloat) -> (minX: Int, minY: Int, maxX: Int, maxY: Int, width: Int, height: Int)? {
        let now = DateParsing.iso8601("2026-09-01T12:00:00Z")!
        let windows = [LimitWindow(id: "session", label: "Session", usedFraction: 0.4,
                                   resetsAt: now.addingTimeInterval(3600), periodDuration: Period.fiveHours)]
        let reading = UsageReading(tool: .claude, windows: windows, plan: nil, fetchedAt: now, observedAt: nil)
        func rings(_ signal: ToolSignal?) -> some View {
            CompactRings(tool: .claude, status: .ready(reading), windows: windows, signal: signal, signalColours: false)
                .padding(room)
        }
        guard let plain = Self.raster(rings(nil)), let marked = Self.raster(rings(signal)),
              plain.width == marked.width, plain.height == marked.height else { return nil }
        let inset = Int(room * markScale)
        var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
        for y in 0 ..< plain.height {
            for x in 0 ..< plain.width {
                let offset = (y * plain.width + x) * 4
                // A tolerance, because the two images are composited independently and a pixel the mark never
                // touched can still differ in the last bit of a channel.
                guard (0 ..< 4).contains(where: { abs(Int(plain.bytes[offset + $0]) - Int(marked.bytes[offset + $0])) > 8 }) else { continue }
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard minX <= maxX else { return nil }
        return (minX - inset, minY - inset, maxX - inset, maxY - inset, maxX - minX + 1, maxY - minY + 1)
    }

    /// A view's drawn pixels as straight RGBA bytes, row zero at the top. `ImageRenderer` hands back a `CGImage`
    /// whose byte layout is the renderer's business, so it is redrawn into a context this test owns.
    @MainActor static func raster(_ view: some View) -> (width: Int, height: Int, bytes: [UInt8])? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = markScale
        guard let image = renderer.cgImage else { return nil }
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? (width, height, bytes) : nil
    }

    /// The other half of the footprint rule: a mark that cost no width would be easy to deliver by not drawing it.
    /// Claude Code on an API key draws a figure and, until this feature, nothing else — so the one assistant whose
    /// hook reports these events was also the only one with nowhere to report them, and "nowhere" must not be where
    /// it ended up. Pixels rather than a size, because a size is exactly what this mark is not allowed to change.
    @MainActor @Test func theApiKeyReadoutDrawsItsMarkOnTheCornerOfTheFigure() {
        let plain = Self.pixels(Self.apiKeyReadout(style: .numbers, signal: nil))
        #expect(plain?.isEmpty == false, "a readout that rendered as nothing would make the comparison below meaningless")
        #expect(Self.pixels(Self.apiKeyReadout(style: .numbers, signal: nil)) == plain, "the same readout must render the same twice, or the comparison below means nothing")
        #expect(Self.pixels(Self.apiKeyReadout(style: .numbers, signal: .finished(turn: 600))) != plain,
                "A readout with no ring must still be able to say that its assistant has stopped, and the corner of the figure is where it says it.")
    }

    /// The menu bar is the one surface in the "five surfaces read one answer" set whose whole statement is a glyph,
    /// and a glyph is exactly what a screen reader cannot see. Both of `update(captured:)`'s early returns are the
    /// shipping default — the pin is off on a notched Mac — and both set the image and the tooltip only, so the
    /// hand and the tick were silent to VoiceOver: `init` sets an accessibility label, which overrides the
    /// description the symbol carries, and nothing set a value. The clearing half matters as much: an early return
    /// that leaves the previous pass's value behind speaks a state that has since gone.
    ///
    /// It drives a real `NSStatusItem` because the defect was in what AppKit ends up holding, not in a string this
    /// code could hand back. The item is reached by `Mirror` rather than by opening the class up: nothing in the
    /// app needs the button, and a property added for a test is a second way in that then has to be kept true.
    @MainActor @Test func theMenuBarGlyphSaysWhatItMeansToVoiceOverWithThePinOff() {
        let suite = "notchmeter.tests.menuBarSpoken"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = Preferences(defaults: defaults)
        #expect(!prefs.menuBarPin, "the branch under test is the default one, so the default is what this must run on")
        let now = Date()
        let reading = UsageReading(tool: .claude, windows: [
            LimitWindow(id: "session", label: "Session", usedFraction: 0.1, resetsAt: now.addingTimeInterval(4 * 3600), periodDuration: Period.fiveHours),
        ], plan: nil, fetchedAt: now, observedAt: nil)
        // A provider, because `visibleTools` asks whether the tool is installed and the pin only speaks for tools
        // it can see.
        let store = UsageStore(prefs: prefs, providers: [FixtureProvider(reading: reading)],
                               cache: ReadingCache(defaults: defaults), defaults: defaults, drainLog: nil, reportFile: nil)
        store.seed(readings: [reading], cost: .empty, nextUpdate: now.addingTimeInterval(60), now: now)
        #expect(store.visibleTools == [.claude])
        let item = MenuBarItem(store: store, prefs: prefs, actions: NotchActions())
        defer { item.remove() }
        #expect(Self.spokenValue(of: item)?.isEmpty ?? true,
                "with nothing being asked of the reader the glyph is the plain gauge, which says nothing and must not claim to")

        store.hookReceived(Hook.Message(event: "Notification", needsInput: true, sessionID: "a"), now: now)
        item.update(captured: false)
        let waiting = try? #require(store.signal(.claude))
        #expect(waiting == .waiting(count: 1), "the glyph is the raised hand, so the value below is being asked about a live wait")
        #expect(Self.spokenValue(of: item) == waiting?.spokenText,
                "a sighted reader sees the raised hand; VoiceOver used to hear the app's name and nothing else")

        item.update(captured: true)
        #expect(Self.spokenValue(of: item)?.isEmpty ?? true,
                "the privacy setting's promise is that the menu bar stops telling the room about this Mac, and a value left behind by the last pass goes on telling it")
    }

    /// With the pin off there is no pinned tool, and the set the glyph was reading from was `pinnedTools`'
    /// fallback — the first visible assistant, which is a device for having something to measure rather than a
    /// choice anyone made. On a Mac with no notch the menu bar item is on by default and the pin is off by
    /// default, so in the shipping configuration the hand and the tick appeared only if the assistant being waited
    /// on happened to sit first in the Assistants order. This puts the wait on the second one, which is what
    /// dragging Codex above Claude does, and asks for the value rather than the image because the value is the
    /// half a screen-reader user gets and the half that was empty.
    @MainActor @Test func theGlyphSpeaksForAnAssistantThatIsNotFirstInTheOrderWithThePinOff() {
        let suite = "notchmeter.tests.menuBarUnpinnedOrder"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = Preferences(defaults: defaults)
        #expect(!prefs.menuBarPin, "the branch under test is the default one, so the default is what this must run on")
        prefs.toolOrder = [.codex, .claude]
        let now = Date()
        let readings = [ToolID.codex, .claude].map { tool in
            UsageReading(tool: tool, windows: [
                LimitWindow(id: "session", label: "Session", usedFraction: 0.1, resetsAt: now.addingTimeInterval(4 * 3600), periodDuration: Period.fiveHours),
            ], plan: nil, fetchedAt: now, observedAt: nil)
        }
        let store = UsageStore(prefs: prefs, providers: readings.map { FixtureProvider(reading: $0) },
                               cache: ReadingCache(defaults: defaults), defaults: defaults, drainLog: nil, reportFile: nil)
        store.seed(readings: readings, cost: .empty, nextUpdate: now.addingTimeInterval(60), now: now)
        #expect(store.visibleTools == [.codex, .claude], "the assistant that is about to wait must not be the first one, or nothing is being tested")
        store.hookReceived(Hook.Message(event: "Notification", needsInput: true, sessionID: "a"), now: now)
        #expect(store.signal(.claude) == .waiting(count: 1) && store.signal(.codex) == nil,
                "the wait is on the second assistant in the order, which is the case the fallback could not see")
        let item = MenuBarItem(store: store, prefs: prefs, actions: NotchActions())
        defer { item.remove() }
        item.update(captured: false)
        #expect(Self.spokenValue(of: item) == ToolSignal.waiting(count: 1).spokenText,
                "The rings beside the notch light up for whichever assistant is waiting, and the menu bar is one of the five surfaces that must read the same answer.")
    }

    /// The pin's own set is still the pin's own set: with the pin on, the figures and the glyph speak for the
    /// assistants the user named, and an unpinned one waiting is not the menu bar's news to carry.
    @MainActor @Test func aPinnedMenuBarStillSpeaksOnlyForTheToolsItWasPinnedTo() {
        #expect(MenuBarItem.signallingTools(visible: [.codex, .claude], pinned: true, chosen: [.codex]) == [.codex])
        #expect(MenuBarItem.signallingTools(visible: [.codex, .claude], pinned: false, chosen: [.codex]) == [.codex, .claude],
                "with the pin off the chosen set is not in force anywhere else either, so it may not narrow this")
        #expect(MenuBarItem.signallingTools(visible: [.codex, .claude], pinned: false, chosen: []) == [.codex, .claude])
    }

    /// The pinned-but-empty branch: the pin is on and no tool has reported a reading yet, which is every launch
    /// before the first scan lands. It returns early down the same path and was silent for the same reason.
    @MainActor @Test func theGlyphAlsoSpeaksWhileThePinIsOnAndNoReadingHasLandedYet() {
        let suite = "notchmeter.tests.menuBarSpokenPinned"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = Preferences(defaults: defaults)
        prefs.menuBarPin = true
        let now = Date()
        let reading = UsageReading(tool: .claude, windows: [], plan: nil, fetchedAt: now, observedAt: nil)
        let store = UsageStore(prefs: prefs, providers: [FixtureProvider(reading: reading)],
                               cache: ReadingCache(defaults: defaults), defaults: defaults, drainLog: nil, reportFile: nil)
        store.hookReceived(Hook.Message(event: "Notification", needsInput: true, sessionID: "a"), now: now)
        let item = MenuBarItem(store: store, prefs: prefs, actions: NotchActions())
        defer { item.remove() }
        #expect(store.status(.claude).reading == nil, "the branch under test is the one with no readings to pin")
        #expect(Self.spokenValue(of: item) == ToolSignal.waiting(count: 1).spokenText)
    }

    /// The status item's button, which `MenuBarItem` holds privately and `NSStatusBar` will not enumerate.
    @MainActor static func spokenValue(of item: MenuBarItem) -> String? {
        for child in Mirror(reflecting: item).children {
            if let status = child.value as? NSStatusItem { return status.button?.accessibilityValue() as? String }
        }
        return nil
    }

    @MainActor static func readout(style: CompactStyle, reading: UsageReading, signal: ToolSignal?) -> CompactReadout {
        CompactReadout(tool: .claude, status: .ready(reading), style: style, display: .used, windows: reading.windows, signal: signal)
    }

    @MainActor static func apiKeyReadout(style: CompactStyle, signal: ToolSignal?) -> CompactReadout {
        CompactReadout(tool: .claude, status: .idle("Billed by API key"), style: style, display: .used, signal: signal, apiKeyCost: "$42")
    }

    @MainActor static func fittingSize(_ view: some View) -> CGSize {
        let host = NSHostingView(rootView: view)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    /// The drawn pixels, padded so that a mark hanging off the corner of its content is inside the rendered bounds
    /// rather than clipped away by them — which would make an overlay that draws nothing look exactly like one that
    /// draws a tick.
    @MainActor static func pixels(_ view: some View) -> Data? {
        let renderer = ImageRenderer(content: view.padding(12))
        renderer.scale = 2
        return renderer.nsImage?.tiffRepresentation
    }

    @Test func aStateCanNeverFallOnAStripCollapsedToADot() {
        // Waiting makes the whole strip urgent, and Hide when idle only ever collapses a quiet one.
        #expect(Presence.level(windows: [], awaitingInput: true) == .urgent)
        #expect(!Presence.hides(level: .urgent, idleFor: 3600, wokeAgo: nil))
        // A finished turn does not raise the level, so it leans on the hook event's own wake instead: that holds the
        // rings up for five minutes, which has to outlast the hold with room to spare, or the state would land on a
        // 4 pt dot where hue would be the only thing left carrying it.
        #expect(ToolSignal.heldFor < 300)
        #expect(!Presence.hides(level: .quiet, idleFor: 3600, wokeAgo: ToolSignal.heldFor))
    }
}
