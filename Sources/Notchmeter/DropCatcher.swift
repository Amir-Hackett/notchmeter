import AppKit
import UniformTypeIdentifiers

/// The window that takes a file dragged onto the collapsed notch (FileDrop, 0.9.26).
///
/// The notch panel cannot take it itself. The Window Server offers a drag to the windows under the pointer, but
/// inside the menu bar's band, the top 33 points of a display with a camera housing, it offers it only to windows
/// at the menu bar's own level or below, which is how a status item accepts a drop. The notch panel sits at the
/// screen-saver level so that it draws over the bar, and a drop on the rings fell through it to whatever window
/// lay beneath: a file dragged onto the notch in 0.9.25 landed in the browser behind it, and the `.onDrop` on the
/// compact strip, which does work for a strip drawn below the band, never heard of it. Read on a 14-inch on
/// 2026-11-07 with a synthetic drag: a target at the status bar's level in the band took the drop, with the notch
/// panel ordered above it or not; the same target at the screen-saver level did not; the same target 12 points
/// below the band did.
///
/// So this is a clear, borderless panel at the status bar's level, framed to the collapsed shape (HoverRegions
/// .compact, the housing and the readouts beside it) and ordered under the notch panel, which keeps drawing over
/// it. It must take mouse events to be offered a drag at all (a click-through window is skipped, read the same
/// day), and clicks never reach it because the notch panel above is painted wherever this one lies. A drag over
/// it opens the panel as a drag over the strip was meant to (NotchController.dragEntered), and a drop on it goes
/// where a drop on the rings goes (NotchController.dropped). Nothing is read from the file here: the URLs go to
/// FileDrop and no further (docs/privacy.md).
@MainActor
final class DropCatcherPresenter {
    private var window: NSPanel?
    private let view = DropCatcherView()

    /// A file drag has come over the collapsed notch.
    var entered: () -> Void {
        get { view.entered }
        set { view.entered = newValue }
    }

    /// Files were dropped on the collapsed notch.
    var dropped: ([URL]) -> Void {
        get { view.dropped }
        set { view.dropped = newValue }
    }

    /// The level the window takes: the menu bar's own, which is where the Window Server looks for a drag's
    /// destination inside the bar's band, and one the notch panel's level is above.
    static let level = NSWindow.Level.statusBar

    /// Places the window under `compact` (the collapsed shape, in screen coordinates) and shows it, or takes it
    /// off screen when `wanted` is false: the setting is off, or the readouts are making way for a full-screen app.
    func show(_ wanted: Bool, under compact: CGRect, behavior: NSWindow.CollectionBehavior) {
        guard wanted else {
            window?.orderOut(nil)
            return
        }
        let window = self.window ?? makeWindow()
        if window.frame != compact { window.setFrame(compact, display: false) }
        window.collectionBehavior = behavior
        if !window.isVisible { window.orderFrontRegardless() }
    }

    /// Takes the window away: the presenter is being discarded.
    func close() {
        window?.orderOut(nil)
        window = nil
    }

    private func makeWindow() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // Not click-through: a window that ignores mouse events is not offered a drag either.
        panel.ignoresMouseEvents = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = Self.level
        panel.contentView = view
        window = panel
        return panel
    }
}

/// The catcher's one view: registered for file URLs, and nothing drawn.
final class DropCatcherView: NSView {
    var entered: () -> Void = {}
    var dropped: ([URL]) -> Void = { _ in }

    init() {
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("DropCatcherView is built in code") }

    /// The file URLs on a drag's pasteboard, in the order they were dragged; empty when it carries none.
    static func urls(on pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !Self.urls(on: sender.draggingPasteboard).isEmpty else { return [] }
        entered()
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = Self.urls(on: sender.draggingPasteboard)
        guard !urls.isEmpty else { return false }
        dropped(urls)
        return true
    }
}
