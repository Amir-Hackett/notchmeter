import Foundation
import Observation
import ServiceManagement

enum NotchVisibility: String, CaseIterable, Codable {
    case onHover, always

    var title: String {
        switch self {
        case .onHover: L("Open on hover")
        case .always: L("Always open")
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
    var edge: PanelEdge {
        didSet { defaults.set(edge.rawValue, forKey: Keys.edge); report("edge", edge.rawValue, changed: edge != oldValue, event: "layout") }
    }
    var compactStyle: CompactStyle {
        didSet {
            defaults.set(compactStyle.rawValue, forKey: Keys.compactStyle)
            report("compactStyle", compactStyle.rawValue, changed: compactStyle != oldValue, event: "compactStyle")
        }
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
    /// Pace-crossing notifications (NotificationScheduler.swift); on by default, asked for on first use.
    var notificationsEnabled: Bool {
        didSet {
            defaults.set(notificationsEnabled, forKey: Keys.notificationsEnabled)
            report(Keys.notificationsEnabled, notificationsEnabled, changed: notificationsEnabled != oldValue)
        }
    }
    private(set) var launchAtLogin: Bool

    private enum Keys {
        static let enabledTools = "enabledTools"
        static let toolOrder = "toolOrder"
        static let visibility = "notchVisibility"
        static let edge = "panelEdge"
        static let compactStyle = "compactStyle"
        static let showSpend = "showSpend"
        static let usageDisplay = "usageDisplay"
        static let resetDisplay = "resetDisplay"
        static let timeFormat = "timeFormat"
        static let notificationsEnabled = "notificationsEnabled"
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
        edge = PanelEdge(rawValue: defaults.string(forKey: Keys.edge) ?? "") ?? .top
        compactStyle = CompactStyle(rawValue: defaults.string(forKey: Keys.compactStyle) ?? "") ?? .rings
        showSpend = defaults.object(forKey: Keys.showSpend) as? Bool ?? true
        usageDisplay = UsageDisplay(rawValue: defaults.string(forKey: Keys.usageDisplay) ?? "") ?? .used
        resetDisplay = ResetDisplay(rawValue: defaults.string(forKey: Keys.resetDisplay) ?? "") ?? .exact
        timeFormat = TimeFormatPreference(rawValue: defaults.string(forKey: Keys.timeFormat) ?? "") ?? .auto
        notificationsEnabled = defaults.object(forKey: Keys.notificationsEnabled) as? Bool ?? true
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
        report(Keys.launchAtLogin, launchAtLogin, changed: true)
    }

    /// Moves a tool one place up (-1) or down (+1); nothing happens at the ends.
    func move(_ tool: ToolID, by offset: Int) {
        guard let index = toolOrder.firstIndex(of: tool), toolOrder.indices.contains(index + offset) else { return }
        toolOrder.swapAt(index, index + offset)
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

    /// The oracle hears about changes only; the edge, the order and the compact style have events of their own.
    private func report(_ key: String, _ value: Any, changed: Bool, event: String = "pref") {
        guard changed else { return }
        Oracle.shared.emit(event, event == "pref" ? ["key": key, "value": value] : [key: value])
    }
}
