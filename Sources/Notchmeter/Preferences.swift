import Foundation
import Observation
import ServiceManagement

enum NotchVisibility: String, CaseIterable, Codable {
    case onHover, onClick, always, hideWhenIdle

    var title: String {
        switch self {
        case .onHover: L("Open on hover")
        case .onClick: L("Open on click")
        case .always: L("Always open")
        case .hideWhenIdle: L("Hide when idle")
        }
    }
}

/// Where the panel lives. Top merges with the physical notch; the others are Codenotch-style edge pills.
enum PanelEdge: String, CaseIterable, Codable {
    case top, left, right, bottom

    var title: String {
        switch self {
        case .top: L("Top, in the notch")
        case .left: L("Left edge")
        case .right: L("Right edge")
        case .bottom: L("Bottom, above the Dock")
        }
    }

    var detail: String {
        switch self {
        case .top: L("Readings sit beside the notch and open below it.")
        case .left: L("A pill down the left-hand edge, clear of a Dock on that side.")
        case .right: L("A pill down the right-hand edge, clear of a Dock on that side.")
        case .bottom: L("A bar resting on top of the Dock.")
        }
    }

    /// The Settings and Options label for the compact readout: rings beside the notch, or inside an edge pill.
    var compactStyleTitle: String {
        self == .top ? L("Beside the notch") : L("In the pill")
    }
}

/// What each tool shows while the panel is closed: its rings, the rings with its percentages, or the digits alone.
enum CompactStyle: String, CaseIterable, Codable {
    case rings, ringsAndNumbers, numbers

    var title: String {
        switch self {
        case .rings: L("Rings")
        case .ringsAndNumbers: L("Rings + numbers")
        case .numbers: L("Numbers")
        }
    }

    var showsRings: Bool { self != .numbers }
    var showsNumbers: Bool { self != .rings }
}

/// Which display carries the panel: the built-in one with the notch, the main (menu bar) display, the one under the
/// pointer, every display at once, or one named by macOS ("DELL U2723QE").
enum DisplayChoice: Hashable, Codable {
    case builtIn, main, pointer, all, named(String)

    static let fixed: [DisplayChoice] = [.builtIn, .main, .pointer, .all]

    var title: String {
        switch self {
        case .builtIn: L("Built-in display")
        case .main: L("Main display")
        case .pointer: L("Display with the pointer")
        case .all: L("All displays")
        case .named(let name): name
        }
    }

    var rawValue: String {
        switch self {
        case .builtIn: "builtIn"
        case .main: "main"
        case .pointer: "pointer"
        case .all: "all"
        case .named(let name): "named:\(name)"
        }
    }

    init?(rawValue: String) {
        switch rawValue {
        case "builtIn": self = .builtIn
        case "main": self = .main
        case "pointer": self = .pointer
        case "all": self = .all
        default:
            guard rawValue.hasPrefix("named:"), rawValue.count > 6 else { return nil }
            self = .named(String(rawValue.dropFirst(6)))
        }
    }
}

/// How much room the open panel gives each card.
enum Density: String, CaseIterable, Codable {
    case comfortable, compact

    var title: String {
        switch self {
        case .comfortable: L("Comfortable")
        case .compact: L("Compact")
        }
    }

    var cardPadding: CGFloat { self == .compact ? 9 : 12 }
    var meterSpacing: CGFloat { self == .compact ? 8 : 12 }
    var costRing: CGFloat { self == .compact ? 72 : 92 }
    var cardSpacing: CGFloat { self == .compact ? 7 : 10 }
}

enum PanelWidth: String, CaseIterable, Codable {
    case standard, wide

    var title: String {
        switch self {
        case .standard: L("Standard")
        case .wide: L("Wide")
        }
    }

    var points: CGFloat { self == .wide ? 460 : 380 }
}

/// A key combination for a global shortcut: a Carbon virtual key code and Carbon modifier flags.
struct Hotkey: Equatable, Codable, Sendable {
    let keyCode: UInt32
    let modifiers: UInt32

    static let commandKey: UInt32 = 1 << 8
    static let shiftKey: UInt32 = 1 << 9
    static let optionKey: UInt32 = 1 << 11
    static let controlKey: UInt32 = 1 << 12

