//
//  EnvironmentValues+Extensions.swift
//  DynamicNotchKit
//
//  Created by Kai Azim on 2025-03-26.
//
//  Notchmeter: @Entry replaced with explicit EnvironmentKeys so the package builds
//  with the Command Line Tools alone (the SwiftUI macro plugin ships only with Xcode).

import SwiftUI

private struct DynamicNotchStyleKey: EnvironmentKey {
    static let defaultValue: DynamicNotchStyle = .auto
}

private struct DynamicNotchSectionKey: EnvironmentKey {
    static let defaultValue: DynamicNotchSection = .expanded
}

extension EnvironmentValues {
    var notchStyle: DynamicNotchStyle {
        get { self[DynamicNotchStyleKey.self] }
        set { self[DynamicNotchStyleKey.self] = newValue }
    }

    var notchSection: DynamicNotchSection {
        get { self[DynamicNotchSectionKey.self] }
        set { self[DynamicNotchSectionKey.self] = newValue }
    }
}

enum DynamicNotchSection {
    case expanded
    case compactLeading
    case compactTrailing
}
