import AppKit
import Testing
@testable import Notchmeter

/// The corner every window the app builds from `SettingsPanel` wears. The class is shared between Settings and the
/// dashboard, and `wearCloseOnly()` is a call each controller has to remember rather than something the class does
/// for itself, which is how the dashboard came to ship without it: a permanently greyed minimise light and a zoom
/// button whose Move & Resize tiles took the window out from under the notch that `frame(for:…)` had put it under.
/// Both controllers are built here the way the app builds them, so a third window made from the class, or either of
/// these two losing the call again, fails a test rather than a release.
@Suite struct PanelChrome {
    @MainActor @Test func everyWindowBuiltFromTheSettingsPanelHidesMinimiseAndZoom() throws {
        let suite = "NotchmeterTests.PanelChrome"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = Preferences(defaults: defaults)
        let store = UsageStore(prefs: prefs, providers: [], cache: ReadingCache(defaults: defaults), defaults: defaults, drainLog: nil)
        let settings = SettingsWindowController(store: store, prefs: prefs, actions: NotchActions(), notifier: Notifier(available: false),
                                                requests: SettingsRequests())
        let dashboard = DashboardWindowController(store: store, prefs: prefs)
        for (name, controller) in [("Settings", settings), ("Dashboard", dashboard)] as [(String, NSWindowController)] {
            let window = try #require(controller.window, "\(name) has no window")
            #expect(window is SettingsPanel, "\(name) is not built from SettingsPanel")
            // The buttons have to exist for hiding them to mean anything: a titled window without `.miniaturizable`
            // still gets its minimise light drawn, greyed, and `.resizable` earns the zoom button.
            let minimise = try #require(window.standardWindowButton(.miniaturizeButton), "\(name) has no minimise button to hide")
            let zoom = try #require(window.standardWindowButton(.zoomButton), "\(name) has no zoom button to hide")
            #expect(minimise.isHidden, "\(name) shows a minimise button it has nowhere to minimise to")
            #expect(zoom.isHidden, "\(name) shows a zoom button whose tiles move it off the notch")
        }
    }
}
