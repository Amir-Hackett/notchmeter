import AppKit

/// An optional status item: the Options menu one click away (Quit, Settings, Open panel) for VoiceOver's VO-M-M
/// and for a Mac whose panel cannot be shown beside a notch, with an optional two-figure pin of the first tool.
/// Off by default on a notched Mac, because taking no menu bar space is the point.
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
            let image = NSImage(systemSymbolName: "gauge.with.dots.needle.33percent", accessibilityDescription: AppInfo.name)
            image?.isTemplate = true
            button.image = image
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

    /// The pin: the first visible tool's two figures ("14% · 4%"), hidden while the screen is shared.
    func update(captured: Bool = false) {
        item.menu = menu.build()
        guard let button = item.button else { return }
        guard prefs.menuBarPin, !captured, let tool = store.visibleTools.first, let reading = store.status(tool).reading else {
            button.title = ""
            return
        }
        button.title = " " + CompactLabel.text(for: prefs.ringWindows(of: reading), display: prefs.usageDisplay, countdown: prefs.showResetCountdown)
        button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize(for: .small), weight: .medium)
    }

    private func observe() {
        withObservationTracking {
            _ = (store.statuses, prefs.menuBarPin, prefs.usageDisplay, prefs.toolOrder, prefs.ringWindows, prefs.showResetCountdown)
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.update()
                self?.observe()
            }
        }
    }
}
