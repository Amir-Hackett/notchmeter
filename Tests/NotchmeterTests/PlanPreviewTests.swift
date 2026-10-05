import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Notchmeter

/// What View Plan reads of a Cursor plan file (CursorPlanFiles.preview), by the shape Cursor writes one: a
/// frontmatter with `name`, `overview`, `todos` and `isProject`, and the plan's text under it.
@Suite struct PlanPreviewReading {
    @Test func thePlansNameAndCursorsOwnOverviewAreRead() {
        let preview = CursorPlanFiles.preview(parsing: """
        ---
        name: three echoes
        overview: Run three standalone echo commands one at a time, skipping any denied command without retrying.
        todos:
          - id: echo-one
            content: run echo one
            status: completed
        isProject: false
        ---

        # Three echoes

        Run three independent shell commands sequentially.
        """)
        #expect(preview?.name == "three echoes")
        #expect(preview?.summary == "Run three standalone echo commands one at a time, skipping any denied command without retrying.")
    }

    /// Cursor quotes an overview that holds a colon, and a task's own fields are not the plan's.
    @Test func aQuotedOverviewIsReadAndATasksFieldsAreNotThePlans() {
        let preview = CursorPlanFiles.preview(parsing: """
        ---
        name: unclaude
        overview: "Decouple pragmatically: tier the calls, then route them."
        todos:
          - id: a
            name: not the plan's name
            overview: nor its overview
            content: do it
            status: pending
        isProject: false
        ---
        """)
        #expect(preview?.name == "unclaude")
        #expect(preview?.summary == "Decouple pragmatically: tier the calls, then route them.")
    }

    @Test func aPlanWithNoOverviewGivesItsFirstParagraphAndOneWithNoFrontmatterItsHeading() {
        let bare = CursorPlanFiles.preview(parsing: """
        ---
        name: net check
        todos:
        isProject: false
        ---

        # Net check

        Create note.txt with the word ok,
        then run curl.

        ## Steps

        1. Create the file
        """)
        #expect(bare?.name == "net check")
        #expect(bare?.summary == "Create note.txt with the word ok, then run curl.", "one paragraph, joined, and no further")

        let none = CursorPlanFiles.preview(parsing: "# Close six bugs\n\nAll six threads are still open.\n\n---\n\nname: not frontmatter\n")
        #expect(none?.name == "Close six bugs")
        #expect(none?.summary == "All six threads are still open.", "a rule in the text opens no frontmatter")

        let code = CursorPlanFiles.preview(parsing: "# Only code\n\n```\nls\n```\n")
        #expect(code == CursorPlanFiles.Preview(name: "Only code", summary: nil), "a code block is not a summary")
        #expect(CursorPlanFiles.preview(parsing: "\n\n") == nil, "a file that says nothing shows nothing")
    }

    @Test func aLongOverviewIsCutAtAWordAndSaysSo() throws {
        let long = String(repeating: "All six threads are still open and snoozed. ", count: 40)
        let preview = try #require(CursorPlanFiles.preview(parsing: "---\nname: n\noverview: \(long)\n---\n"))
        let summary = try #require(preview.summary)
        #expect(summary.count <= CursorPlanFiles.previewSummaryLimit + 1)
        #expect(summary.hasSuffix("…") && !summary.dropLast().hasSuffix(" "))
        #expect(long.hasPrefix(String(summary.dropLast())))
        #expect(CursorPlanFiles.clipped("  two\nlines\tand a tab  ", to: 100) == "two lines and a tab")
        #expect(CursorPlanFiles.clipped("   ", to: 10) == nil)
    }
}

/// View Plan on a Cursor chat's row (UsageStore.cursorPlanAction): the plan shown on the row first, with Open in
/// Cursor under it, and what becomes of it when a plan's words may not be drawn.
@MainActor @Suite(.serialized) struct PlanPreviewOnTheRow {
    static let suite = "NotchmeterTests.planPreview"
    let store: UsageStore
    let prefs: Preferences
    let chat: AgentSession
    let file: String
    let box = Box()

    final class Box { var opened: [String] = []; var handedOff = 0; var opens = true }

    init() throws {
        (store, prefs) = DemoFixtures.store(now: Date(), moment: .cursorNotch, suite: Self.suite)
        chat = try #require(store.sessions.all.first { $0.planFile != nil })
        file = try #require(chat.planFile)
        let box = box
        store.readPlan = { _ in CursorPlanFiles.Preview(name: "Close six snoozed Intercom bugs", summary: "All six threads are still open and snoozed. None have an open pull request.") }
        store.openPlan = { box.opened.append($0); return box.opens }
        store.handedOff = { box.handedOff += 1 }
    }

