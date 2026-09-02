import AppKit
import Combine
import DynamicNotchKit
import SwiftUI

/// Closures the panel content can invoke; wired by the app delegate.
@MainActor
final class NotchActions {
    var refresh: () -> Void = {}
    var openSettings: () -> Void = {}
    var showOptions: () -> Void = {}
    var applyLayout: () -> Void = {}
}

/// One on-screen presentation of the readings: the notch itself or a Codenotch-style edge pill.
@MainActor
protocol PanelPresenting: AnyObject {
    var edge: PanelEdge { get }
    var isVisible: Bool { get }
    var windowFrame: NSRect? { get }
    func show()
    func hide() async
    func showOptions()
}

/// The right-click / Options menu shared by every panel style.
@MainActor
final class OptionsMenu: NSObject {
    private let prefs: Preferences
    private let actions: NotchActions

    init(prefs: Preferences, actions: NotchActions) {
        self.prefs = prefs
        self.actions = actions
    }

    func popUp(in window: NSWindow?, event: NSEvent? = nil) {
        let menu = build()
        if let event, let view = window?.contentView {
            NSMenu.popUpContextMenu(menu, with: event, for: view)
        } else {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }

    private func build() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item("Refresh now", #selector(refreshNow)))
        menu.addItem(.separator())
        for visibility in NotchVisibility.allCases {
            let entry = item(visibility.title, #selector(setVisibility(_:)))
            entry.representedObject = visibility.rawValue
            entry.state = prefs.visibility == visibility ? .on : .off
            menu.addItem(entry)
        }
        let position = NSMenuItem(title: "Position", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for edge in PanelEdge.allCases {
            let entry = item(edge.title, #selector(setEdge(_:)))
            entry.representedObject = edge.rawValue
            entry.state = prefs.edge == edge ? .on : .off
            submenu.addItem(entry)
        }
        position.submenu = submenu
        menu.addItem(position)
        menu.addItem(.separator())
        let login = item("Open at login", #selector(toggleLaunchAtLogin))
        login.state = prefs.launchAtLogin ? .on : .off
        menu.addItem(login)
        menu.addItem(item("Settings…", #selector(showSettings)))
        menu.addItem(.separator())
        menu.addItem(item("Quit \(AppInfo.name)", #selector(quit)))
        return menu
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        entry.target = self
        return entry
    }

    @objc private func refreshNow() { actions.refresh() }

    @objc private func setVisibility(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let visibility = NotchVisibility(rawValue: raw) else { return }
        prefs.visibility = visibility
        actions.applyLayout()
    }

    @objc private func setEdge(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let edge = PanelEdge(rawValue: raw) else { return }
        prefs.edge = edge
        actions.applyLayout()
    }

    @objc private func toggleLaunchAtLogin() { try? prefs.setLaunchAtLogin(!prefs.launchAtLogin) }
    @objc private func showSettings() { actions.openSettings() }
    @objc private func quit() { NSApp.terminate(nil) }
}

/// Top layout: compact rings beside the physical notch, the full panel below it on hover.
@MainActor
final class NotchController: NSObject, PanelPresenting {
    let edge: PanelEdge = .top
    private let store: UsageStore
    private let prefs: Preferences
    private let menu: OptionsMenu
    private let notch: DynamicNotch<NotchExpandedView, NotchCompactView, NotchCompactView>
    private var cancellables = Set<AnyCancellable>()
    private var collapseTask: Task<Void, Never>?
    private var rightClickMonitor: Any?

    init(store: UsageStore, prefs: Preferences, actions: NotchActions) {
        self.store = store
        self.prefs = prefs
        self.menu = OptionsMenu(prefs: prefs, actions: actions)
        let hasNotch = NSScreen.screens.contains { $0.safeAreaInsets.top > 0 }
        notch = DynamicNotch(hoverBehavior: [.keepVisible, .increaseShadow], style: hasNotch ? .notch : .floating) {
            NotchExpandedView(store: store, prefs: prefs, actions: actions)
        } compactLeading: {
            NotchCompactView(store: store, side: .leading)
        } compactTrailing: {
            NotchCompactView(store: store, side: .trailing)
        }
        super.init()
        notch.transitionConfiguration.skipIntermediateHides = true
        notch.$isHovering
            .removeDuplicates()
            .sink { [weak self] hovering in
                Task { @MainActor in self?.hoverChanged(hovering) }
            }
            .store(in: &cancellables)
        // Local monitors run on the main thread. assumeIsolated must return something Sendable, which NSEvent is not,
        // so the closure reports whether it handled the event and the event is passed on outside it.
        rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self, let window = self.notch.windowController?.window, event.window === window else { return false }
                self.menu.popUp(in: window, event: event)
                return true
            }
            return handled ? nil : event
        }
    }

    var targetScreen: NSScreen {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    var windowFrame: NSRect? { notch.windowController?.window?.frame }
    var isVisible: Bool { notch.windowController?.window?.isVisible ?? false }

    func show() {
        Task { await self.apply(hovering: self.notch.isHovering) }
    }

    func hide() async {
        if let rightClickMonitor { NSEvent.removeMonitor(rightClickMonitor) }
        rightClickMonitor = nil
        collapseTask?.cancel()
        await notch.hide()
    }

    func showOptions() {
        menu.popUp(in: notch.windowController?.window)
    }

    private func hoverChanged(_ hovering: Bool) {
        collapseTask?.cancel()
        if hovering {
            Task { await self.notch.expand(on: self.targetScreen) }
            store.refreshAll(force: false)
        } else {
            collapseTask = Task {
                try? await Task.sleep(for: .seconds(0.45))
                guard !Task.isCancelled else { return }
                await self.apply(hovering: false)
            }
        }
    }

    private func apply(hovering: Bool) async {
        if prefs.visibility == .always || hovering {
            await notch.expand(on: targetScreen)
        } else {
            await notch.compact(on: targetScreen)
        }
    }
}