    /// "⌃⌥⇧⌘N" in the order the menu bar draws them.
    var description: String {
        var text = ""
        if modifiers & Self.controlKey != 0 { text += "⌃" }
        if modifiers & Self.optionKey != 0 { text += "⌥" }
        if modifiers & Self.shiftKey != 0 { text += "⇧" }
        if modifiers & Self.commandKey != 0 { text += "⌘" }
        return text + KeyNames.name(for: keyCode)
    }
}

/// The reminder before a window resets: off, ten minutes or an hour ahead.
enum ResetReminder: String, CaseIterable, Codable {
    case off, tenMinutes, oneHour

    var title: String {
        switch self {
        case .off: L("Off")
        case .tenMinutes: L("10 minutes before")
        case .oneHour: L("1 hour before")
        }
    }

    var lead: TimeInterval? {
        switch self {
        case .off: nil
        case .tenMinutes: 600
        case .oneHour: 3600
        }
    }
}

enum ToolOrder {
    /// A stored order with names that are no tool dropped, repeats removed, and every tool it leaves out appended
    /// in default order, so a tool added in a later version appears without a reset.
    static func normalize(_ stored: [String]?) -> [ToolID] {
        var order: [ToolID] = []
        for name in stored ?? [] {
            if let tool = ToolID(rawValue: name), !order.contains(tool) { order.append(tool) }
        }
        order.append(contentsOf: ToolID.allCases.filter { !order.contains($0) })
        return order
    }
}

@MainActor
@Observable
final class Preferences {
    @ObservationIgnored private let defaults: UserDefaults

