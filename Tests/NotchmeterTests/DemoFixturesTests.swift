import CoreGraphics
import Foundation
import Testing
@testable import Notchmeter

/// The readings and cost `--render-assets` draws add up, sit in the calm state the README describes, and seed a
/// store without a provider read.
@Suite struct DemoFixtureReadings {
    @Test func costSeriesAddsUpToTheHeadlineFigures() {
        let cost = DemoFixtures.cost(now: Date())
        // Two tools that can report spend, side by side; the headline figures are their total.
        #expect(cost.providers.map(\.tool) == [.claude, .cursor])
        #expect(cost.providers.map(\.source) == [.localTranscripts, .billingExport])
        #expect(abs(cost.today - cost.providers.reduce(0) { $0 + $1.totals(.today).cost }) < 1e-9)
        #expect(cost.provider(.cursor)?.burnMultiple == nil)
        #expect(cost.daily.count == 30)
        #expect(abs(cost.daily.reduce(0) { $0 + $1.cost } - cost.last30Days) < 0.01)
        #expect(cost.daily.last?.cost == cost.today)
        #expect(cost.daily.dropLast().last?.cost == cost.yesterday)
        #expect(cost.burnMultiple.map { $0 >= Advisor.burnThreshold } == true)
    }

    @Test func everyRingIsQuietAndOnPace() {
        let now = Date()
        let windows = DemoFixtures.readings(now: now).flatMap(\.windows)
        #expect(Presence.level(windows: windows, awaitingInput: false, now: now) == .quiet)
        for window in windows where window.usedFraction != nil && window.periodDuration != nil {
            #expect(Pace.status(for: window, now: now) == .ahead)
        }
    }

    /// Every reset sits in the middle of the unit its countdown prints, so a render that lays out one view a
    /// second after another gets the same words in both. It did not: `expanded.png` read "Resets in 3h 19m" and
    /// `expanded-contrast.png`, drawn a moment later from the same fixtures, read "3h 18m" — a pair offered as
    /// evidence about contrast that disagreed with itself about the clock.
    @Test func everyCountdownReadsTheSameThroughoutARender() {
        let now = Date()
        for window in DemoFixtures.readings(now: now).flatMap(\.windows) {
            guard let resetsAt = window.resetsAt else { continue }
            let first = ResetText.line(resetsAt: resetsAt, hasLimit: true, display: .countdown, timeFormat: .auto, now: now)
            for offset in [1.0, 5.0, 25.0] {
                let later = ResetText.line(resetsAt: resetsAt, hasLimit: true, display: .countdown, timeFormat: .auto,
                                           now: now.addingTimeInterval(offset))
                #expect(later == first, "\(window.id) reads \(first) at the start of a render and \(later) \(Int(offset)) s in")
            }
        }
    }

    @MainActor @Test func seedsAStoreWithoutAProviderRead() {
        let now = Date()
        let (store, prefs) = DemoFixtures.store(now: now)
        #expect(store.visibleTools == [.claude, .codex, .cursor])
        #expect(store.readyReadings.count == 3)
        #expect(store.nextUpdate != nil)
        #expect(store.advice.contains { $0.id == "burn/claude" })
        #expect(prefs.resetDisplay == .countdown)
    }
}

/// The GIF's open is DynamicNotchKit's spring sampled over the morph.
@Suite struct NotchMorph {
    @Test func theOpeningSpringStartsAtRestOvershootsOnceAndSettles() {
        let samples = (0..<24).map { AssetRenderer.bounce(Double($0) / 23) }
        #expect(abs(samples[0]) < 0.001)
        #expect(samples.max()! > 1)
        #expect(abs(samples[23] - 1) < 0.01)
    }
}

/// The hook state the pictures are drawn over. Both signal states are read against the clock, so the thing worth
/// pinning is not only that each moment resolves to the mark it promises but that it is far enough inside its own
/// window to survive a render that lays every view out and encodes an eighty-two-frame GIF between seeding the
/// store and writing the last file.
@Suite struct DemoFixtureSessions {
    let now = DateParsing.iso8601("2026-09-01T15:00:00Z")!
    /// The turn the just-finished moment reports: submitted 8m 52s ago, stopped 12 s ago.
    let turn: TimeInterval = 8 * 60 + 52 - 12

