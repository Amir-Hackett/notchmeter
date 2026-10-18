import AppKit
import SwiftUI

/// The drop-zone box that appears over the open panel while a file is being dragged to the notch (0.9.24).
///
/// Why this exists rather than a SwiftUI `.onDrop` on the panel. The panel is a non-activating panel at the
/// screen-saver level, and a SwiftUI drop target inside such a window is never offered the drag: the window
/// intercepts it (so the drop no longer falls through to whatever is behind the panel) but the hosting view's
/// SwiftUI `onDrop` closure does not fire, and the drag ends with nothing taken. An AppKit `NSView` that
/// registers for the file type and implements the dragging-destination methods itself does receive it. So this
/// is a small panel, shown only while a file is in hand near the notch, that sits just above the notch panel,
/// covers where the panel's content is, draws a dashed drop-zone box naming the session the file will go to, and
/// on a drop hands the paths to the controller (`NotchController.dropped`). It takes no clicks and is gone the
/// instant the drag ends, so it never stands between the pointer and the panel at any other time.
@MainActor
final class FileDropCatcher {
    /// Called with the dropped file URLs; the controller routes them to the session FileDrop.target picks.
    var onDrop: ([URL]) -> Void = { _ in }

    private let model = DropZoneModel()
    private var panel: NSPanel?

    /// Shows the box over `rect` (the panel's content, in screen coordinates), naming `label` as the destination.
    func show(over rect: CGRect, label: String?, behavior: NSWindow.CollectionBehavior) {
        guard !rect.isNull, rect.width > 1, rect.height > 1 else { return }
        model.label = label
        let panel = self.panel ?? makeWindow()
        panel.collectionBehavior = behavior
        if panel.frame != rect { panel.setFrame(rect, display: false) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    /// Takes the box down: the drag ended, left the panel, or the file landed.
    func hide() {
        model.targeted = false
        panel?.orderOut(nil)
    }

    private func makeWindow() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        // Just above the notch panel (DynamicNotchPanel is at .screenSaver), so a drag over the panel is offered
        // to this view and not to the panel's own window underneath it.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        let view = DropZoneHostView(model: model)
        view.onDrop = { [weak self] urls in self?.onDrop(urls) }
        view.onExit = { [weak self] in self?.hide() }
        panel.contentView = view
        self.panel = panel
        return panel
    }
}

/// What the box shows: the session the file will go to, and whether the pointer is over it right now.
@MainActor
@Observable
final class DropZoneModel {
    var label: String?
    var targeted = false
}

/// The AppKit drag destination. It fills the panel, registers for file URLs and implements the dragging methods
/// itself; a SwiftUI overlay (`DropZoneBox`) draws the box over it. Only the container is a drag destination, so
/// the hosting view's own (empty) registration never competes for the drag.
final class DropZoneHostView: NSView {
    var onDrop: ([URL]) -> Void = { _ in }
    var onExit: () -> Void = {}
    private let model: DropZoneModel
    private let host: NSHostingView<DropZoneBox>

    init(model: DropZoneModel) {
        self.model = model
        self.host = NSHostingView(rootView: DropZoneBox(model: model))
        super.init(frame: .zero)
        // A borderless non-opaque window routes a drag through its transparent pixels to the window below, so the
        // registered view is never offered the file. A faint full-bounds backing gives the whole frame content for
        // the WindowServer to route to; it reads as a slight dim over the panel while a file is in hand, no more.
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.12).cgColor
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.topAnchor.constraint(equalTo: topAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        // The overlay must not be a drag destination of its own (it has no onDrop), or it would shadow this
        // container, which is the one registered to receive the file.
        host.unregisterDraggedTypes()
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// The SwiftUI overlay draws the box but must never be the view a drag resolves to: it is not registered for
    /// the file type, so a drag landing on it would find no destination. Hit-testing always returns this
    /// container, which is the registered destination, so the drag is offered to it and the overlay stays visual.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = superview?.convert(point, to: self) ?? point
        return bounds.contains(local) ? self : nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        MainActor.assumeIsolated { model.targeted = true }
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        MainActor.assumeIsolated { model.targeted = false; onExit() }
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                         options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return false }
        MainActor.assumeIsolated { model.targeted = false; onDrop(files) }
        return true
    }
}

/// The box the reader sees: a rounded, dashed outline over the panel, brighter while the pointer is on it, with a
/// line that names where the file will land. Drawn on the dark panel, so its ink is the panel's own.
struct DropZoneBox: View {
    @Bindable var model: DropZoneModel

    private var line: String {
        if let label = model.label, !label.isEmpty { return L("Drop to hand it to %@", label) }
        return L("Drop a file here")
    }

    var body: some View {
        let accent = Palette.calm
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(model.targeted ? AnyShapeStyle(accent.opacity(0.12)) : AnyShapeStyle(.clear))
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                .foregroundStyle(model.targeted ? AnyShapeStyle(accent) : AnyShapeStyle(.white.opacity(0.55)))
            VStack(spacing: 8) {
                Image(systemName: "arrow.down.doc")
                    .font(.system(size: 26, weight: .regular))
                    .foregroundStyle(model.targeted ? AnyShapeStyle(accent) : AnyShapeStyle(.white.opacity(0.8)))
                Text(line)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.horizontal, 12)
            }
        }
        .padding(8)
        .animation(.easeOut(duration: 0.12), value: model.targeted)
        .environment(\.colorScheme, .dark)
    }
}