    var enabledTools: Set<ToolID> {
        didSet {
            defaults.set(enabledTools.map(\.rawValue).sorted(), forKey: Keys.enabledTools)
            report(Keys.enabledTools, enabledTools.map(\.rawValue).sorted(), changed: enabledTools != oldValue)
        }
    }
    /// The assistants' order everywhere: the panel's cards, the rings beside the notch (the first on its left, the
    /// rest on its right), the edge pills, and the Advisor's tie-breaks.
    var toolOrder: [ToolID] {
        didSet {
            defaults.set(toolOrder.map(\.rawValue), forKey: Keys.toolOrder)
            report("toolOrder", toolOrder.map(\.rawValue), changed: toolOrder != oldValue, event: "order")
        }
    }
    var visibility: NotchVisibility {
        didSet { defaults.set(visibility.rawValue, forKey: Keys.visibility); report(Keys.visibility, visibility.rawValue, changed: visibility != oldValue) }
    }
    /// How long the pointer rests on the rings before the panel opens, 0.1 to 1 s.
    var hoverDelay: TimeInterval {
        didSet {
            hoverDelay = min(1, max(0.1, (hoverDelay * 20).rounded() / 20))
            defaults.set(hoverDelay, forKey: Keys.hoverDelay)
            report(Keys.hoverDelay, hoverDelay, changed: hoverDelay != oldValue)
        }
    }
    var edge: PanelEdge {
        didSet { defaults.set(edge.rawValue, forKey: Keys.edge); report("edge", edge.rawValue, changed: edge != oldValue, event: "layout") }
    }
    var display: DisplayChoice {
        didSet { defaults.set(display.rawValue, forKey: Keys.display); report(Keys.display, display.rawValue, changed: display != oldValue) }
    }
    var showOverFullScreenApps: Bool {
        didSet { defaults.set(showOverFullScreenApps, forKey: Keys.fullScreen); report(Keys.fullScreen, showOverFullScreenApps, changed: showOverFullScreenApps != oldValue) }
    }
    var compactStyle: CompactStyle {
        didSet {
            defaults.set(compactStyle.rawValue, forKey: Keys.compactStyle)
            report("compactStyle", compactStyle.rawValue, changed: compactStyle != oldValue, event: "compactStyle")
        }
    }
    /// "90% · 32m": the main window's reset countdown after its figure, in the styles that show numbers.
    var showResetCountdown: Bool {
        didSet { defaults.set(showResetCountdown, forKey: Keys.resetCountdown); report(Keys.resetCountdown, showResetCountdown, changed: showResetCountdown != oldValue) }
    }
    var showSpend: Bool {
        didSet { defaults.set(showSpend, forKey: Keys.showSpend); report(Keys.showSpend, showSpend, changed: showSpend != oldValue) }
    }
    var usageDisplay: UsageDisplay {
        didSet { defaults.set(usageDisplay.rawValue, forKey: Keys.usageDisplay); report(Keys.usageDisplay, usageDisplay.rawValue, changed: usageDisplay != oldValue) }
    }
    var resetDisplay: ResetDisplay {
        didSet { defaults.set(resetDisplay.rawValue, forKey: Keys.resetDisplay); report(Keys.resetDisplay, resetDisplay.rawValue, changed: resetDisplay != oldValue) }
    }
    var timeFormat: TimeFormatPreference {
        didSet { defaults.set(timeFormat.rawValue, forKey: Keys.timeFormat); report(Keys.timeFormat, timeFormat.rawValue, changed: timeFormat != oldValue) }
    }
    var density: Density {
        didSet { defaults.set(density.rawValue, forKey: Keys.density); report(Keys.density, density.rawValue, changed: density != oldValue) }
    }
    var panelWidth: PanelWidth {
        didSet { defaults.set(panelWidth.rawValue, forKey: Keys.panelWidth); report(Keys.panelWidth, panelWidth.rawValue, changed: panelWidth != oldValue) }
    }
    /// Swipe down over the rings opens, swipe up over the panel closes, with a haptic tick on each transition.
    var gesturesEnabled: Bool {
        didSet { defaults.set(gesturesEnabled, forKey: Keys.gestures); report(Keys.gestures, gesturesEnabled, changed: gesturesEnabled != oldValue) }
    }
    /// OR-ed with the system's Reduce Motion wherever motion is decided.
    var reduceAnimations: Bool {
        didSet { defaults.set(reduceAnimations, forKey: Keys.reduceAnimations); report(Keys.reduceAnimations, reduceAnimations, changed: reduceAnimations != oldValue) }
    }
    /// Nil follows the default: off on a Mac whose panel can be shown beside a notch, on when it cannot.
    var showMenuBarItem: Bool? {
        didSet {
            if let showMenuBarItem { defaults.set(showMenuBarItem, forKey: Keys.menuBarItem) } else { defaults.removeObject(forKey: Keys.menuBarItem) }
            report(Keys.menuBarItem, showMenuBarItem as Any, changed: showMenuBarItem != oldValue)
        }
    }
    /// The two main figures of the first tool beside the menu bar icon.
    var menuBarPin: Bool {
        didSet { defaults.set(menuBarPin, forKey: Keys.menuBarPin); report(Keys.menuBarPin, menuBarPin, changed: menuBarPin != oldValue) }
    }
    /// While the screen is captured, the rings lose their digits and the panel its Cost card.
    var hideFromScreenShare: Bool {
        didSet { defaults.set(hideFromScreenShare, forKey: Keys.screenShare); report(Keys.screenShare, hideFromScreenShare, changed: hideFromScreenShare != oldValue) }
    }
    /// ISO 4217 code and the user's own rate from a dollar; nothing is fetched.
    var currencyCode: String {
        didSet { defaults.set(currencyCode, forKey: Keys.currencyCode); report(Keys.currencyCode, currencyCode, changed: currencyCode != oldValue); Money.configure(code: currencyCode, rate: currencyRate) }
    }
    var currencyRate: Double {
        didSet { defaults.set(currencyRate, forKey: Keys.currencyRate); report(Keys.currencyRate, currencyRate, changed: currencyRate != oldValue); Money.configure(code: currencyCode, rate: currencyRate) }
    }
    /// Per tool, the ids of the windows the outer and inner rings show; empty means the reading's first two.
    var ringWindows: [ToolID: [String]] {
        didSet {
            defaults.set(ringWindows.reduce(into: [String: [String]]()) { $0[$1.key.rawValue] = $1.value }, forKey: Keys.ringWindows)
            report(Keys.ringWindows, ringWindows.map { "\($0.key.rawValue):\($0.value.joined(separator: ","))" }.sorted(), changed: ringWindows != oldValue)
        }
    }
    /// Per tool, the window ids left out of the card and the rings.
    var hiddenWindows: [ToolID: Set<String>] {
        didSet {
            defaults.set(hiddenWindows.reduce(into: [String: [String]]()) { $0[$1.key.rawValue] = $1.value.sorted() }, forKey: Keys.hiddenWindows)
            report(Keys.hiddenWindows, hiddenWindows.map { "\($0.key.rawValue):\($0.value.sorted().joined(separator: ","))" }.sorted(), changed: hiddenWindows != oldValue)
        }
    }
    /// Pace-crossing notifications (NotificationScheduler.swift); on by default, asked for on first use.
    var notificationsEnabled: Bool {
        didSet {
            defaults.set(notificationsEnabled, forKey: Keys.notificationsEnabled)
            report(Keys.notificationsEnabled, notificationsEnabled, changed: notificationsEnabled != oldValue)
        }
    }
    var notifyOnTrack: Bool {
        didSet { defaults.set(notifyOnTrack, forKey: Keys.notifyOnTrack); report(Keys.notifyOnTrack, notifyOnTrack, changed: notifyOnTrack != oldValue) }
    }
    var notifyBehind: Bool {
        didSet { defaults.set(notifyBehind, forKey: Keys.notifyBehind); report(Keys.notifyBehind, notifyBehind, changed: notifyBehind != oldValue) }
    }
    var notifyRunningOut: Bool {
        didSet { defaults.set(notifyRunningOut, forKey: Keys.notifyRunningOut); report(Keys.notifyRunningOut, notifyRunningOut, changed: notifyRunningOut != oldValue) }
    }
    /// Once, when a window that was at least 80 % used or behind pace passes its reset.
    var notifyOnReset: Bool {
        didSet { defaults.set(notifyOnReset, forKey: Keys.notifyOnReset); report(Keys.notifyOnReset, notifyOnReset, changed: notifyOnReset != oldValue) }
    }
    var resetReminder: ResetReminder {
        didSet { defaults.set(resetReminder.rawValue, forKey: Keys.resetReminder); report(Keys.resetReminder, resetReminder.rawValue, changed: resetReminder != oldValue) }
    }
    var notifyWaiting: Bool {
        didSet { defaults.set(notifyWaiting, forKey: Keys.notifyWaiting); report(Keys.notifyWaiting, notifyWaiting, changed: notifyWaiting != oldValue) }
    }
    var notifyFinished: Bool {
        didSet { defaults.set(notifyFinished, forKey: Keys.notifyFinished); report(Keys.notifyFinished, notifyFinished, changed: notifyFinished != oldValue) }
    }
    /// A turn that ran at least this long is worth a notification when it finishes.
    var finishedAfterMinutes: Int {
        didSet {
            finishedAfterMinutes = min(60, max(1, finishedAfterMinutes))
            defaults.set(finishedAfterMinutes, forKey: Keys.finishedAfter)
            report(Keys.finishedAfter, finishedAfterMinutes, changed: finishedAfterMinutes != oldValue)
        }
    }
    var notificationSound: Bool {
        didSet { defaults.set(notificationSound, forKey: Keys.notificationSound); report(Keys.notificationSound, notificationSound, changed: notificationSound != oldValue) }
    }
    var quietHoursEnabled: Bool {
        didSet { defaults.set(quietHoursEnabled, forKey: Keys.quietHours); report(Keys.quietHours, quietHoursEnabled, changed: quietHoursEnabled != oldValue) }
    }
    /// Minutes after midnight, local time; a window that crosses midnight is fine (22:00 to 08:00).
    var quietHoursStart: Int {
        didSet { defaults.set(quietHoursStart, forKey: Keys.quietStart); report(Keys.quietStart, quietHoursStart, changed: quietHoursStart != oldValue) }
    }
    var quietHoursEnd: Int {
        didSet { defaults.set(quietHoursEnd, forKey: Keys.quietEnd); report(Keys.quietEnd, quietHoursEnd, changed: quietHoursEnd != oldValue) }
    }
    /// Folders beyond Claude Code's own config directory whose transcripts are priced (synced logs, other machines).
    var extraTranscriptRoots: [String] {
        didSet { defaults.set(extraTranscriptRoots, forKey: Keys.extraRoots); report(Keys.extraRoots, extraTranscriptRoots, changed: extraTranscriptRoots != oldValue) }
    }
    /// GET /v1/limits on 127.0.0.1 for scripts and widgets; off because it widens the surface of a local-only app.
    var localAPIEnabled: Bool {
        didSet { defaults.set(localAPIEnabled, forKey: Keys.localAPI); report(Keys.localAPI, localAPIEnabled, changed: localAPIEnabled != oldValue) }
    }
    /// A second Codex endpoint (rate-limit reset credits), opt-in under the one-request-per-token rule.
    var codexResetCredits: Bool {
        didSet { defaults.set(codexResetCredits, forKey: Keys.codexCredits); report(Keys.codexCredits, codexResetCredits, changed: codexResetCredits != oldValue) }
    }
    var togglePanelHotkey: Hotkey? {
        didSet { store(togglePanelHotkey, forKey: Keys.hotkeyToggle); report(Keys.hotkeyToggle, togglePanelHotkey?.description as Any, changed: togglePanelHotkey != oldValue) }
    }
    var openSettingsHotkey: Hotkey? {
        didSet { store(openSettingsHotkey, forKey: Keys.hotkeySettings); report(Keys.hotkeySettings, openSettingsHotkey?.description as Any, changed: openSettingsHotkey != oldValue) }
    }
    /// The one-time first-launch offer to install the Claude Code hook has been shown.
    var hookOfferShown: Bool {
        didSet { defaults.set(hookOfferShown, forKey: Keys.hookOffer); report(Keys.hookOffer, hookOfferShown, changed: hookOfferShown != oldValue) }
    }
    private(set) var launchAtLogin: Bool
    private(set) var launchAtLoginStatus: SMAppService.Status

