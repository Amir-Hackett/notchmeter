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
        update(captured: store.hidesFigures)
        observe()
    }

    func remove() {
        NSStatusBar.system.removeStatusItem(item)
    }

    /// The status item's own glyph, and the one place the pin says what an assistant is asking of the user: a
    /// raised hand while one waits, a tick while one has just finished, the gauge otherwise. A symbol rather than a
    /// colour, because the image stays a template and so keeps following the menu bar's own appearance, and because
    /// an icon that changed colour for ninety seconds would look like a fault rather than a message. The `bars`
    /// style replaces this image with the meters' glyph, which fills its 22 × 16 edge to edge and has no room for a
    /// second claim; there the tooltip and the VoiceOver value carry it.
    private static func icon(signal: ToolSignal? = nil) -> NSImage? {
        let image = NSImage(systemSymbolName: signal?.symbolName ?? "gauge.with.dots.needle.33percent",
                            accessibilityDescription: signal?.spokenText ?? AppInfo.name)
        image?.isTemplate = true
        return image
    }

    /// The pinned tools, in the user's order: the chosen set when any of them is visible, else the first visible tool.
    nonisolated static func pinnedTools(visible: [ToolID], chosen: Set<ToolID>) -> [ToolID] {
        let picked = visible.filter(chosen.contains)
        return picked.isEmpty ? Array(visible.prefix(1)) : picked
    }

    /// The tools the glyph is allowed to speak for, which is not the same set the figures are drawn from.
    ///
    /// With the pin on, the user named the assistants the menu bar reports and the glyph rides beside their
    /// figures. With the pin off there is no such choice to honour — and `pinnedTools`' fallback to the first
    /// visible tool is a device for having something to measure, not a preference anyone expressed. Reading the
    /// signal from that fallback made the glyph report whichever assistant happened to sit first in the Assistants
    /// order: on a Mac with no notch the menu bar item is on by default and the pin is off by default, so dragging
    /// Codex above Claude left the rings beside the notch lighting up while the glyph stayed a gauge and
    /// VoiceOver's value stayed empty. That is the one surface a screen-reader user has, and it was silent in the
    /// shipping default for every order but one.
    nonisolated static func signallingTools(visible: [ToolID], pinned: Bool, chosen: Set<ToolID>) -> [ToolID] {
        pinned ? pinnedTools(visible: visible, chosen: chosen) : visible
    }

    /// "14% · 4% | 61% · 12%": each pinned tool's two figures, tools separated by a bar.
    nonisolated static func label(readings: [(windows: [LimitWindow], display: UsageDisplay)], countdown: Bool, now: Date = Date()) -> String {
        readings.map { CompactLabel.text(for: $0.windows, display: $0.display, countdown: countdown, now: now) }.joined(separator: " | ")
    }

    /// The pin: hidden while the screen is shared, and so is the signal. The privacy setting's whole promise is
    /// that the menu bar stops telling the room about this Mac, and "someone is waiting on you" is a thing about
    /// this Mac; the rings beside the notch keep their own mark through a capture, as they always have, because
    /// the mark carries no figure.
    ///
    /// `captured` has no default any more. It had one, and `observe`'s callback took it — so every hook event and
    /// every thirty-second sweep repainted the figures, the glyph and the tooltip over a capture that had already
    /// hidden them, several times a minute while an assistant worked. There is one answer to this question in the
    /// app and every caller now has to say it out loud.
    ///
    /// Every branch below sets the accessibility value, including the two that return early, and sets it even when
    /// there is nothing to say so that a later pass clears what an earlier one left. The two early returns are the
    /// default configuration — the pin is off on a notched Mac — and they used to set only the image and the
    /// tooltip: `init`'s `setAccessibilityLabel` overrides the description the symbol carries, so a sighted reader
    /// saw a raised hand or a tick and VoiceOver read "Notchmeter" and stopped. That is the one surface where the
    /// state rested on something a screen reader could not reach, against both the "five surfaces read one answer"
    /// promise and this repo's rule that shape and colour are never a state's only carriers.
    func update(captured: Bool) {
        // Not while the user is in the menu: `build()` returns a new NSMenu every call, and assigning one while
        // AppKit is tracking the old one closes it and its open submenu under the pointer. The menu the user is
        // holding open cannot have gone stale in the seconds they have had it, and it is rebuilt on the next
        // change after they let it go.
        if !menu.isOpen { item.menu = menu.build() }
        guard let button = item.button else { return }
        let tools = Self.pinnedTools(visible: store.visibleTools, chosen: prefs.menuBarPinnedTools)
        // Found before the pin guard on purpose, and over its own set of tools: the state is not a usage figure, so
        // the pin being off has nothing to withhold. It says an assistant wants an answer, not what anything cost.
        let signalled = captured ? nil : store.strongestSignal(
            among: Self.signallingTools(visible: store.visibleTools, pinned: prefs.menuBarPin, chosen: prefs.menuBarPinnedTools))
        let signalLine = signalled.map { Self.signalTooltip(tool: $0.tool, signal: $0.signal) }
        guard prefs.menuBarPin, !captured else {
            button.title = ""
            button.image = Self.icon(signal: signalled?.signal)
            button.toolTip = signalLine ?? AppInfo.name
            button.setAccessibilityValue(signalled?.signal.spokenText)
            return
        }
        let readings = tools.compactMap { tool -> (windows: [LimitWindow], display: UsageDisplay)? in
            guard let reading = store.status(tool).reading else { return nil }
            return (prefs.ringWindows(of: reading), prefs.usageDisplay)
        }
        guard !readings.isEmpty else {
            button.title = ""
            button.image = Self.icon(signal: signalled?.signal)
            button.toolTip = signalLine ?? AppInfo.name
            button.setAccessibilityValue(signalled?.signal.spokenText)
            return
        }
        switch prefs.menuBarStyle {
        case .text:
            button.image = Self.icon(signal: signalled?.signal)
            button.title = " " + Self.label(readings: readings, countdown: prefs.showResetCountdown)
            button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize(for: .small), weight: .medium)
        case .bars:
            button.title = ""
            button.image = MenuBarBars.image(windows: Array(readings.flatMap(\.windows).prefix(4)))
        }
        button.setAccessibilityValue([signalled?.signal.spokenText, Self.label(readings: readings, countdown: prefs.showResetCountdown)]
            .compactMap { $0 }.joined(separator: ", "))
        button.toolTip = [signalLine, Self.tooltip(readings: readings, prefs: prefs)].compactMap { $0 }.joined(separator: "\n")
    }

    private func observe() {
        withObservationTracking {
            // `store.sessions` and nothing finer: without it the glyph would only change on the next reading,
            // which is minutes away. `store.attendedAt` is tracked alongside it because a look at the rings
            // releases a finish and nothing else publishes when it does: without it this item kept the tick and
            // the "finished a 12m turn" tooltip for the rest of the ninety-second hold, while the ring the user
            // had just looked at was already plain. Five surfaces read one answer, and one of them lagging the
            // others by a minute and a half is the contradiction that promise exists to rule out. `attendedAt`
            // costs at most one extra pass per turn — `wakeFromIdle` writes the date only while a finish is
            // actually lit — but `store.sessions` costs two a minute whatever happens: `UsageStore`'s thirty-second
            // sweep calls `sessions.expire` unconditionally, and a mutating call through `@Observable` publishes
            // whether or not it changed anything. That is a rebuilt NSMenu twice a minute, which the `isOpen` guard
            // above keeps off the menu the user is holding open and which is otherwise cheap; naming it here so the
            // next person weighing a finer-grained key knows what the coarse one actually costs. `prefs.signalRings`
            // is deliberately absent: it decides whether the rings beside the notch take the state colour, and this
            // item's glyph carries the state whatever it says, so tracking it bought a repaint and a rebuilt NSMenu
            // every time the toggle moved and changed nothing here.
            _ = (store.statuses, store.sessions, store.attendedAt, prefs.menuBarPin, prefs.menuBarPinnedTools, prefs.menuBarStyle,
                 prefs.usageDisplay, prefs.toolOrder,
                 prefs.ringWindows, prefs.showResetCountdown, prefs.hiddenWindows, prefs.revealedWindows)
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.update(captured: self.store.hidesFigures)
                self.observe()
            }
        }
    }
}

