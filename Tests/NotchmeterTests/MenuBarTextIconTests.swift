import AppKit
import Testing
@testable import Notchmeter

/// The text-style menu bar item draws a glyph only while an assistant waits: the figures already name the item, so
/// the gauge beside them was noise, and a finish is not something to act on.
@Suite struct MenuBarTextIcon {
    @Test func onlyAWaitDrawsAGlyph() {
        #expect(MenuBarItem.textIcon(signal: nil) == nil)
        #expect(MenuBarItem.textIcon(signal: .finished(turn: 120)) == nil)
        #expect(MenuBarItem.textIcon(signal: .waiting(count: 1)) != nil)
    }
}
