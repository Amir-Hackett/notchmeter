//
//  NotchView.swift
//  DynamicNotchKit
//
//  Created by Kai Azim on 2023-08-24.
//

import SwiftUI

struct NotchView<Expanded, CompactLeading, CompactTrailing>: View where Expanded: View, CompactLeading: View, CompactTrailing: View {
    @ObservedObject private var dynamicNotch: DynamicNotch<Expanded, CompactLeading, CompactTrailing>
    @State private var compactLeadingWidth: CGFloat = 0
    @State private var compactTrailingWidth: CGFloat = 0
    private let safeAreaInset: CGFloat = 15
    /// Notchmeter: whether the blur behind a translucent panel is in the hierarchy. Only while it can be seen. The
    /// compact strip is opaque black over it for nearly all of the panel's life, and WindowServer composites a
    /// behind-window blur on every frame the desktop under it changes whether or not something opaque covers it,
    /// so a blur left mounted under the strip would be paid for on every menu-bar redraw and every window dragged
    /// under the notch, for nothing anyone sees. It goes in as the panel opens and comes out once the black has
    /// faded back over it, so the close still crossfades; `GlassBackdrop` below is gated the same way.
    @State private var backdropMounted = false
    /// The body's black fading out over the blur as the panel opens, and back in, quicker, as it closes.
    private let backdropFadeIn: Double = 0.22
    private let backdropFadeOut: Double = 0.15

    init(dynamicNotch: DynamicNotch<Expanded, CompactLeading, CompactTrailing>) {
        self.dynamicNotch = dynamicNotch
    }

    private var expandedNotchCornerRadii: (top: CGFloat, bottom: CGFloat) {
        if case let .notch(topCornerRadius, bottomCornerRadius) = dynamicNotch.style {
            (top: topCornerRadius, bottom: bottomCornerRadius)
        } else {
            (top: 15, bottom: 20)
        }
    }

    private var compactNotchCornerRadii: (top: CGFloat, bottom: CGFloat) {
        (top: 6, bottom: 14)
    }

    private var minWidth: CGFloat {
        dynamicNotch.notchSize.width + (topCornerRadius * 2)
    }

    private var topCornerRadius: CGFloat {
        dynamicNotch.state == .expanded ? expandedNotchCornerRadii.top : compactNotchCornerRadii.top
    }

    private var bottomCornerRadius: CGFloat {
        dynamicNotch.state == .expanded ? expandedNotchCornerRadii.bottom : compactNotchCornerRadii.bottom
    }

    private var xOffset: CGFloat {
        if dynamicNotch.state != .compact {
            0
        } else {
            compactXOffset
        }
    }

    private var compactXOffset: CGFloat {
        (compactTrailingWidth - compactLeadingWidth) / 2
    }

