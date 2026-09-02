import AppKit

/// What the display choice needs to know about a screen; built from NSScreen, or by a test.
struct ScreenInfo: Equatable, Sendable {
    let name: String
    /// A stable identity for the panel (DisplayIdentity): survives a rename and tells two identical monitors apart.
    let key: String
    let hasNotch: Bool
    /// The display with the menu bar, index 0 of NSScreen.screens: what System Settings › Displays calls the main display.
    let isMain: Bool
    let frame: CGRect

    init(name: String, key: String? = nil, hasNotch: Bool, isMain: Bool, frame: CGRect) {
        self.name = name
        self.key = key ?? name
        self.hasNotch = hasNotch
        self.isMain = isMain
        self.frame = frame
    }
}

/// Which screens carry a panel for a display choice, with the fallbacks when the chosen one is gone: the built-in
/// display is the first with a notch, else the main one; a named display that is unplugged falls back the same way;
/// the pointer's display is the one under it, else the main one. A named choice stored by an earlier version is a
/// localizedName; it still matches on the name until the preference is written again with the identity key.
enum ScreenSelection {
    static func indices(for choice: DisplayChoice, screens: [ScreenInfo], pointer: CGPoint) -> [Int] {
        guard !screens.isEmpty else { return [] }
        let main = screens.firstIndex(where: \.isMain) ?? 0
        let builtIn = screens.firstIndex(where: \.hasNotch) ?? main
        switch choice {
        case .builtIn:
            return [builtIn]
        case .main:
            return [main]
        case .pointer:
            return [screens.firstIndex { $0.frame.contains(pointer) } ?? main]
        case .all:
            return Array(screens.indices)
        case .named(let key):
            return [screens.firstIndex { $0.key == key } ?? screens.firstIndex { $0.name == key } ?? builtIn]
        }
    }
}

/// A display's identity from the public CoreGraphics display registration: vendor, model and serial number, with
/// the unit number standing in when a panel reports no serial (some do), and an index when two identical panels
/// report identical numbers. Never the localizedName alone, which two monitors of one model share.
enum DisplayIdentity {
    static func key(vendor: UInt32, model: UInt32, serial: UInt32, unit: UInt32, duplicateIndex: Int) -> String {
        let base = serial != 0 ? "\(vendor)-\(model)-\(serial)" : "\(vendor)-\(model)-u\(unit)"
        return duplicateIndex > 0 ? "\(base)#\(duplicateIndex)" : base
    }

    /// One key per screen, in `screens` order, with duplicates suffixed by their position among their twins.
    static func keys(for screens: [NSScreen]) -> [String] {
        var seen: [String: Int] = [:]
        return screens.map { screen in
            let id = screen.displayID
            let base = key(vendor: CGDisplayVendorNumber(id), model: CGDisplayModelNumber(id), serial: CGDisplaySerialNumber(id), unit: CGDisplayUnitNumber(id), duplicateIndex: 0)
            let index = seen[base, default: 0]
            seen[base] = index + 1
            return index > 0 ? "\(base)#\(index)" : base
        }
    }