extension MenuBarItem {
    /// What hovering the icon says: every shown window in the reader's own settings — used or left, countdown or
    /// exact time — and, when a bar has taken colour, the reason it did, since the tint carries meaning the icon
    /// alone cannot explain.
    static func tooltip(readings: [(windows: [LimitWindow], display: UsageDisplay)], prefs: Preferences,
                        now: Date = Date()) -> String {
        var lines: [String] = []
        let windows = readings.flatMap(\.windows)
        for window in windows {
            let figure = prefs.usageLine(for: window) ?? "—"
            let reset = prefs.resetLine(for: window, now: now)
            lines.append(reset.isEmpty ? "\(window.label): \(figure)" : "\(window.label): \(figure) · \(reset)")
        }
        switch windows.map({ Pace.status(for: $0, now: now) }) {
        case let paces where paces.contains(.behind):
            lines.append(L("Coloured because a window is behind its pace."))
        case let paces where paces.contains(.onTrack):
            lines.append(L("Coloured because a window is close to its pace."))
        default:
            break
        }
        return lines.isEmpty ? AppInfo.name : lines.joined(separator: "\n")
    }

    /// The line above the figures while an assistant is asking something of the reader. The tooltip already exists
    /// to explain a tint the glyph cannot; a state makes that job twice as necessary, since the icon can say that
    /// something is being asked of you but not which assistant, or what it wants. It is also the only place the
    /// `bars` style can say it at all.
    static func signalTooltip(tool: ToolID, signal: ToolSignal) -> String {
        switch signal {
        case .waiting: L("%@ is waiting for your input.", tool.productName)
        case .finished(let turn): L("%1$@ finished a %2$@ turn.", tool.productName, ResetText.duration(turn))
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
