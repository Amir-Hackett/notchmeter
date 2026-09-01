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

@MainActor
@Observable
final class Preferences {
    @ObservationIgnored private let defaults: UserDefaults

    var enabledTools: Set<ToolID> {
        didSet { defaults.set(enabledTools.map(\.rawValue).sorted(), forKey: Keys.enabledTools) }
    }

    var visibility: NotchVisibility {
        didSet { defaults.set(visibility.rawValue, forKey: Keys.visibility) }
    }

    private(set) var launchAtLogin: Bool

    private enum Keys {
        static let enabledTools = "enabledTools"
        static let visibility = "notchVisibility"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let raw = defaults.array(forKey: Keys.enabledTools) as? [String] {
            enabledTools = Set(raw.compactMap(ToolID.init(rawValue:)))
        } else {
            enabledTools = Set(ToolID.allCases)
        }
        visibility = NotchVisibility(rawValue: defaults.string(forKey: Keys.visibility) ?? "") ?? .onHover
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
}
