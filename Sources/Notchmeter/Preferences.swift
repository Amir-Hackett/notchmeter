import Foundation
import Observation
import ServiceManagement

enum NotchVisibility: String, CaseIterable, Codable {
    case onHover, always

    var title: String {
        switch self {
        case .onHover: "Open on hover"
        case .always: "Always open"
        }
    }
}

/// Where the panel lives. Top merges with the physical notch; the others are Codenotch-style edge pills.
enum PanelEdge: String, CaseIterable, Codable {
    case top, left, right, bottom

    var title: String {
        switch self {
        case .top: "Top, in the notch"
        case .left: "Left edge"
        case .right: "Right edge"
        case .bottom: "Bottom, above the Dock"
        }
    }

    var detail: String {
        switch self {
        case .top: "Readings sit beside the notch and open below it."
        case .left: "A pill down the left-hand edge, clear of a Dock on that side."
        case .right: "A pill down the right-hand edge, clear of a Dock on that side."
        case .bottom: "A bar resting on top of the Dock."
        }
    }
}

@MainActor
@Observable
final class Preferences {
    @ObservationIgnored private let defaults: UserDefaults

    var enabledTools: Set<ToolID> { didSet { defaults.set(enabledTools.map(\.rawValue).sorted(), forKey: Keys.enabledTools) } }
    var visibility: NotchVisibility { didSet { defaults.set(visibility.rawValue, forKey: Keys.visibility) } }
    var edge: PanelEdge { didSet { defaults.set(edge.rawValue, forKey: Keys.edge) } }
    var showSpend: Bool { didSet { defaults.set(showSpend, forKey: Keys.showSpend) } }
    var usageDisplay: UsageDisplay { didSet { defaults.set(usageDisplay.rawValue, forKey: Keys.usageDisplay) } }
    var resetDisplay: ResetDisplay { didSet { defaults.set(resetDisplay.rawValue, forKey: Keys.resetDisplay) } }
    var timeFormat: TimeFormatPreference { didSet { defaults.set(timeFormat.rawValue, forKey: Keys.timeFormat) } }
    /// Pace-crossing notifications (NotificationScheduler.swift); on by default, asked for on first use.
    var notificationsEnabled: Bool { didSet { defaults.set(notificationsEnabled, forKey: Keys.notificationsEnabled) } }
    private(set) var launchAtLogin: Bool

    private enum Keys {
        static let enabledTools = "enabledTools"
        static let visibility = "notchVisibility"
        static let edge = "panelEdge"
        static let showSpend = "showSpend"
        static let usageDisplay = "usageDisplay"
        static let resetDisplay = "resetDisplay"
        static let timeFormat = "timeFormat"
        static let notificationsEnabled = "notificationsEnabled"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let raw = defaults.array(forKey: Keys.enabledTools) as? [String] {
            enabledTools = Set(raw.compactMap(ToolID.init(rawValue:)))
        } else {
            enabledTools = Set(ToolID.allCases)
        }
        visibility = NotchVisibility(rawValue: defaults.string(forKey: Keys.visibility) ?? "") ?? .onHover
        edge = PanelEdge(rawValue: defaults.string(forKey: Keys.edge) ?? "") ?? .top
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
    }

    func resetLine(for window: LimitWindow, stale: Bool = false, now: Date = Date()) -> String {
        ResetText.line(resetsAt: window.resetsAt, hasLimit: window.usedFraction != nil, display: resetDisplay, timeFormat: timeFormat,
                       stale: stale, now: now)
    }

    func usageLine(for window: LimitWindow) -> String? {
        guard let used = window.usedFraction else { return nil }
        switch usageDisplay {
        case .used: return "\(Int((used * 100).rounded()))% used"
        case .left: return "\(Int(((1 - used) * 100).rounded()))% left"
        }
    }
}