    var key: String { SessionsCard.listKey(chat.id, .plan) }

    func height() -> CGFloat {
        let host = NSHostingView(rootView: NotchExpandedView(store: store, prefs: prefs, actions: NotchActions(), maxHeight: 10_000))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    @Test func viewPlanShowsThePlanHereAndOpenInCursorGoesToIt() {
        defer { UserDefaults.standard.removePersistentDomain(forName: Self.suite) }
        let closed = height()
        store.cursorPlanAction(file, .view, sessionID: chat.id)
        #expect(store.planPreviews[chat.id]?.preview.name == "Close six snoozed Intercom bugs")
        #expect(store.planPreviews[chat.id]?.file == file)
        #expect(store.openSessionLists.contains(key), "under the key that re-sizes the panel")
        #expect(box.opened.isEmpty && box.handedOff == 0, "nothing is opened in Cursor, and the panel stays")
        let shown = height()
        #expect(shown > closed, "the measured panel grows for it, which is what makes the window grow")

        // A second press folds it away.
        store.cursorPlanAction(file, .view, sessionID: chat.id)
        #expect(store.planPreviews[chat.id] == nil && !store.openSessionLists.contains(key))
        #expect(height() == closed)

        // Open in Cursor goes to the plan: the panel is told to get out of the way, and the row's copy is let go.
        store.cursorPlanAction(file, .view, sessionID: chat.id)
        store.cursorPlanAction(file, .open, sessionID: chat.id)
        #expect(box.opened == [file] && box.handedOff == 1)
        #expect(store.planPreviews[chat.id] == nil && !store.openSessionLists.contains(key))
    }

    /// A plan's name and summary are its author's words, shown under the same setting as a session's title.
    @Test func withTitlesOffViewPlanGoesStraightToCursorAndAnOpenPlanIsLetGo() {
        defer { UserDefaults.standard.removePersistentDomain(forName: Self.suite) }
        store.cursorPlanAction(file, .view, sessionID: chat.id)
        #expect(store.planPreviews[chat.id] != nil)
        store.dropTitles()
        #expect(store.planPreviews.isEmpty && !store.openSessionLists.contains(key), "titles off is every plan's words gone")

        prefs.sessionTitles = false
        store.cursorPlanAction(file, .view, sessionID: chat.id)
        #expect(store.planPreviews.isEmpty, "no words are read onto the row")
        #expect(box.opened == [file] && box.handedOff == 1, "View Plan is Open in Cursor then")
        prefs.sessionTitles = true
    }

    /// While the screen is shared and figures are hidden, a plan left open on its row is not drawn, and View Plan goes
    /// to Cursor rather than folding a preview nobody can see.
    @Test func whileTheScreenIsSharedAnOpenPlanIsNotDrawnAndViewPlanGoesToCursor() {
        defer { UserDefaults.standard.removePersistentDomain(forName: Self.suite) }
        let closed = height()
        store.cursorPlanAction(file, .view, sessionID: chat.id)
        #expect(height() > closed)
        prefs.hideFromScreenShare = true
        store.setScreenCaptured(true)
        #expect(store.hidesFigures)
        #expect(height() <= closed, "none of the plan's words are on the row")
        store.cursorPlanAction(file, .view, sessionID: chat.id)
        #expect(box.opened == [file] && box.handedOff == 1)
        #expect(store.planPreviews[chat.id] == nil && !store.openSessionLists.contains(key))
        store.setScreenCaptured(false)
        prefs.hideFromScreenShare = false
    }

    @Test func aPlanThatIsGoneSaysSoAndARowThatGoesTakesItsPlanWithIt() {
        defer { UserDefaults.standard.removePersistentDomain(forName: Self.suite) }
        // Nothing to show and nothing to open: the note, on a panel that stays.
        store.readPlan = { _ in nil }
        box.opens = false
        store.cursorPlanAction(file, .view, sessionID: chat.id)
        #expect(store.planPreviews.isEmpty && box.handedOff == 0)
        #expect(store.cursorActionNotes[chat.id] == L("The plan file is gone"))

        // A file that says nothing to show, but is there: straight to Cursor.
        box.opens = true
        store.cursorPlanAction(file, .view, sessionID: chat.id)
        #expect(box.handedOff == 1)

        // Shown, and then the row is removed: the words go with it.
        store.readPlan = { _ in CursorPlanFiles.Preview(name: "p", summary: "s") }
        store.cursorPlanAction(file, .view, sessionID: chat.id)
        #expect(store.planPreviews[chat.id] != nil)
        store.dismissSession(chat.id)
        #expect(store.planPreviews[chat.id] == nil && !store.openSessionLists.contains(key))
    }
}