    @Test func theWaitingMomentHoldsAPermissionPromptOnClaudeAndNothingElse() {
        let sessions = DemoFixtures.sessions(now: now, moment: .waiting)
        #expect(sessions.count == 2)
        #expect(sessions.waiting(of: .claude).count == 1)
        #expect(sessions.waiting(of: .codex).isEmpty)
        #expect(sessions.isWorking(.claude) == false)
        #expect(ToolSignal.resolve(waiting: sessions.waiting(of: .claude).count, finish: sessions.finish(of: .claude, now: now),
                                   working: sessions.isWorking(.claude), attended: nil, now: now) == .waiting(count: 1))
    }

    @Test func theJustFinishedMomentHoldsATurnThatEndedAndNoWait() {
        let sessions = DemoFixtures.sessions(now: now, moment: .justFinished)
        #expect(sessions.waiting(of: .claude).isEmpty)
        let finish = sessions.finish(of: .claude, now: now)
        #expect(finish?.turn == turn)
        #expect(ToolSignal.resolve(waiting: 0, finish: finish, working: sessions.isWorking(.claude), attended: nil, now: now)
                == .finished(turn: turn))
    }

    /// The failure this guards is a picture with no mark in it at all, which is silent: the render succeeds, the
    /// files are written, and the feature the frame exists to show is simply absent. Half of each window is the
    /// margin, and half of ninety seconds is the tighter of the two by a wide margin.
    @Test func bothMomentsSitWellInsideTheWindowTheirStateIsReadAgainst() {
        let waiting = DemoFixtures.sessions(now: now, moment: .waiting)
        guard case .waiting(let since)? = waiting.waiting(of: .claude).first?.state else {
            Issue.record("the waiting moment has no waiting session")
            return
        }
        #expect(now.timeIntervalSince(since) < SessionTracker.waitingTimeout / 2)
        let finish = DemoFixtures.sessions(now: now, moment: .justFinished).finish(of: .claude, now: now)
        #expect(finish.map { now.timeIntervalSince($0.at) < ToolSignal.heldFor / 2 } == true)
    }

    /// The fixtures show Claude Code's sessions by choice: Cursor's hook lights the same tick (never the hand, since
    /// Cursor has no event for a wait), but the pictures keep the one assistant whose hook shows every state, so a
    /// fixture lighting another ring would change the README for nothing it adds.
    @Test func noAssistantButClaudeCarriesASessionInEitherMoment() {
        for moment in [DemoFixtures.Moment.waiting, .justFinished] {
            let sessions = DemoFixtures.sessions(now: now, moment: moment)
            #expect(sessions.all.allSatisfy { $0.tool == .claude })
            for tool in ToolID.allCases where tool != .claude {
                #expect(sessions.waiting(of: tool).isEmpty)
                #expect(sessions.finish(of: tool, now: now) == nil)
            }
        }
    }

    @MainActor @Test func theSeededStoreShowsTheWaitOnItsRingsItsCardAndItsAdvice() {
        let (store, _) = DemoFixtures.store(now: now, moment: .waiting)
        #expect(store.signal(.claude, now: now) == .waiting(count: 1))
        #expect(store.signal(.codex, now: now) == nil)
        #expect(store.presence == .urgent, "a waiting assistant is what makes the rings loud (Presence.level)")
        let advice = Advisor.advise(store.adviceContext(now: now))
        #expect(advice.contains { $0.id == "waiting/claude" })
        #expect(advice.contains { $0.id == "burn/claude" },
                "the wait is added to the strip rather than pushed onto it: the burn line the panel picture has always shown must survive")
    }

    @MainActor @Test func theSeededStoreShowsTheFinishedTurnInTheOtherMoment() {
        let (store, _) = DemoFixtures.store(now: now, moment: .justFinished)
        #expect(store.signal(.claude, now: now) == .finished(turn: turn))
        #expect(store.presence == .quiet,
                "a finish deliberately does not lift the presence, so the two rows of signal-rings.png differ in size as well as in mark")
    }
}

/// The Product Hunt frame that lays one bitmap out twice, unflipped then flipped. It once drew the flipped copy
/// at the unflipped one's own x, which for a centred picture is the same x, so the opaque second tile landed
/// exactly over the first and `07-edges.png` shipped showing one right-hand notch where its caption promised a
/// pair — a bug that is invisible in the file it produces, because a frame with one tile in it looks like a frame
/// with one tile in it. These read the pixels back so it cannot come back silently.
@MainActor @Suite struct GalleryComposites {
    static let canvas = CGSize(width: 1270, height: 760)
    static let tile = 240

