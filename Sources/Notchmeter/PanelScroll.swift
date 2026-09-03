import AppKit

/// Where the open panel is scrolled to, as a reading rather than something only the eye can check. The panel is a
/// readout and not a document, so every opening starts at the Cost card with its title clear of the notch
/// (NotchExpandedView's scroll anchor); this is that position, for `--smoke` and for the oracle's snapshot.
struct PanelScroll: Equatable {
    /// `documentVisibleRect.minY`, negative by the room the content is held below the top of the window. Where an
    /// opening lands is SwiftUI's to decide, so it is compared against another reading rather than against a
    /// number assumed here: AppKit's own clamp is 8 pt further up than the panel ever rests.
    var offset: CGFloat
    /// The scroll view's top content inset, which under the notch is the hardware's own height.
    var insetTop: CGFloat
    var contentHeight: CGFloat
    var visibleHeight: CGFloat
    /// The top edge of the scrolled content in screen points, measured.
    var contentTopOnScreen: CGFloat?
    /// The top of the first card's title: the measured content top, less the room above it (the content's own top
    /// padding and the card's). This is what has to stay below the notch; the card's corner may touch it.
    var titleTopOnScreen: CGFloat?
    /// The bottom edge of the shape the panel hangs under; nil on the layouts with nothing over them.
    var notchBottom: CGFloat?

    /// Half a point of layout rounding, for the edges.
    static let tolerance: CGFloat = 0.5
    /// How far apart two openings may land and still count as the same place. Openings measured across runs and
    /// layouts spread over about 6 pt, which is the panel's own settling; a panel that kept where the last look
    /// left it is out by a card at least, and by a couple of hundred points after a real scroll.
    static let restTolerance: CGFloat = 12

    init(offset: CGFloat, insetTop: CGFloat, contentHeight: CGFloat, visibleHeight: CGFloat,
         contentTopOnScreen: CGFloat?, titleInset: CGFloat, notchBottom: CGFloat?) {
        self.offset = offset
        self.insetTop = insetTop
        self.contentHeight = contentHeight
        self.visibleHeight = visibleHeight
        self.contentTopOnScreen = contentTopOnScreen
        self.titleTopOnScreen = contentTopOnScreen.map { $0 - titleInset }
        self.notchBottom = notchBottom
    }

    var overflows: Bool { contentHeight > visibleHeight + Self.tolerance }

    /// The same scrolled position as another reading, within that rounding.
    func isAt(_ other: PanelScroll) -> Bool { abs(offset - other.offset) <= Self.restTolerance }

    /// The first card's title below the bottom of the notch. Nil where nothing is over the panel.
    var clearsNotch: Bool? {
        guard let titleTopOnScreen, let notchBottom else { return nil }
        return titleTopOnScreen <= notchBottom + Self.tolerance
    }

    var text: String {
        var parts = ["offset=\(rounded(offset))", "inset=\(rounded(insetTop))",
                     "content=\(rounded(contentHeight)) visible=\(rounded(visibleHeight)) scrollable=\(overflows)"]
        if let titleTopOnScreen, let notchBottom {
            parts.append("title top=\(rounded(titleTopOnScreen)) notch bottom=\(rounded(notchBottom)) → clear=\(clearsNotch == true)")
        }
        return parts.joined(separator: " ")
    }

    var fields: [String: Any] {
        ["offset": offset, "insetTop": insetTop, "contentHeight": contentHeight, "visibleHeight": visibleHeight,
         "scrollable": overflows, "contentTopOnScreen": contentTopOnScreen as Any, "titleTopOnScreen": titleTopOnScreen as Any,
         "notchBottom": notchBottom as Any, "clearsNotch": clearsNotch as Any]
    }

    private func rounded(_ value: CGFloat) -> String { String(format: "%.1f", value) }
}

/// Reads the panel's own scroll view, and drives it for the self check. SwiftUI's ScrollView is an NSScrollView in
/// the window the panel is drawn in, and the expanded content is only in that window while the panel is open, so
/// every read is nil while it is closed.
@MainActor
struct PanelScrollReader {
    let window: NSWindow?
    /// The shape the panel hangs under, on the layouts that have one.
    let notch: CGRect?
    /// The room between the top of the content and the first card's title.
    let titleInset: CGFloat

    func read() -> PanelScroll? {
        guard let window, let scroll = scrollView, let document = scroll.documentView else { return nil }
        let visible = scroll.documentVisibleRect
        // A flipped document (SwiftUI's) draws its first line at bounds.minY, an unflipped one at bounds.maxY.
        let top = document.isFlipped ? document.bounds.minY : document.bounds.maxY
        let inWindow = document.convert(NSPoint(x: document.bounds.minX, y: top), to: nil)
        return PanelScroll(offset: visible.minY, insetTop: scroll.contentInsets.top,
                           contentHeight: document.frame.height, visibleHeight: visible.height,
                           contentTopOnScreen: window.convertPoint(toScreen: inWindow).y,
                           titleInset: titleInset, notchBottom: notch?.minY)
    }

    /// Scrolls down the way a look through the cards would: a wheel event through the scroll view's own handler,
    /// rather than the clip view moved behind its back, so SwiftUI sees the same scroll a trackpad would give it.
    /// Reads where that left the panel.
    @discardableResult
    func scrollDown(by points: CGFloat) -> PanelScroll? {
        guard let scroll = scrollView,
              let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                  wheel1: Int32(clamping: Int(-points.rounded())), wheel2: 0, wheel3: 0),
              let event = NSEvent(cgEvent: wheel) else { return nil }
        scroll.scrollWheel(with: event)
        return read()
    }

    /// The class names down to the deepest view, for a run that found no scroll view to read.
    var hierarchy: String { Self.hierarchy(of: window?.contentView) }

    private var scrollView: NSScrollView? { Self.scrollView(in: window?.contentView) }

    static func scrollView(in view: NSView?) -> NSScrollView? {
        guard let view else { return nil }
        if let scroll = view as? NSScrollView { return scroll }
        for subview in view.subviews {
            if let found = scrollView(in: subview) { return found }
        }
        return nil
    }

    static func hierarchy(of view: NSView?, depth: Int = 0) -> String {
        guard let view, depth < 12 else { return "" }
        let name = String(describing: type(of: view))
        let children = view.subviews.map { hierarchy(of: $0, depth: depth + 1) }.filter { !$0.isEmpty }
        return children.isEmpty ? name : "\(name)(\(children.joined(separator: ", ")))"
    }
}
