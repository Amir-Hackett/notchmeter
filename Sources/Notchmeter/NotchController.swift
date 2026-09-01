import AppKit
import Combine
import DynamicNotchKit
import SwiftUI

/// Owns the notch window: compact rings by default, the full panel on hover, a context menu on right-click.
private struct UncheckedBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

@MainActor
final class NotchController: NSObject {
    private let store: UsageStore
    private let prefs: Preferences
    private let notch: DynamicNotch<NotchExpandedView, NotchCompactView, NotchCompactView>
    private var cancellables = Set<AnyCancellable>()
    private var collapseTask: Task<Void, Never>?
    private var rightClickMonitor: Any?
    var openSettings: (() -> Void)?

    init(store: UsageStore, prefs: Preferences) {
        self.store = store
        self.prefs = prefs
        let hasNotch = NSScreen.screens.contains { $0.safeAreaInsets.top > 0 }
        notch = DynamicNotch(hoverBehavior: [.keepVisible, .increaseShadow], style: hasNotch ? .notch : .floating) {
            NotchExpandedView(store: store, prefs: prefs)
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
        // Local monitors are delivered on the main thread; the box keeps the non-Sendable NSEvent out of the closure's capture check.
        rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            let boxed = UncheckedBox(event)
            return MainActor.assumeIsolated {
                let event = boxed.value
                guard let self, let window = self.notch.windowController?.window, event.window === window else { return event }
                self.showMenu(with: event, in: window)
                return nil
            }
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

    // MARK: - Context menu

    private func showMenu(with event: NSEvent, in window: NSWindow) {
        let menu = NSMenu()
        menu.addItem(item("Refresh now", #selector(refreshNow)))
        menu.addItem(.separator())
        for visibility in NotchVisibility.allCases {
            let entry = item(visibility.title, #selector(setVisibility(_:)))
            entry.representedObject = visibility.rawValue
            entry.state = prefs.visibility == visibility ? .on : .off
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        let login = item("Open at login", #selector(toggleLaunchAtLogin))
        login.state = prefs.launchAtLogin ? .on : .off
        menu.addItem(login)
        menu.addItem(item("Settings…", #selector(showSettings)))
        menu.addItem(.separator())
        menu.addItem(item("Quit \(AppInfo.name)", #selector(quit)))
        guard let view = window.contentView else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        entry.target = self
        return entry
    }

    @objc private func refreshNow() {
        store.refreshAll()
    }

    @objc private func setVisibility(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let visibility = NotchVisibility(rawValue: raw) else { return }
        prefs.visibility = visibility
        show()
    }

    @objc private func toggleLaunchAtLogin() {
        try? prefs.setLaunchAtLogin(!prefs.launchAtLogin)
    }

    @objc private func showSettings() {
        openSettings?()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
