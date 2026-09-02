import AppKit

/// An optional status item: the Options menu one click away (Quit, Settings, Open panel) for VoiceOver's VO-M-M
/// and for a Mac whose panel cannot be shown beside a notch, with an optional pin of the chosen tools' two ring
/// figures, as text ("14% · 4%") or as a glyph of up to four mini bars. Off by default on a notched Mac, because
/// taking no menu bar space is the point.
@MainActor
final class MenuBarItem {
    private let item: NSStatusItem
    private let menu: OptionsMenu
    private let store: UsageStore
    private let prefs: Preferences

    init(store: UsageStore, prefs: Preferences, actions: NotchActions) {
        self.store = store
        self.prefs = prefs
        menu = OptionsMenu(prefs: prefs, actions: actions, includesOpenPanel: true)
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = Self.icon()
            button.imagePosition = .imageLeading
            button.setAccessibilityLabel(AppInfo.name)
        }
        item.menu = menu.build()
        update()
        observe()
    }

    func remove() {
        NSStatusBar.system.removeStatusItem(item)
    }

    private static func icon() -> NSImage? {
        let image = NSImage(systemSymbolName: "gauge.with.dots.needle.33percent", accessibilityDescription: AppInfo.name)
        image?.isTemplate = true
        return image
    }

    /// The pinned tools, in the user's order: the chosen set when any of them is visible, else the first visible tool.
    nonisolated static func pinnedTools(visible: [ToolID], chosen: Set<ToolID>) -> [ToolID] {
        let picked = visible.filter(chosen.contains)
        return picked.isEmpty ? Array(visible.prefix(1)) : picked
    }

    /// "14% · 4% | 61% · 12%": each pinned tool's two figures, tools separated by a bar.
    nonisolated static func label(readings: [(windows: [LimitWindow], display: UsageDisplay)], countdown: Bool, now: Date = Date()) -> String {
        readings.map { CompactLabel.text(for: $0.windows, display: $0.display, countdown: countdown, now: now) }.joined(separator: " | ")
    }

    /// The pin: hidden while the screen is shared.
    func update(captured: Bool = false) {
        item.menu = menu.build()
        guard let button = item.button else { return }
        guard prefs.menuBarPin, !captured else {
            button.title = ""
            button.image = Self.icon()
            return
        }
        let tools = Self.pinnedTools(visible: store.visibleTools, chosen: prefs.menuBarPinnedTools)
        let readings = tools.compactMap { tool -> (windows: [LimitWindow], display: UsageDisplay)? in
            guard let reading = store.status(tool).reading else { return nil }
            return (prefs.ringWindows(of: reading), prefs.usageDisplay)
        }
        guard !readings.isEmpty else {
            button.title = ""
            button.image = Self.icon()
            return
        }
        switch prefs.menuBarStyle {
        case .text:
            button.image = Self.icon()
            button.title = " " + Self.label(readings: readings, countdown: prefs.showResetCountdown)
            button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize(for: .small), weight: .medium)
        case .bars:
            button.title = ""
            button.image = MenuBarBars.image(windows: Array(readings.flatMap(\.windows).prefix(4)))
        }
        button.setAccessibilityValue(Self.label(readings: readings, countdown: prefs.showResetCountdown))
    }

    private func observe() {
        withObservationTracking {
            _ = (store.statuses, prefs.menuBarPin, prefs.menuBarPinnedTools, prefs.menuBarStyle, prefs.usageDisplay, prefs.toolOrder, prefs.ringWindows,
                 prefs.showResetCountdown, prefs.hiddenWindows, prefs.revealedWindows)
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.update()
                self?.observe()
            }
        }
    }
}

/// Up to four mini bars in an 18 pt glyph: a template image (so it follows the menu bar's appearance) while every
/// bar is on pace, and a colour-carrying one (orange for on track, vermillion for behind) when one is not, the
/// same rule the rings use.
enum MenuBarBars {
    static let size = NSSize(width: 22, height: 16)

    static func image(windows: [LimitWindow], now: Date = Date()) -> NSImage {
        let paces = windows.map { Pace.status(for: $0, now: now) }
        let tinted = paces.contains { $0 == .onTrack || $0 == .behind }
        let image = NSImage(size: size, flipped: false) { rect in
            let count = max(1, windows.count)
            let gap: CGFloat = 2
            let width = (rect.width - gap * CGFloat(count - 1)) / CGFloat(count)
            for (index, window) in windows.enumerated() {
                let x = CGFloat(index) * (width + gap)
                let track = NSBezierPath(roundedRect: NSRect(x: x, y: 1, width: width, height: rect.height - 2), xRadius: 1.5, yRadius: 1.5)
                NSColor.black.withAlphaComponent(0.25).setFill()
                track.fill()
                let fraction = CGFloat(min(1, max(0.06, window.usedFraction ?? 0)))
                let fill = NSBezierPath(roundedRect: NSRect(x: x, y: 1, width: width, height: (rect.height - 2) * fraction), xRadius: 1.5, yRadius: 1.5)
                switch paces[index] {
                case .behind: NSColor(red: 0.84, green: 0.37, blue: 0, alpha: 1).setFill()
                case .onTrack: NSColor(red: 0.9, green: 0.62, blue: 0, alpha: 1).setFill()
                default: NSColor.black.setFill()
                }
                fill.fill()
            }
            return true
        }
        image.isTemplate = !tinted
        image.accessibilityDescription = AppInfo.name
        return image
    }
}