    private enum Keys {
        static let enabledTools = "enabledTools"
        static let toolOrder = "toolOrder"
        static let visibility = "notchVisibility"
        static let hoverDelay = "hoverDelay"
        static let edge = "panelEdge"
        static let display = "display"
        static let fullScreen = "showOverFullScreenApps"
        static let compactStyle = "compactStyle"
        static let resetCountdown = "showResetCountdown"
        static let showSpend = "showSpend"
        static let usageDisplay = "usageDisplay"
        static let resetDisplay = "resetDisplay"
        static let timeFormat = "timeFormat"
        static let density = "density"
        static let panelWidth = "panelWidth"
        static let gestures = "gesturesEnabled"
        static let reduceAnimations = "reduceAnimations"
        static let menuBarItem = "showMenuBarItem"
        static let menuBarPin = "menuBarPin"
        static let screenShare = "hideFromScreenShare"
        static let currencyCode = "currencyCode"
        static let currencyRate = "currencyRate"
        static let ringWindows = "ringWindows"
        static let hiddenWindows = "hiddenWindows"
        static let notificationsEnabled = "notificationsEnabled"
        static let notifyOnTrack = "notifyOnTrack"
        static let notifyBehind = "notifyBehind"
        static let notifyRunningOut = "notifyRunningOut"
        static let notifyOnReset = "notifyOnReset"
        static let resetReminder = "resetReminder"
        static let notifyWaiting = "notifyWaiting"
        static let notifyFinished = "notifyFinished"
        static let finishedAfter = "finishedAfterMinutes"
        static let notificationSound = "notificationSound"
        static let quietHours = "quietHoursEnabled"
        static let quietStart = "quietHoursStart"
        static let quietEnd = "quietHoursEnd"
        static let extraRoots = "extraTranscriptRoots"
        static let localAPI = "localAPIEnabled"
        static let codexCredits = "codexResetCredits"
        static let hotkeyToggle = "hotkeyTogglePanel"
        static let hotkeySettings = "hotkeyOpenSettings"
        static let hookOffer = "hookOfferShown"
        static let launchAtLogin = "launchAtLogin"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let raw = defaults.array(forKey: Keys.enabledTools) as? [String] {
            enabledTools = Set(raw.compactMap(ToolID.init(rawValue:)))
        } else {
            enabledTools = Set(ToolID.allCases)
        }
        toolOrder = ToolOrder.normalize(defaults.array(forKey: Keys.toolOrder) as? [String])
        visibility = NotchVisibility(rawValue: defaults.string(forKey: Keys.visibility) ?? "") ?? .onHover
        hoverDelay = defaults.object(forKey: Keys.hoverDelay) as? Double ?? HoverIntent.expandDwell
        edge = PanelEdge(rawValue: defaults.string(forKey: Keys.edge) ?? "") ?? .top
        display = DisplayChoice(rawValue: defaults.string(forKey: Keys.display) ?? "") ?? .builtIn
        showOverFullScreenApps = defaults.object(forKey: Keys.fullScreen) as? Bool ?? true
        compactStyle = CompactStyle(rawValue: defaults.string(forKey: Keys.compactStyle) ?? "") ?? .rings
        showResetCountdown = defaults.bool(forKey: Keys.resetCountdown)
        showSpend = defaults.object(forKey: Keys.showSpend) as? Bool ?? true
        usageDisplay = UsageDisplay(rawValue: defaults.string(forKey: Keys.usageDisplay) ?? "") ?? .used
        resetDisplay = ResetDisplay(rawValue: defaults.string(forKey: Keys.resetDisplay) ?? "") ?? .exact
        timeFormat = TimeFormatPreference(rawValue: defaults.string(forKey: Keys.timeFormat) ?? "") ?? .auto
        density = Density(rawValue: defaults.string(forKey: Keys.density) ?? "") ?? .comfortable
        panelWidth = PanelWidth(rawValue: defaults.string(forKey: Keys.panelWidth) ?? "") ?? .standard
        gesturesEnabled = defaults.object(forKey: Keys.gestures) as? Bool ?? true
        reduceAnimations = defaults.bool(forKey: Keys.reduceAnimations)
        showMenuBarItem = defaults.object(forKey: Keys.menuBarItem) as? Bool
        menuBarPin = defaults.bool(forKey: Keys.menuBarPin)
        hideFromScreenShare = defaults.bool(forKey: Keys.screenShare)
        currencyCode = defaults.string(forKey: Keys.currencyCode) ?? "USD"
        currencyRate = defaults.object(forKey: Keys.currencyRate) as? Double ?? 1
        ringWindows = (defaults.dictionary(forKey: Keys.ringWindows) as? [String: [String]] ?? [:])
            .reduce(into: [:]) { if let tool = ToolID(rawValue: $1.key) { $0[tool] = $1.value } }
        hiddenWindows = (defaults.dictionary(forKey: Keys.hiddenWindows) as? [String: [String]] ?? [:])
            .reduce(into: [:]) { if let tool = ToolID(rawValue: $1.key) { $0[tool] = Set($1.value) } }
        notificationsEnabled = defaults.object(forKey: Keys.notificationsEnabled) as? Bool ?? true
        notifyOnTrack = defaults.object(forKey: Keys.notifyOnTrack) as? Bool ?? true
        notifyBehind = defaults.object(forKey: Keys.notifyBehind) as? Bool ?? true
        notifyRunningOut = defaults.object(forKey: Keys.notifyRunningOut) as? Bool ?? true
        notifyOnReset = defaults.object(forKey: Keys.notifyOnReset) as? Bool ?? true
        resetReminder = ResetReminder(rawValue: defaults.string(forKey: Keys.resetReminder) ?? "") ?? .off
        notifyWaiting = defaults.bool(forKey: Keys.notifyWaiting)
        notifyFinished = defaults.bool(forKey: Keys.notifyFinished)
        finishedAfterMinutes = defaults.object(forKey: Keys.finishedAfter) as? Int ?? 2
        notificationSound = defaults.object(forKey: Keys.notificationSound) as? Bool ?? true
        quietHoursEnabled = defaults.bool(forKey: Keys.quietHours)
        quietHoursStart = defaults.object(forKey: Keys.quietStart) as? Int ?? 22 * 60
        quietHoursEnd = defaults.object(forKey: Keys.quietEnd) as? Int ?? 8 * 60
        extraTranscriptRoots = defaults.stringArray(forKey: Keys.extraRoots) ?? []
        localAPIEnabled = defaults.bool(forKey: Keys.localAPI)
        codexResetCredits = defaults.bool(forKey: Keys.codexCredits)
        togglePanelHotkey = Self.hotkey(defaults, Keys.hotkeyToggle)
        openSettingsHotkey = Self.hotkey(defaults, Keys.hotkeySettings)
        hookOfferShown = defaults.bool(forKey: Keys.hookOffer)
        let status = SMAppService.mainApp.status
        launchAtLoginStatus = status
        launchAtLogin = status == .enabled
        Money.configure(code: currencyCode, rate: currencyRate)
    }

