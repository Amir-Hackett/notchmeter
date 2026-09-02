//
// DynamicNotchPanel.swift
// DynamicNotchKit
//
// Created by <Huy D.> on 2024-11-01.
//
// Notchmeter: isOpaque is set false explicitly. A clear background alone leaves NSPanel opaque, and the
// window now spans the screen's full height, so its transparent area must stay click-through. The collection
// behaviour is set by the app (DynamicNotch.collectionBehavior) so the "Show over full-screen apps" setting
// applies to this window the same way it applies to the edge pills.

import AppKit

final class DynamicNotchPanel: NSPanel {
    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(
            contentRect: contentRect,
            styleMask: style,
            backing: backingStoreType,
            defer: flag
        )
        self.hasShadow = false
        self.isOpaque = false
        self.backgroundColor = .clear
        self.level = .screenSaver
        self.collectionBehavior = [.canJoinAllSpaces, .stationary]
    }

    override var canBecomeKey: Bool {
        true
    }
}
