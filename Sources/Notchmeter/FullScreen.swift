import AppKit

/// Whether another app is running full-screen on a given display, so the readouts can get out of the way.
///
/// A window that joins every space still draws over a full-screen app, whatever its collection behaviour, so
/// the panel has to be ordered out rather than merely reconfigured. Detection reads the on-screen window list:
/// bounds, owner and layer come back without Screen Recording permission (only window titles need it).
enum FullScreen {
    /// A normal-layer window from another app that covers the whole display, menu bar included.
    static func isActive(on screen: NSScreen, ownName: String = AppInfo.name) -> Bool {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let infos = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return false }
        let target = screen.frame.size
        for info in infos {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let owner = info[kCGWindowOwnerName as String] as? String, owner != ownName,
                  let raw = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: raw)
            else { continue }
            if abs(bounds.width - target.width) < 1, abs(bounds.height - target.height) < 1 { return true }
        }
        return false
    }
}

/// Calls back when a display enters or leaves full screen. Entering full screen switches Space, so that
/// notification carries the change; an app activation covers the case of switching between full-screen apps.
@MainActor
final class FullScreenWatch {
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private(set) var isActive = false
    private let screen: () -> NSScreen
    private let changed: (Bool) -> Void

    init(screen: @escaping () -> NSScreen, changed: @escaping (Bool) -> Void) {
        self.screen = screen
        self.changed = changed
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            observers.append((workspace, workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }))
        }
        refresh()
    }

    deinit {
        for (center, token) in observers { center.removeObserver(token) }
    }

    func refresh() {
        let active = FullScreen.isActive(on: screen())
        guard active != isActive else { return }
        isActive = active
        changed(active)
    }

    func stop() {
        for (center, token) in observers { center.removeObserver(token) }
        observers = []
    }
}