    private static func hotkey(_ defaults: UserDefaults, _ key: String) -> Hotkey? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Hotkey.self, from: data)
    }

    private func store(_ hotkey: Hotkey?, forKey key: String) {
        if let hotkey, let data = try? JSONEncoder().encode(hotkey) {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
        refreshLaunchAtLogin()
        report(Keys.launchAtLogin, launchAtLogin, changed: true)
    }

    /// Re-reads the login item's status: the user may have approved it in System Settings meanwhile.
    func refreshLaunchAtLogin() {
        let status = SMAppService.mainApp.status
        launchAtLoginStatus = status
        launchAtLogin = status == .enabled
    }

    /// Moves a tool one place up (-1) or down (+1); nothing happens at the ends.
    func move(_ tool: ToolID, by offset: Int) {
        guard let index = toolOrder.firstIndex(of: tool), toolOrder.indices.contains(index + offset) else { return }
        toolOrder.swapAt(index, index + offset)
    }

    func isHidden(_ window: LimitWindow, of tool: ToolID) -> Bool {
        hiddenWindows[tool]?.contains(window.id) ?? false
    }

    func setHidden(_ hidden: Bool, window id: String, of tool: ToolID) {
        var set = hiddenWindows[tool] ?? []
        if hidden { set.insert(id) } else { set.remove(id) }
        hiddenWindows[tool] = set.isEmpty ? nil : set
    }

    /// The reading's windows in the order the card shows them, hidden ones left out.
    func shownWindows(of reading: UsageReading) -> [LimitWindow] {
        reading.windows.filter { !isHidden($0, of: reading.tool) }
    }

    /// The two windows the rings show: the chosen ids when they exist in the reading, else the first two shown.
    func ringWindows(of reading: UsageReading) -> [LimitWindow] {
        RingSelection.windows(of: reading, chosen: ringWindows[reading.tool] ?? [], hidden: hiddenWindows[reading.tool] ?? [])
    }

    func resetLine(for window: LimitWindow, stale: Bool = false, now: Date = Date()) -> String {
        ResetText.line(resetsAt: window.resetsAt, hasLimit: window.usedFraction != nil, display: resetDisplay, timeFormat: timeFormat,
                       stale: stale, now: now)
    }

    func usageLine(for window: LimitWindow) -> String? {
        guard let used = window.usedFraction else { return nil }
        switch usageDisplay {
        case .used: return L("%ld%% used", Int((used * 100).rounded()))
        case .left: return L("%ld%% left", Int(((1 - used) * 100).rounded()))
        }
    }

    /// Notifications are held between the quiet hours, local time.
    func isQuietHour(at date: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard quietHoursEnabled else { return false }
        return QuietHours.contains(minute: calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date),
                                   start: quietHoursStart, end: quietHoursEnd)
    }

    /// Empties this app's defaults domain; the caller relaunches, so nothing here needs to be re-read.
    static func resetAll(defaults: UserDefaults = .standard, bundleIdentifier: String? = Bundle.main.bundleIdentifier) {
        if let bundleIdentifier {
            defaults.removePersistentDomain(forName: bundleIdentifier)
        } else {
            for key in defaults.dictionaryRepresentation().keys { defaults.removeObject(forKey: key) }
        }
        defaults.synchronize()
    }

    /// The oracle hears about changes only; the edge, the order and the compact style have events of their own.
    private func report(_ key: String, _ value: Any, changed: Bool, event: String = "pref") {
        guard changed else { return }
        Oracle.shared.emit(event, event == "pref" ? ["key": key, "value": value] : [key: value])
    }
}

