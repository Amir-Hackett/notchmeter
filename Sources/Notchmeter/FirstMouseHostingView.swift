import AppKit
import SwiftUI

/// The hosting view for SwiftUI content in a panel that never activates the app (SettingsPanel), with one change:
/// a click lands on the control it was aimed at even when the panel is not key.
///
/// AppKit asks the view under a click whether it accepts "first mouse" — a click on a window that is not key —
/// and when the answer is no, the window becomes key and the click is spent on that. AppKit's own controls answer
/// yes; SwiftUI's hosting view answers no. In an ordinary app that is rarely felt, because the app activates and
/// its windows stay key between clicks. Here the app is an accessory that never activates, so the Settings panel
/// loses key every time the pointer clicks anywhere else — the app being worked in, the rings, the Dock — and the
/// next click on a toggle, stepper or picker only brought the panel back rather than moving the control. That read
/// as a control that needed two clicks, or one that answered late; a sample of the process during a run of such
/// clicks showed the main thread idle, which is what said the delay was routing rather than work.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
