import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Notchmeter

/// The notch's queued opens and closes against the hover machine's latest word (NotchController.leave, .expand and
/// .compact), driven on the controller itself. Its own transitions on the notch are swapped for a recorder
/// (`carryOut`), so no window is put on screen and what the notch was told, in what order, can be read back.
@MainActor @Suite(.serialized) struct NotchSequencing {
    static let suite = "NotchmeterTests.notchSequencing"
    let store: UsageStore
    let prefs: Preferences
    let controller: NotchController
    let notch = Recorder()

    final class Recorder {
        var carried: [HoverIntent.State] = []
        /// While set, a close does not return until `finish` is called, as DynamicNotchKit's does not for its morph.
        var holdsCloses = false
        var waiting: [CheckedContinuation<Void, Never>] = []
        func finish() {
            let all = waiting
            waiting = []
            for continuation in all { continuation.resume() }
        }
    }

    init() throws {
        (store, prefs) = DemoFixtures.store(now: Date(), moment: .permissionRequest, suite: Self.suite)
        controller = NotchController(screen: try #require(NSScreen.screens.first), store: store, prefs: prefs, actions: NotchActions())
        let notch = notch
        controller.carryOut = { state in
            notch.carried.append(state)
            if state == .compact, notch.holdsCloses { await withCheckedContinuation { notch.waiting.append($0) } }
        }
    }

    /// Lets the tasks the controller queued run.
    func settle() async {
        for _ in 0..<5 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func openOnTheRequest() async {
        store.panelOpenedForPrompt = true
        controller.expandNow(cause: .notification)
        await settle()
    }

    /// Closing Settings with a request pending asked for a close and then, in the same turn, for the request's
    /// panel. The close ran a turn late and cleared what the opening had just set, so the panel came back on every
    /// part and stayed open after the answer (0.7.0).
    @Test func anOpeningAskedForInTheTurnOfACloseKeepsWhatItSet() async {
        defer { UserDefaults.standard.removePersistentDomain(forName: Self.suite) }
        await openOnTheRequest()
        #expect(notch.carried == [.expanded])
        #expect(controller.hover.state == .expanded)

        controller.hover.dismiss(cause: .notification)
        #expect(!store.panelOpenedForPrompt, "the close is decided, and the store cleared, in the turn that asks for it")
        #expect(controller.leavingOpening?.promptOnly == true, "with what the panel was open on kept for its way out")
        store.panelOpenedForPrompt = true
        controller.expandNow(cause: .notification)
        await settle()
        #expect(!notch.carried.contains(.compact), "the close was overtaken, so the notch is never told to shut")
        #expect(controller.hover.state == .expanded)
        #expect(store.panelOpenedForPrompt, "and what the opening set is still set")
        #expect(controller.leavingOpening == nil, "the panel is drawn from the store again")
    }

    /// A Stop for a session whose request is still on the notch ends the request and, with Glance set, glances for
    /// the finished turn in the same turn. The close used to take the machine back to closed under the glance, which
    /// lost its clock, and DynamicNotchKit then shut a panel the machine read as open.
    @Test func aGlanceInTheTurnOfACloseStaysOpenWithItsClock() async throws {
        defer { UserDefaults.standard.removePersistentDomain(forName: Self.suite) }
        await openOnTheRequest()
        let session = try #require(store.sessions.all.first)
        controller.hover.dismiss(cause: .notification)
        store.attentionNotice = AttentionNotice(session: session, event: .waiting(blocking: true))
        controller.glance(for: 3)
        await settle()
        #expect(!notch.carried.contains(.compact))
        #expect(controller.hover.state == .expanded)
        #expect(controller.hover.isGlancing, "the glance still closes itself")
        #expect(store.attentionNotice?.session.id == session.id, "and its card is what the panel is on")
    }

    /// An opening that is overtaken is dropped the same way: opened and closed in one turn, the notch is told nothing.
    @Test func anOpeningOvertakenByACloseIsDropped() async {
        defer { UserDefaults.standard.removePersistentDomain(forName: Self.suite) }
        store.panelOpenedForPrompt = true
        controller.expandNow(cause: .notification)
        controller.hover.dismiss(cause: .notification)
        await settle()
        #expect(!notch.carried.contains(.expanded), "the notch is never opened for an opening already taken back")
        #expect(controller.hover.state == .compact)
        #expect(!store.panelOpenedForPrompt && controller.leavingOpening == nil)
    }

    /// The panel is on screen for as long as its close takes, and is drawn from its own copy for that long and no
    /// longer: a notice in it is a copy of its session, title and all.
    @Test func whatThePanelWasOpenOnIsKeptUntilItsCloseHasFinished() async throws {
        defer { UserDefaults.standard.removePersistentDomain(forName: Self.suite) }
        let session = try #require(store.sessions.all.first)
        store.attentionNotice = AttentionNotice(session: session, event: .waiting(blocking: true))
        controller.expandNow(cause: .glance)
        await settle()
        notch.holdsCloses = true
        controller.hover.dismiss(cause: .glance)
        await settle()
        #expect(notch.carried == [.expanded, .compact])
        #expect(store.attentionNotice == nil, "the store is cleared for everything that asks whether a card has the panel")
        #expect(controller.leavingOpening?.notice?.session.id == session.id, "and the panel still on screen keeps its card")

        // A request arrives while the panel is still on its way out: its opening reads the store, not the old copy.
        store.panelOpenedForPrompt = true
        controller.expandNow(cause: .notification)
        await settle()
        #expect(controller.leavingOpening == nil && store.panelOpenedForPrompt)
        notch.finish()
        await settle()
        #expect(controller.hover.state == .expanded && store.panelOpenedForPrompt, "the close finishing late takes nothing from the opening after it")

        // And a close left to finish lets its copy go.
        controller.hover.dismiss(cause: .notification)
        await settle()
        #expect(controller.leavingOpening?.promptOnly == true)
        notch.finish()
        await settle()
        #expect(controller.leavingOpening == nil)
    }
}
