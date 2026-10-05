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

    /// Files that are not as Cursor writes them show what can be shown and never their own markup.
    @Test func aFileThatIsNotAsCursorWritesItShowsNoMarkup() {
        #expect(CursorPlanFiles.preview(parsing: "---\nname: cut short\noverview: The file ends here\ntodos:\n  - id: a\n") == nil,
                "a frontmatter that never closes is not its own summary")
        let null = CursorPlanFiles.preview(parsing: "---\nname: ~\noverview: null\n---\n\n# From the text\n\nAnd its first paragraph.\n")
        #expect(null == CursorPlanFiles.Preview(name: "From the text", summary: "And its first paragraph."), "YAML's nothing is no name and no summary")
        let wrapped = CursorPlanFiles.preview(parsing: "---\nname: wrapped\noverview: The first line of it\n  and the second,\n  and the third.\ntodos:\n  - id: a\n    content: not part of it\n---\n")
        #expect(wrapped?.summary == "The first line of it and the second, and the third.")
        let quoted = CursorPlanFiles.preview(parsing: "---\nname: quoted\noverview: \"Two lines: the first\n  and the second.\"\n---\n")
        #expect(quoted?.summary == "Two lines: the first and the second.")
        let dressed = CursorPlanFiles.preview(parsing: "# Dressed\n\n<!-- a note to self\nover two lines -->\n~~~\nls\n~~~\n- a list\n- of things\n\n| a | table |\n\n> a quotation\n\n1. numbered\n\nThe first prose there is.\n")
        #expect(dressed == CursorPlanFiles.Preview(name: "Dressed", summary: "The first prose there is."), "comments, code, lists, tables and quotations are not a summary")
        #expect(CursorPlanFiles.preview(parsing: "# Only a list\n\n- one\n- two\n") == CursorPlanFiles.Preview(name: "Only a list", summary: nil))
    }

    /// Only the head of a file is read, on the main actor as the row opens, whatever the file's size; a byte-order
    /// mark is not part of its first line, and a file that is not text is not shown at all.
    @Test func onlyTheHeadOfAFileIsRead() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("plan-preview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let big = folder.appendingPathComponent("big.plan.md")
        var data = Data([0xEF, 0xBB, 0xBF]) + Data("---\nname: big\noverview: Read from the head.\n---\n\n".utf8)
        data.append(Data(String(repeating: "Line after line of plan, each one much like the last.\n", count: 40_000).utf8))
        try data.write(to: big)
        #expect(data.count > CursorPlanFiles.previewReadLimit * 20)
        #expect(CursorPlanFiles.preview(in: big) == CursorPlanFiles.Preview(name: "big", summary: "Read from the head."))
        // A frontmatter longer than the head is one that never closes within it.
        let long = folder.appendingPathComponent("long.plan.md")
        try Data(("---\nname: long\ntodos:\n" + String(repeating: "  - id: a\n    content: one more task\n", count: 4_000) + "---\n").utf8).write(to: long)
        #expect(CursorPlanFiles.preview(in: long) == nil)
        let binary = folder.appendingPathComponent("binary.plan.md")
        try Data([0xFF, 0xFE, 0x00, 0x41, 0xD8, 0x00]).write(to: binary)
        #expect(CursorPlanFiles.preview(in: binary) == nil)
        #expect(CursorPlanFiles.preview(in: folder.appendingPathComponent("gone.plan.md")) == nil)
        try Data().write(to: folder.appendingPathComponent("empty.plan.md"))
        #expect(CursorPlanFiles.preview(in: folder.appendingPathComponent("empty.plan.md")) == nil)
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

        // The chat has made another plan since: its preview takes the old one's place, where folding the old one,
        // which the row no longer draws, was a press that did nothing.
        let newer = file + ".newer.plan.md"
        store.readPlan = { $0 == newer ? CursorPlanFiles.Preview(name: "The newer plan", summary: nil) : nil }
        store.cursorPlanAction(newer, .view, sessionID: chat.id)
        #expect(store.planPreviews[chat.id] == UsageStore.ShownPlan(file: newer, preview: CursorPlanFiles.Preview(name: "The newer plan", summary: nil)))
        #expect(store.openSessionLists.contains(key))
        store.cursorPlanAction(newer, .view, sessionID: chat.id)
        #expect(store.planPreviews[chat.id] == nil, "and a second press on that one folds it")
        store.readPlan = { _ in CursorPlanFiles.Preview(name: "Close six snoozed Intercom bugs", summary: "All six threads are still open and snoozed. None have an open pull request.") }
        store.cursorPlanAction(file, .view, sessionID: chat.id)

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
        // Measured against the same panel with nothing shown on the row, not against the panel before the screen was
        // shared: hiding figures makes the whole panel shorter, which a comparison with that one passed whatever
        // the row drew.
        let withThePlanOpenButHidden = height()
        store.cursorPlanAction(file, .view, sessionID: chat.id)
        #expect(box.opened == [file] && box.handedOff == 1)
        #expect(store.planPreviews[chat.id] == nil && !store.openSessionLists.contains(key))
        #expect(withThePlanOpenButHidden == height(), "none of the plan's words were on the row while the screen was shared")
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