    /// A stand-in for the notch picture rather than the notch picture itself: `edgeNotch` needs a seeded store and
    /// a hosting view, and none of that is what this frame gets wrong. What it gets wrong is arithmetic over a
    /// rectangle, and a rectangle of known colour is the cleanest thing to do that arithmetic to.
    static func stripe(dark: Range<Int>) throws -> CGImage {
        try AssetRenderer.bitmap(CGSize(width: tile, height: tile), pixelScale: 1) { ctx in
            ctx.setFillColor(CGColor(srgbRed: 0x1c / 255, green: 0x1c / 255, blue: 0x1e / 255, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(tile), height: CGFloat(tile)))
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            ctx.fill(CGRect(x: CGFloat(dark.lowerBound), y: 0, width: CGFloat(dark.count), height: CGFloat(tile)))
        }
    }

    /// The runs of columns that hold at least one all but black pixel. The gallery's own ground is #1c1c1e, which
    /// sums to 86 across the three channels, so a threshold of 30 separates the fill from the ground without
    /// resting on either being exact.
    static func darkRuns(in image: CGImage) throws -> [Range<Int>] {
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { throw AssetRenderer.Failure.snapshot("a readback context") }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var runs: [Range<Int>] = []
        var start: Int?
        for x in 0 ... width {
            let dark = x < width && (0 ..< height).contains { y in
                let index = (y * width + x) * 4
                return Int(bytes[index]) + Int(bytes[index + 1]) + Int(bytes[index + 2]) < 30
            }
            if dark, start == nil { start = x }
            if !dark, let from = start { runs.append(from ..< x); start = nil }
        }
        return runs
    }

    @Test func thePairedEdgeFrameLeavesTwoSeparateNotchesRatherThanOneOverTheOther() throws {
        let frame = try AssetRenderer.composite(Self.stripe(dark: 0 ..< Self.tile), caption: "", lines: [],
                                                canvas: Self.canvas, beside: Self.stripe(dark: 0 ..< Self.tile))
        let runs = try Self.darkRuns(in: frame)
        #expect(runs.count == 2, "two tiles that overlap read back as one run; the caption promises a pair")
        guard runs.count == 2 else { return }
        #expect(runs[0].count == runs[1].count)
        #expect(runs[1].lowerBound > runs[0].upperBound, "the runs must not touch, let alone overlap")
        // Both tiles are placed from one spread, so the pair is centred whatever the tile's own size.
        #expect(abs(runs[0].lowerBound + runs[1].upperBound - Int(Self.canvas.width)) <= 1)
    }

    /// The second picture is drawn exactly as it is handed over, and no longer flipped. Flipping is what let one
    /// render of the left edge stand for both, and it is also what put every ring's signal mark on the wrong
    /// corner of the right-hand tile, so the caller renders each edge for itself (`AssetRenderer.edgeNotch`).
    /// A stripe down one side of the stand-in is what tells a copy laid down as given from a mirrored one; the
    /// solid tile above cannot.
    @Test func theSecondTileIsDrawnAsGivenAndNotFlipped() throws {
        let frame = try AssetRenderer.composite(Self.stripe(dark: 0 ..< 60), caption: "", lines: [],
                                                canvas: Self.canvas, beside: Self.stripe(dark: 0 ..< 60))
        let runs = try Self.darkRuns(in: frame)
        #expect(runs.count == 2)
        guard runs.count == 2 else { return }
        // Both stripes sit at their own tile's leading edge, so the gap between the runs is the rest of the first
        // tile plus the margin between them — never the whole tile's width, which is what a flip would give.
        #expect(runs[1].lowerBound - runs[0].upperBound < Self.tile,
                "a stripe drawn at each tile's leading edge is the picture as handed over; a flip would push the second stripe to the far side")
    }

    /// The frame that is not mirrored must stay one picture. The fix widened the spread and the scale by a factor
    /// of `tiles`, and a `tiles` that came out at two everywhere would have shrunk every other frame by half.
    @Test func aFrameThatAsksForNoMirrorDrawsOneTileAtItsFullSize() throws {
        let frame = try AssetRenderer.composite(Self.stripe(dark: 0 ..< Self.tile), caption: "", lines: [],
                                                canvas: Self.canvas)
        let runs = try Self.darkRuns(in: frame)
        #expect(runs.count == 1)
        #expect(runs.first?.count == Self.tile)
    }

    /// A picture wide enough to want the room takes it: the frames that carry text beside the picture used to
    /// give the picture half the canvas and start it at the margin, so a picture that filled its half ran a
    /// margin's width under the first character of every line. `03-advice` did.
    @Test func aPictureWithLinesBesideItStopsShortOfTheColumnTheLinesStartIn() throws {
        let wide = try AssetRenderer.bitmap(CGSize(width: 2000, height: 400), pixelScale: 1) { ctx in
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 2000, height: 400))
        }
        let frame = try AssetRenderer.composite(wide, caption: "", lines: ["one", "two", "three"],
                                                canvas: Self.canvas)
        let runs = try Self.darkRuns(in: frame)
        #expect(runs.count == 1)
        #expect((runs.first?.upperBound ?? Int.max) <= Int(Self.canvas.width / 2),
                "the picture crosses the middle of the canvas, which is where the text column begins")
    }
}

