//
// FirstMouseNotchHostingView.swift
// DynamicNotchKit
//
// Notchmeter: not part of upstream DynamicNotchKit.
//

import AppKit
import SwiftUI

/// The hosting view for the notch panel's content, with one change from `NSHostingView`: a click lands on the
/// control it was aimed at even when the panel is not key.
///
/// The app is an accessory that never activates and nothing makes this panel key, so every click on the open
/// panel is a "first mouse" click. AppKit asks the view under such a click whether it accepts it; `NSHostingView`
/// answers no, and the click is spent making the window key. AppKit's own controls answer yes for themselves,
/// so a segmented `Picker` in the panel took its clicks while the SwiftUI buttons and tap gestures beside it
/// did not -- which is what made replacing that picker with SwiftUI look like a dead control.
///
/// The app carries the same subclass for its Settings and Dashboard panels (`FirstMouseHostingView`); this one
/// is declared here because the vendored framework cannot see the app's target.
final class FirstMouseNotchHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
