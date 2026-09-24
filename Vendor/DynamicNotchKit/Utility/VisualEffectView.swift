//
//  VisualEffectView.swift
//  DynamicNotchKit
//
//  Created by Kai Azim on 2024-04-06.
//
//  Notchmeter: an optional appearance, so a blur behind a dark panel stays dark whatever the system's appearance,
//  and the material stays active while another app is frontmost (the panel never becomes key).

import SwiftUI

struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    var appearance: NSAppearance? = nil

    func makeNSView(context _: Context) -> NSVisualEffectView {
        let visualEffectView = NSVisualEffectView()
        visualEffectView.material = material
        visualEffectView.blendingMode = blendingMode
        visualEffectView.state = .active
        visualEffectView.isEmphasized = true
        visualEffectView.appearance = appearance
        return visualEffectView
    }

    func updateNSView(_: NSVisualEffectView, context _: Context) {}
}
