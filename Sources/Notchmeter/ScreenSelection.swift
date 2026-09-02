import AppKit

/// What the display choice needs to know about a screen; built from NSScreen, or by a test.
struct ScreenInfo: Equatable, Sendable {
    let name: String
    let hasNotch: Bool
    let isMain: Bool
    let frame: CGRect
}

/// Which screens carry a panel for a display choice, with the fallbacks when the chosen one is gone: the built-in
/// display is the first with a notch, else the main one; a named display that is unplugged falls back the same way;
/// the pointer's display is the one under it, else the main one.
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
        case .named(let name):
            return [screens.firstIndex { $0.name == name } ?? builtIn]
        }
    }
}

extension NSScreen {
    var info: ScreenInfo {
        ScreenInfo(name: localizedName, hasNotch: safeAreaInsets.top > 0, isMain: self == NSScreen.main, frame: frame)
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

    /// One line per screen for `--smoke` and the oracle's `screens` event.
    static var descriptions: [[String: Any]] {
        screens.map { screen in
            ["name": screen.localizedName, "frame": screen.frame, "visibleFrame": screen.visibleFrame,
             "safeAreaTop": screen.safeAreaInsets.top, "notch": screen.safeAreaInsets.top > 0,
             "isMain": screen == NSScreen.main, "isPrimary": screen == screens.first]
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

/// Menu bar and Dock auto-hide, read once per layout rather than cached (Apple: "Don't cache the rectangle").
enum SystemChrome {
    static var menuBarAutoHides: Bool {
        UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["_HIHideMenuBar"] as? Bool ?? false
    }

    static var dockAutoHides: Bool {
        UserDefaults.standard.persistentDomain(forName: "com.apple.dock")?["autohide"] as? Bool ?? false
    }

    /// The strip along the bottom edge that reveals a hidden Dock; a bottom bar sits above it.
    static let dockRevealStrip: CGFloat = 4
}
