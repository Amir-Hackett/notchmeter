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
    /// Set by `close()`. hide() closes the catcher and then waits for the notch to go, and a refresh queued
    /// before that (NotchController.observeContent) can still run inside the wait and ask for the catcher
    /// again. Asked of a presenter with no window, that built a new panel which nothing would ever close, over
    /// a controller that was being discarded, and a file dropped on it went nowhere. A closed presenter stays
    /// closed; the controller that replaces this one brings its own.
    private var closed = false
    /// Where the window goes, which under a drag is not simply where it was last asked to go (DropCatcherFrame).
    private var placement = DropCatcherFrame()

    init() {
        view.dragOver = { [weak self] over in self?.dragOver(over) }
    }

    /// Whether the window is built: false before the first `show`, and for good after `close()`.
    var hasWindow: Bool { window != nil }


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
        guard !closed else { return }
        guard wanted else {
            window?.orderOut(nil)
            // A window taken off screen is told nothing more about a drag that was over it.
            _ = placement.dragEnded()
            return
        }
        let window = self.window ?? makeWindow()
        let frame = placement.ask(for: compact)
        if window.frame != frame { window.setFrame(frame, display: false) }
        window.collectionBehavior = behavior
        if !window.isVisible { window.orderFrontRegardless() }
    }

    /// Takes the window away: the presenter is being discarded.
    func close() {
        closed = true
        window?.orderOut(nil)
        window = nil
    }

    private func dragOver(_ over: Bool) {
        guard let window else { return }
        if over {
            placement.dragBegan(at: window.frame)
        } else if let wanted = placement.dragEnded(), window.frame != wanted {
            window.setFrame(wanted, display: false)
        }
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

/// Where the catcher's window goes across a drag.
///
/// With no drag over it, where it was last asked to go. While a drag is over it, its frame only grows: opening
/// the panel for the drag clears the news peek, the collapsed shape narrows with it, and a catcher that followed
/// would slide out from under a pointer still holding the file, whose drop then fell to the window beneath. Every
/// frame it has had since the drag came over it is kept, not only the first: a shape that widens and then narrows
/// again under the same drag would otherwise take back the part it had just offered. The frame last asked for is
/// taken up once the drag has left, dropped or ended.
struct DropCatcherFrame: Equatable {
    /// The frame last asked for.
    private(set) var wanted: CGRect?
    /// Everything the window has covered since a drag came over it; nil with no drag.
    private(set) var held: CGRect?

    /// The frame to take now that `frame` is asked for.
    mutating func ask(for frame: CGRect) -> CGRect {
        wanted = frame
        guard let held else { return frame }
        let grown = held.union(frame)
        self.held = grown
        return grown
    }

    /// A drag has come over the window, which is at `frame`.
    mutating func dragBegan(at frame: CGRect) { held = frame }

    /// The drag has gone; the frame to return to, when one was asked for.
    mutating func dragEnded() -> CGRect? {
        held = nil
        return wanted
    }
}

/// The catcher's one view: registered for file URLs, and nothing drawn.
final class DropCatcherView: NSView {
    var entered: () -> Void = {}
    var dropped: ([URL]) -> Void = { _ in }
    /// A drag the catcher accepts has come over it (true), or has left, dropped or ended (false).
    var dragOver: (Bool) -> Void = { _ in }
    /// What the drag now over the view was found to carry when it entered, and whether it has been announced.
    private var carriesFiles = false
    private var announced = false

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

    /// What a drag is answered with: a copy, when it carries a file and its source allows one; nothing otherwise.
    /// A destination may only choose an operation the source permits, and a source can offer a file to be moved
    /// and not copied.
    nonisolated static func answer(carriesFiles: Bool, allowed: NSDragOperation) -> NSDragOperation {
        carriesFiles && allowed.contains(.copy) ? .copy : []
    }

    /// The answer for the drag now over the view, announcing it the first time the answer is yes. AppKit goes on
    /// sending updates after an entry that was refused, and what the source allows can change under a drag (a
    /// modifier key), so the entry and every update are answered the same way and from what the entry found.
    private func answer(_ sender: NSDraggingInfo) -> NSDragOperation {
        let operation = Self.answer(carriesFiles: carriesFiles, allowed: sender.draggingSourceOperationMask)
        if operation == .copy, !announced {
            announced = true
            dragOver(true)
            entered()
        }
        return operation
    }

    private func finish() {
        carriesFiles = false
        guard announced else { return }
        announced = false
        dragOver(false)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        carriesFiles = !Self.urls(on: sender.draggingPasteboard).isEmpty
        announced = false
        return answer(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { answer(sender) }

    override func draggingExited(_ sender: NSDraggingInfo?) { finish() }

    override func draggingEnded(_ sender: NSDraggingInfo) { finish() }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = Self.urls(on: sender.draggingPasteboard)
        guard Self.answer(carriesFiles: !urls.isEmpty, allowed: sender.draggingSourceOperationMask) == .copy else { return false }
        dropped(urls)
        return true
    }
}
