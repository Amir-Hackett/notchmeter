import AppKit
import Testing
@testable import Notchmeter

/// The window under the collapsed notch that takes a dropped file. What matters about it cannot be read off a
/// unit test (whether the Window Server offers it a drag inside the menu bar's band was read off a real drag,
/// DropCatcher.swift), so these pin what the reading depends on: its level, that it is registered, what it answers
/// a drag with, and that it neither shrinks under a drag nor comes back once closed.
@Suite struct DropCatcherRule {
    @MainActor @Test func sitsAtTheMenuBarsLevelUnderTheNotchPanel() {
        // The status bar's level is where a drag in the band is offered; the notch panel is above it so it keeps
        // drawing over the catcher.
        #expect(DropCatcherPresenter.level == .statusBar)
        #expect(DropCatcherPresenter.level.rawValue < NSWindow.Level.screenSaver.rawValue)
    }

    @MainActor @Test func takesFileURLsAndNothingElse() {
        let view = DropCatcherView()
        #expect(view.registeredDraggedTypes == [.fileURL])
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("NotchmeterTests.DropCatcher"))
        pasteboard.clearContents()
        pasteboard.writeObjects([URL(fileURLWithPath: "/tmp/a report.pdf") as NSURL, URL(string: "https://example.com")! as NSURL])
        #expect(DropCatcherView.urls(on: pasteboard).map(\.lastPathComponent) == ["a report.pdf"])
        pasteboard.clearContents()
    }

    /// A destination may only choose what the source allows: a copy for a file whose source permits one, and
    /// nothing for a source that offers a move alone, or for a drag with no file on it.
    @Test func answersACopyOnlyForAFileItsSourceLetsBeCopied() {
        #expect(DropCatcherView.answer(carriesFiles: true, allowed: [.copy, .move]) == .copy)
        #expect(DropCatcherView.answer(carriesFiles: true, allowed: .every) == .copy)
        #expect(DropCatcherView.answer(carriesFiles: true, allowed: .move) == [])
        #expect(DropCatcherView.answer(carriesFiles: true, allowed: []) == [])
        #expect(DropCatcherView.answer(carriesFiles: false, allowed: .copy) == [])
    }

    /// One drag from entry to drop, the way AppKit sends it: the panel is asked for once, however many updates
    /// follow, and the drop hands over the file.
    @MainActor @Test func aFileDragOpensThePanelOnceAndDropsItsFile() {
        let view = DropCatcherView()
        var entered = 0, over: [Bool] = [], dropped: [[URL]] = []
        view.entered = { entered += 1 }
        view.dragOver = { over.append($0) }
        view.dropped = { dropped.append($0) }
        let drag = FakeDrag(name: "aFileDrag", files: ["/tmp/a report.pdf"], allowed: [.copy, .move])
        defer { drag.draggingPasteboard.clearContents() }
        #expect(view.draggingEntered(drag) == .copy)
        #expect(view.draggingUpdated(drag) == .copy)
        #expect(view.draggingUpdated(drag) == .copy)
        #expect(entered == 1)
        #expect(over == [true])
        #expect(view.performDragOperation(drag))
        view.draggingEnded(drag)
        #expect(dropped.map { $0.map(\.lastPathComponent) } == [["a report.pdf"]])
        #expect(over == [true, false])
    }

    /// AppKit goes on sending updates after an entry that was refused. A drag with no readable file on it stays
    /// refused through them (it answered a copy on every update, and only the drop said no), and so does a file
    /// its source will not let be copied, until the source allows it.
    @MainActor @Test func aRefusedDragStaysRefusedOnUpdate() {
        let view = DropCatcherView()
        var entered = 0, over: [Bool] = []
        view.entered = { entered += 1 }
        view.dragOver = { over.append($0) }
        let empty = FakeDrag(name: "aRefusedDrag.empty", files: [], allowed: .every)
        defer { empty.draggingPasteboard.clearContents() }
        #expect(view.draggingEntered(empty) == [])
        #expect(view.draggingUpdated(empty) == [])
        #expect(!view.performDragOperation(empty))
        view.draggingExited(empty)
        #expect(entered == 0)
        #expect(over.isEmpty)

        let moveOnly = FakeDrag(name: "aRefusedDrag.move", files: ["/tmp/notes.txt"], allowed: .move)
        defer { moveOnly.draggingPasteboard.clearContents() }
        #expect(view.draggingEntered(moveOnly) == [])
        #expect(view.draggingUpdated(moveOnly) == [])
        #expect(!view.performDragOperation(moveOnly))
        #expect(entered == 0)
        // The modifier that made it a move is let go: the same drag may now be copied, and the panel opens for it.
        moveOnly.draggingSourceOperationMask = [.copy, .move]
        #expect(view.draggingUpdated(moveOnly) == .copy)
        #expect(entered == 1)
        // And taken away again: refused, with nothing announced twice.
        moveOnly.draggingSourceOperationMask = .move
        #expect(view.draggingUpdated(moveOnly) == [])
        view.draggingExited(moveOnly)
        #expect(entered == 1)
        #expect(over == [true, false])
        // The next drag starts from nothing.
        #expect(view.draggingUpdated(empty) == [])
    }

    /// While a drag is over it the catcher's frame only grows: opening the panel clears the news peek and narrows
    /// the collapsed shape, and a frame that followed would leave a pointer in the old band holding a file over
    /// nothing. Without a drag the frame asked for is the frame.
    @Test func theFrameDoesNotShrinkUnderADrag() {
        let peek = CGRect(x: 500, y: 949, width: 520, height: 33)
        let compact = CGRect(x: 620, y: 949, width: 280, height: 33)
        #expect(DropCatcherPresenter.frame(wanted: compact, heldSince: nil) == compact)
        #expect(DropCatcherPresenter.frame(wanted: compact, heldSince: peek) == peek)
        // A shape that grows or moves under the drag is taken up as well as the one it entered at.
        let wider = CGRect(x: 480, y: 949, width: 300, height: 33)
        #expect(DropCatcherPresenter.frame(wanted: wider, heldSince: peek) == CGRect(x: 480, y: 949, width: 540, height: 33))
    }

    /// hide() closes the catcher and then waits for the notch; a refresh queued before it can still ask for the
    /// catcher inside that wait. A closed presenter builds nothing, where it built a panel nobody would close.
    @MainActor @Test func aClosedCatcherIsNotBuiltAgain() {
        let presenter = DropCatcherPresenter()
        #expect(!presenter.hasWindow)
        presenter.close()
        presenter.show(true, under: CGRect(x: 620, y: 949, width: 280, height: 33), behavior: [.canJoinAllSpaces])
        #expect(!presenter.hasWindow)
    }
}

/// A drag as AppKit hands one to a destination, with the two things the catcher reads: the pasteboard and what
/// the source allows. Everything else is the protocol's furniture.
@MainActor private final class FakeDrag: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    var draggingSourceOperationMask: NSDragOperation

    init(name: String, files: [String], allowed: NSDragOperation) {
        draggingPasteboard = NSPasteboard(name: NSPasteboard.Name("NotchmeterTests.DropCatcher.\(name)"))
        draggingSourceOperationMask = allowed
        draggingPasteboard.clearContents()
        if !files.isEmpty { draggingPasteboard.writeObjects(files.map { URL(fileURLWithPath: $0) as NSURL }) }
    }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    func resetSpringLoading() {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}
