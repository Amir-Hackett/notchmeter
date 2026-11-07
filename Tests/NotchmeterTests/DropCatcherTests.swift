import AppKit
import Testing
@testable import Notchmeter

/// The window under the collapsed notch that takes a dropped file. What matters about it cannot be read off a
/// unit test (whether the Window Server offers it a drag inside the menu bar's band was read off a real drag,
/// DropCatcher.swift), so these pin the two things the reading depends on: its level, and that it is registered.
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
}