enum QuietHours {
    /// A window that ends before it starts wraps past midnight: 22:00 to 08:00 covers the night.
    static func contains(minute: Int, start: Int, end: Int) -> Bool {
        if start == end { return false }
        if start < end { return minute >= start && minute < end }
        return minute >= start || minute < end
    }
}

/// The windows the compact rings draw: chosen ids first, in the chosen order, filled up to two from the reading's
/// own order, hidden windows never.
enum RingSelection {
    static func windows(of reading: UsageReading, chosen: [String], hidden: Set<String>) -> [LimitWindow] {
        let shown = reading.windows.filter { !hidden.contains($0.id) }
        var result: [LimitWindow] = []
        for id in chosen {
            if let window = shown.first(where: { $0.id == id }), !result.contains(where: { $0.id == id }) { result.append(window) }
        }
        for window in shown where result.count < 2 && !result.contains(where: { $0.id == window.id }) {
            result.append(window)
        }
        return Array(result.prefix(2))
    }
}

/// Names for the virtual key codes a shortcut recorder can show; anything else is "Key N".
enum KeyNames {
    private static let names: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
        16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
        30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "↩", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",",
        44: "/", 45: "N", 46: "M", 47: ".", 48: "⇥", 49: "Space", 50: "`", 51: "⌫", 53: "⎋", 96: "F5", 97: "F6", 98: "F7", 99: "F3",
        100: "F8", 101: "F9", 103: "F11", 109: "F10", 111: "F12", 118: "F4", 120: "F2", 122: "F1", 123: "←", 124: "→", 125: "↓", 126: "↑",
    ]

    static func name(for keyCode: UInt32) -> String {
        names[keyCode] ?? "Key \(keyCode)"
    }
}