    /// The names to show for a list of screens: a duplicate localizedName gains "(2)", "(3)".
    static func titles(for names: [String]) -> [String] {
        var seen: [String: Int] = [:]
        return names.map { name in
            let count = seen[name, default: 0] + 1
            seen[name] = count
            return count > 1 ? "\(name) (\(count))" : name
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) } ?? 0
    }

    /// The identity key among the current screens.
    var identityKey: String {
        let all = NSScreen.screens
        guard let index = all.firstIndex(of: self) else { return DisplayIdentity.keys(for: [self])[0] }
        return DisplayIdentity.keys(for: all)[index]
    }

    /// The name to show in a picker, suffixed when another screen shares it.
    var displayTitle: String {
        let all = NSScreen.screens
        guard let index = all.firstIndex(of: self) else { return localizedName }
        return DisplayIdentity.titles(for: all.map(\.localizedName))[index]
    }

    var info: ScreenInfo {
        ScreenInfo(name: localizedName, key: identityKey, hasNotch: safeAreaInsets.top > 0, isMain: self == NSScreen.screens.first, frame: frame)
    }

    /// The screens the panel is shown on for the choice, in NSScreen.screens order.
    static func panelScreens(for choice: DisplayChoice, pointer: CGPoint = NSEvent.mouseLocation) -> [NSScreen] {
        let all = screens
        return ScreenSelection.indices(for: choice, screens: all.map(\.info), pointer: pointer).map { all[$0] }
    }

    /// Where the panel lives by default: the display with the notch when there is one, else the main screen.
    static var panelScreen: NSScreen {
        panelScreens(for: .builtIn).first ?? main ?? screens[0]
    }

    /// The screen under the pointer, for windows that should open where the user is working.
    static var pointerScreen: NSScreen {
        panelScreens(for: .pointer).first ?? panelScreen
    }

    /// The current NSScreen for a stored identity key, so a controller never keeps an instance across a display change.
    static func screen(withKey key: String) -> NSScreen? {
        let all = screens
        let keys = DisplayIdentity.keys(for: all)
        return keys.firstIndex(of: key).map { all[$0] }
    }

    /// One line per screen for `--smoke` and the oracle's `screens` event.
    static var descriptions: [[String: Any]] {
        let keys = DisplayIdentity.keys(for: screens)
        return screens.enumerated().map { index, screen in
            ["name": screen.localizedName, "key": keys[index], "frame": screen.frame, "visibleFrame": screen.visibleFrame,
             "safeAreaTop": screen.safeAreaInsets.top, "notch": screen.safeAreaInsets.top > 0,
             "isMain": screen == NSScreen.screens.first, "isPrimary": screen == screens.first, "hasKeyWindow": screen == NSScreen.main]
        }
    }

    /// The menu bar's height as visibleFrame reports it right now (zero while an auto-hidden bar is away).
    var menuBarHeightNow: CGFloat {
        frame.maxY - visibleFrame.maxY
    }

    /// True when the Dock is set to hide: the usable area then reaches the screen's bottom edge on the Dock's side.
    var dockHidesOnThisScreen: Bool {
        abs(visibleFrame.minY - frame.minY) < 4 && abs(visibleFrame.minX - frame.minX) < 4 && abs(visibleFrame.maxX - frame.maxX) < 4
    }
}

/// Menu bar, Dock and Stage Manager state, read once per layout rather than cached (Apple: "Don't cache the rectangle").
enum SystemChrome {
    static var menuBarAutoHides: Bool {
        UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["_HIHideMenuBar"] as? Bool ?? false
    }

    static var dockAutoHides: Bool {
        UserDefaults.standard.persistentDomain(forName: "com.apple.dock")?["autohide"] as? Bool ?? false
    }

    /// "bottom", "left" or "right", as the Dock's own preference has it.
    static var dockOrientation: String {
        (UserDefaults.standard.persistentDomain(forName: "com.apple.dock")?["orientation"] as? String) ?? "bottom"
    }

    /// Stage Manager, from the window manager's own preferences: on at all, and whether its recent-apps strip on
    /// the left edge hides until the pointer touches that edge.
    static var stageManagerEnabled: Bool {
        UserDefaults.standard.persistentDomain(forName: "com.apple.WindowManager")?["GloballyEnabled"] as? Bool ?? false
    }

    static var stageManagerStripAutoHides: Bool {
        UserDefaults.standard.persistentDomain(forName: "com.apple.WindowManager")?["AutoHide"] as? Bool ?? false
    }

    /// The strip along the bottom edge that reveals a hidden Dock; a bottom bar sits above it.
    static let dockRevealStrip: CGFloat = 4
    /// The width of Stage Manager's recent-apps strip along the left edge: 120 pt thumbnails with the 16 pt margins
    /// either side that Apple's window manager lays them out with. visibleFrame does not exclude it. Not measured on
    /// this machine (Stage Manager is off here and turning it on is a system setting); re-measure on macOS 14, 15
    /// and 26 and correct the constant if the strip differs.
    static let stageManagerStripWidth: CGFloat = 152

    /// The menu bar's full height for a screen, for placing a top pill under a bar that is away right now.
    static var menuBarThickness: CGFloat {
        max(NSStatusBar.system.thickness, NSApplication.shared.mainMenu?.menuBarHeight ?? 0, 24)
    }
}