/// Where the Settings sheet breaks its columns. An even `height / columns` cut *Will run out (behind pace)* in
/// half at the foot of one column and again at the head of the next, in the README's picture and in the
/// gallery's alike; the cut has to land in the gap the form leaves between two rows.
@Suite struct SettingsSheetColumns {
    static let width = 200
    static let rowHeight = 40
    static let gap = 12

    /// A stand-in for the Settings capture: bands of many colours where the real one has text and controls,
    /// separated by flat gaps. `quietBands` counts colours per scanline rather than measuring brightness, so
    /// what a row is made of does not matter and what separates two rows does.
    static func rows(_ count: Int) throws -> CGImage {
        let height = count * (rowHeight + gap)
        return try AssetRenderer.bitmap(CGSize(width: width, height: height), pixelScale: 1) { ctx in
            ctx.setFillColor(CGColor(gray: 0.1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
            for row in 0 ..< count {
                for step in 0 ..< 20 {
                    ctx.setFillColor(CGColor(srgbRed: Double(step) / 20, green: 0.5, blue: 1 - Double(step) / 20, alpha: 1))
                    ctx.fill(CGRect(x: CGFloat(step) * 10, y: CGFloat(row * (rowHeight + gap) + gap), width: 10, height: CGFloat(rowHeight)))
                }
            }
        }
    }

    /// A gap runs from the end of one row to the start of the next.
    static func isInAGap(_ cut: Int) -> Bool {
        let within = cut % (rowHeight + gap)
        return within < gap
    }

    @Test func everyColumnBreaksInTheGapBetweenTwoRowsRatherThanThroughOne() throws {
        // Fifteen rows over four columns puts the even cut a third of the way down a row three times over.
        let image = try Self.rows(15)
        let cuts = AssetRenderer.columnCuts(of: image, columns: 4)
        #expect(cuts.count == 5)
        #expect(cuts.first == 0)
        #expect(cuts.last == image.height)
        for cut in cuts.dropFirst().dropLast() {
            #expect(Self.isInAGap(cut), "a column ends \(cut % (Self.rowHeight + Self.gap)) px into a row")
        }
    }

    @Test func theColumnsAreStillNearlyEvenAndNeverOutOfOrder() throws {
        let image = try Self.rows(15)
        let cuts = AssetRenderer.columnCuts(of: image, columns: 4)
        let heights = zip(cuts, cuts.dropFirst()).map { $1 - $0 }
        #expect(heights.allSatisfy { $0 > 0 })
        // A seam travels at most an eighth of a column, so no column is more than a quarter off the even share.
        let even = Double(image.height) / 4
        #expect(heights.allSatisfy { abs(Double($0) - even) <= even / 4 })
    }

    /// A capture with nothing to cut on keeps the arithmetic it would have had, rather than losing a column.
    @Test func aCaptureWithNoGapWithinReachKeepsTheEvenCut() throws {
        let solid = try AssetRenderer.bitmap(CGSize(width: 200, height: 800), pixelScale: 1) { ctx in
            for y in 0 ..< 800 {
                for step in 0 ..< 20 {
                    ctx.setFillColor(CGColor(srgbRed: Double(step) / 20, green: Double(y % 7) / 7, blue: 0.4, alpha: 1))
                    ctx.fill(CGRect(x: CGFloat(step) * 10, y: CGFloat(y), width: 10, height: 1))
                }
            }
        }
        #expect(AssetRenderer.quietBands(in: solid, minimumHeight: 6).isEmpty)
        #expect(AssetRenderer.columnCuts(of: solid, columns: 4) == [0, 200, 400, 600, 800])
    }
}