    var body: some View {
        notchContent()
            .background {
                ZStack(alignment: .top) {
                    if let tint = dynamicNotch.expandedTint {
                        // Notchmeter: a translucent panel. The blur and its tint under everything, there only while
                        // the panel is open (`backdropMounted`); the body's black over them fades out as the panel
                        // opens (and back in, quicker, as it closes), so the compact strip is never translucent; the
                        // band the hardware notch sits in stays black throughout.
                        if backdropMounted {
                            ZStack {
                                VisualEffectView(material: .hudWindow, blendingMode: .behindWindow, appearance: NSAppearance(named: .darkAqua))
                                Rectangle().foregroundStyle(.black.opacity(tint))
                            }
                            .padding(-50)
                        }
                        Rectangle()
                            .foregroundStyle(.black)
                            .opacity(dynamicNotch.state == .expanded ? 0 : 1)
                            .padding(-50)
                            .animation(dynamicNotch.reduceMotion ? nil
                                       : dynamicNotch.state == .expanded ? .easeOut(duration: backdropFadeIn) : .easeIn(duration: backdropFadeOut),
                                       value: dynamicNotch.state)
                        Rectangle()
                            .foregroundStyle(.black)
                            .frame(height: dynamicNotch.notchSize.height + 50)
                            .padding(.horizontal, -50)
                            .offset(y: -50)
                    } else {
                        Rectangle()
                            .foregroundStyle(.black)
                            .padding(-50) // The opening/closing animation can overshoot, so this makes sure that it's still black
                    }
                    // Notchmeter: Liquid Glass under the expanded content only; the strip beside the notch stays black.
                    if dynamicNotch.expandedGlass, dynamicNotch.state == .expanded {
                        GlassBackdrop()
                            .padding(.top, dynamicNotch.notchSize.height)
                    }
                }
            }
            .mask {
                NotchShape(
                    topCornerRadius: topCornerRadius,
                    bottomCornerRadius: bottomCornerRadius
                )
                .padding(.horizontal, 0.5)
                .frame(
                    width: dynamicNotch.state != .hidden ? nil : minWidth,
                    height: dynamicNotch.state != .hidden ? nil : dynamicNotch.notchSize.height
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .offset(x: xOffset)
            // Notchmeter: no slide under Reduce Motion (DynamicNotch.reduceMotion).
            .animation(dynamicNotch.reduceMotion ? nil : .smooth, value: [compactLeadingWidth, compactTrailingWidth])
            .onAppear { backdropMounted = dynamicNotch.state == .expanded }
            .onChange(of: dynamicNotch.state) { _, state in mountBackdrop(for: state) }
    }

    /// Notchmeter: the blur goes in the moment the panel opens and comes out once the close fade has covered it —
    /// at once under Reduce Motion, where there is no fade. A panel reopened inside the fade keeps its blur.
    private func mountBackdrop(for state: DynamicNotchState) {
        if state == .expanded {
            backdropMounted = true
        } else if dynamicNotch.reduceMotion {
            backdropMounted = false
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + backdropFadeOut) {
                if dynamicNotch.state != .expanded { backdropMounted = false }
            }
        }
    }

    private func notchContent() -> some View {
        ZStack {
            compactContent()
                .fixedSize()
                .offset(x: dynamicNotch.state == .compact ? 0 : compactXOffset)
                .frame(
                    width: dynamicNotch.state == .compact ? nil : dynamicNotch.notchSize.width,
                    height: (dynamicNotch.state == .compact && dynamicNotch.isHovering) ? dynamicNotch.menubarHeight : dynamicNotch.notchSize.height
                )

            expandedContent()
                .fixedSize()
                .frame(
                    maxWidth: dynamicNotch.state == .expanded ? nil : 0,
                    maxHeight: dynamicNotch.state == .expanded ? nil : 0
                )
                .offset(x: dynamicNotch.state == .compact ? -compactXOffset : 0)
        }
        .padding(.horizontal, topCornerRadius)
        .fixedSize()
        .frame(minWidth: minWidth, minHeight: dynamicNotch.notchSize.height)
        .onHover(perform: dynamicNotch.updateHoverState)
    }

    func compactContent() -> some View {
        HStack(spacing: 0) {
            if dynamicNotch.state == .compact, !dynamicNotch.disableCompactLeading {
                dynamicNotch.compactLeadingContent
                    .environment(\.notchSection, .compactLeading)
                    .safeAreaInset(edge: .leading, spacing: 0) { Color.clear.frame(width: 8) }
                    .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: 4) }
                    .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: 8) }
                    .onGeometryChange(for: CGFloat.self, of: \.size.width) { compactLeadingWidth = $0 }
                    .transition(.blur(intensity: 10).combined(with: .scale(x: 0, anchor: .trailing)).combined(with: .opacity))
            }

            Spacer()
                .frame(width: dynamicNotch.notchSize.width)

            if dynamicNotch.state == .compact, !dynamicNotch.disableCompactTrailing {
                dynamicNotch.compactTrailingContent
                    .environment(\.notchSection, .compactTrailing)
                    .safeAreaInset(edge: .trailing, spacing: 0) { Color.clear.frame(width: 8) }
                    .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: 4) }
                    .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: 8) }
                    .onGeometryChange(for: CGFloat.self, of: \.size.width) { compactTrailingWidth = $0 }
                    .transition(.blur(intensity: 10).combined(with: .scale(x: 0, anchor: .leading)).combined(with: .opacity))
            }
        }
        .frame(height: dynamicNotch.notchSize.height)
        .onChange(of: dynamicNotch.disableCompactLeading) { _ in
            if dynamicNotch.disableCompactLeading {
                compactLeadingWidth = 0
            }
        }
        .onChange(of: dynamicNotch.disableCompactTrailing) { _ in
            if dynamicNotch.disableCompactTrailing {
                compactTrailingWidth = 0
            }
        }
    }

    func expandedContent() -> some View {
        HStack(spacing: 0) {
            if dynamicNotch.state == .expanded {
                dynamicNotch.expandedContent
                    .transition(.blur(intensity: 10).combined(with: .scale(y: 0.6, anchor: .top)).combined(with: .opacity))
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: dynamicNotch.notchSize.height) }
        .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: safeAreaInset) }
        .safeAreaInset(edge: .leading, spacing: 0) { Color.clear.frame(width: safeAreaInset) }
        .safeAreaInset(edge: .trailing, spacing: 0) { Color.clear.frame(width: safeAreaInset) }
        .frame(minWidth: dynamicNotch.notchSize.width)
    }
}

/// The glass material on macOS 26; nothing older than that.
struct GlassBackdrop: View {
    var body: some View {
        if #available(macOS 26.0, *) {
            Rectangle()
                .fill(.clear)
                .glassEffect(.regular, in: .rect)
        } else {
            EmptyView()
        }
    }
}
