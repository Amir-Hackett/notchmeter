import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// What the window was opened for, kept where the view can watch it: the banner over the controls shows only for
/// a card the app offered by itself after an update (ShareCardOffer), and goes with the setting it offers to turn off.
@MainActor
@Observable
final class ShareCardSession {
    var offered = false
    /// What the last Save, Copy or Share had to say, under the buttons.
    var message: String?
}

/// The studio the usage card is made in: the choices down the left, the card at actual size on the right, and the
/// four ways out under the choices. Every choice is a preference (Preferences.shareCard*), so the card opens as it
/// was last made and the preview redraws as each one changes.
///
/// The preview is the real `ShareCardView`, laid out at the format's own size in points and scaled by the display's
/// backing factor, so a 1200-pixel card is 1200 pixels on screen: what Save PNG writes, what Copy image puts on the
/// pasteboard and what the share sheet hands on are the same pixels, drawn once more by `ShareCardRenderer` at
/// one pixel a point. It takes no clicks and VoiceOver reads it as one element whose value is the caption, which
/// is the card in words.
struct ShareCardStudio: View {
    let store: UsageStore
    let prefs: Preferences
    let session: ShareCardSession
    let hostWindow: () -> NSWindow?

    var body: some View {
        let input = store.shareCardInput()
        let content = ShareCard.content(input)
        HStack(alignment: .top, spacing: 0) {
            controls(input: input, content: content)
                .frame(width: 320)
            Divider()
            preview(content: content)
        }
    }

    // MARK: - Choices

    private func controls(input: ShareCard.Input, content: ShareCardContent) -> some View {
        Form {
            if session.offered, prefs.offerShareCardAfterUpdate {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L("New in %1$@ %2$@: your usage as a card to share.", AppInfo.name, AppInfo.version))
                            .font(.callout.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        Text(L("It opened by itself this once, after the update. It never carries a project, a prompt or a session title."))
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(L("Don't offer after updates")) { prefs.offerShareCardAfterUpdate = false }
                            .controlSize(.small)
                    }
                }
            }
            Section(L("Card")) {
                Picker(L("Metric"), selection: Binding(get: { prefs.shareCardMetric }, set: { prefs.shareCardMetric = $0 })) {
                    ForEach(ShareCardMetric.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker(L("Range"), selection: Binding(get: { prefs.shareCardRange }, set: { prefs.shareCardRange = $0 })) {
                    ForEach(ShareCardRange.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                assistants(input: input)
            }
            Section(L("Look")) {
                Picker(L("Format"), selection: Binding(get: { prefs.shareCardFormat }, set: { prefs.shareCardFormat = $0 })) {
                    ForEach(ShareCardFormat.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                // The theme follows the metric until one is picked by hand (Preferences.shareCardTheme), and the
                // link under the row is the way back to following it.
                Picker(L("Theme"), selection: Binding(get: { prefs.shareCardThemeShown }, set: { prefs.shareCardTheme = $0 })) {
                    ForEach(ShareCardTheme.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                if prefs.shareCardTheme != nil {
                    Button(L("Match the metric")) { prefs.shareCardTheme = nil }
                        .buttonStyle(.link).controlSize(.small)
                        .help(L("Money on black, tokens on blue, until a theme is chosen here."))
                }
                TextField(L("Signature"), text: Binding(get: { prefs.shareCardSignature },
                                                        set: { prefs.shareCardSignature = String($0.prefix(ShareCard.signatureLimit)) }),
                          prompt: Text(L("Your name or handle, optional")))
                    .help(L("One line under the figures, at most %ld characters. Left empty, the card carries none.", ShareCard.signatureLimit))
            }
            Section {
                actions(content: content)
            } footer: {
                Text(L("The card carries totals, the plan's published price, one line about a limit window and the signature above. Never a project name, a prompt or a session title."))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    /// One checkbox per assistant with a figure to carry, in the panel's order; unticked ones are remembered as
    /// left off (Preferences.shareCardHidden), so an assistant that starts reporting joins the next card.
    @ViewBuilder
    private func assistants(input: ShareCard.Input) -> some View {
        let available = ShareCard.available(providers: input.providers, order: input.order)
        if available.isEmpty {
            LabeledContent(L("Assistants")) {
                Text(L("No assistant has reported spend yet")).foregroundStyle(.secondary)
            }
        } else {
            LabeledContent(L("Assistants")) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(available, id: \.self) { tool in
                        Toggle(isOn: Binding(get: { !prefs.shareCardHidden.contains(tool) },
                                             set: { if $0 { prefs.shareCardHidden.remove(tool) } else { prefs.shareCardHidden.insert(tool) } })) {
                            Text(verbatim: tool.displayName)
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }
        }
    }

    // MARK: - Ways out

    /// Share through the system sheet, save a PNG, or copy the picture or its caption. Each draws the card afresh
    /// at one pixel a point (ShareCardRenderer), so what leaves is what the preview shows. Nothing leaves while the
    /// figures are hidden for a screen share: the buttons are there, disabled, with the preview's own note saying why.
    private func actions(content: ShareCardContent) -> some View {
        let disabled = content.isEmpty || store.hidesFigures
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                ShareSheetButton(title: L("Share…"), enabled: !disabled) { shareItems(content) }
                Button(L("Save PNG…")) { save(content) }
                    .disabled(disabled)
            }
            HStack {
                Button(L("Copy image")) { copyImage(content) }
                    .disabled(disabled)
                Button(L("Copy caption")) { copyCaption(content) }
                    .disabled(disabled)
            }
            if let message = session.message {
                Text(message).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var format: ShareCardFormat { prefs.shareCardFormat }
    private var theme: ShareCardTheme { prefs.shareCardThemeShown }

    /// The PNG on disk for the share sheet: a file rather than an image object, because AirDrop and Mail take a
    /// file and every other service takes one too, where an image object is refused by some. Written afresh each
    /// time under a fixed name in the temporary folder, so nothing accumulates.
    private func shareItems(_ content: ShareCardContent) -> [Any] {
        guard let image = ShareCardRenderer.image(content, format: format, theme: theme), let data = ShareCardRenderer.png(image) else {
            session.message = L("The card could not be drawn.")
            return []
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(ShareCard.fileName(range: content.range, format: format))
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            session.message = error.localizedDescription
            return []
        }
        Oracle.shared.emit("shareCard", ["action": "shareSheet", "format": format.rawValue, "theme": theme.rawValue, "metric": content.metric.rawValue])
        return [url]
    }

    private func save(_ content: ShareCardContent) {
        guard let image = ShareCardRenderer.image(content, format: format, theme: theme), let data = ShareCardRenderer.png(image) else {
            session.message = L("The card could not be drawn.")
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = ShareCard.fileName(range: content.range, format: format)
        panel.canSelectHiddenExtension = true
        let format = format, theme = theme
        NSApp.activate()
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do {
                    try data.write(to: url, options: .atomic)
                    session.message = L("Saved %@.", url.lastPathComponent)
                    Oracle.shared.emit("shareCard", ["action": "saved", "format": format.rawValue, "theme": theme.rawValue, "metric": content.metric.rawValue])
                } catch {
                    session.message = error.localizedDescription
                }
            }
        }
    }

    private func copyImage(_ content: ShareCardContent) {
        guard let image = ShareCardRenderer.image(content, format: format, theme: theme) else {
            session.message = L("The card could not be drawn.")
            return
        }
        // Sized in pixels, so the pasteboard holds the 1200-wide picture rather than a 600-point one at 2x.
        let picture = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([picture])
        session.message = L("Copied the card.")
        Oracle.shared.emit("clipboard", ["kind": "shareCard", "width": image.width, "height": image.height])
    }

    private func copyCaption(_ content: ShareCardContent) {
        let caption = content.caption(calendar: .current)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(caption, forType: .string)
        session.message = L("Copied the caption.")
        Oracle.shared.emit("clipboard", ["kind": "caption", "lines": caption.split(separator: "\n").count])
    }

    // MARK: - The card

    /// The display's pixels per point: a 1200-pixel card is 600 points wide on a Retina display, and that is the
    /// size it is drawn at, so what the eye sees is what the file holds.
    private var pixelsPerPoint: CGFloat {
        hostWindow()?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    private func preview(content: ShareCardContent) -> some View {
        let scale = pixelsPerPoint
        let size = format.size
        return ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(L("Preview at actual size")).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(verbatim: "\(format.pixels.width) × \(format.pixels.height) px").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
                .frame(width: size.width / scale)
                if store.hidesFigures {
                    note(L("Figures are hidden while the screen is shared; the card is here once it ends."), size: size, scale: scale)
                } else if content.nothingTicked {
                    // Empty by choice, not by the span (ShareCardContent.nothingTicked): the card's own line would
                    // say nothing was recorded, and the buttons under the checkboxes have just gone grey.
                    note(L("No assistant is ticked; tick one under Assistants to draw the card."), size: size, scale: scale)
                } else {
                    ShareCardView(content: content, format: format, theme: theme)
                        .scaleEffect(1 / scale, anchor: .topLeading)
                        .frame(width: size.width / scale, height: size.height / scale, alignment: .topLeading)
                        .clipped()
                        // A white card on a light window has no edge of its own; a hairline gives it one on every ground.
                        .overlay(Rectangle().strokeBorder(.separator, lineWidth: 1))
                        .allowsHitTesting(false)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(L("Usage card preview"))
                        .accessibilityValue(content.caption(calendar: .current))
                }
            }
            .padding(20)
        }
    }

    /// The card's place with a line of words in it, while there is no card to draw.
    private func note(_ text: String, size: CGSize, scale: CGFloat) -> some View {
        Text(text)
            .font(.callout).foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
            .frame(width: size.width / scale, height: size.height / scale)
            .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
    }
}

/// The share sheet's button, an AppKit one so the picker can be anchored to its own frame: `NSSharingServicePicker`
/// opens relative to a view, and a SwiftUI button has none to give it. The items are made when the button is
/// pressed, not before, since drawing the card is the expensive part.
struct ShareSheetButton: NSViewRepresentable {
    let title: String
    let enabled: Bool
    let items: () -> [Any]

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: title, target: context.coordinator, action: #selector(Coordinator.share(_:)))
        button.bezelStyle = .rounded
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        button.title = title
        button.isEnabled = enabled
        context.coordinator.items = items
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(items: items)
    }

    /// Not main-actor isolated, the way `UpdateSession` is not: the picker's and the service's delegate calls
    /// arrive on the main thread and are stepped onto the actor where they need it, which language mode 5 lets a
    /// plain NSObject do.
    final class Coordinator: NSObject, NSSharingServicePickerDelegate, NSSharingServiceDelegate {
        var items: () -> [Any]
        /// The sheet on screen, held for as long as it is: the picker keeps no reference to itself.
        private var picker: NSSharingServicePicker?
        /// The button the picker opened from, for the window the chosen service's own UI belongs to.
        private weak var anchor: NSView?

        init(items: @escaping () -> [Any]) {
            self.items = items
        }

        @objc func share(_ sender: NSButton) {
            MainActor.assumeIsolated {
                let list = items()
                guard !list.isEmpty else { return }
                anchor = sender
                let picker = NSSharingServicePicker(items: list)
                picker.delegate = self
                self.picker = picker
                picker.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            }
        }

        func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
            // The service's own name only: which app the card went to, never what was in it.
            Oracle.shared.emit("shareCard", ["action": "shared", "service": service?.title ?? "none"])
            picker = nil
        }

        /// The chosen service asks its delegate, this one, which window it is sharing from (below).
        func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, delegateFor sharingService: NSSharingService) -> NSSharingServiceDelegate? {
            self
        }

        /// The studio is the window the card leaves from, so a service with a compose window of its own (Messages,
        /// Notes, Reminders, AirDrop's list of who is near) attaches it to the studio as a sheet, at the studio's
        /// own level. Left unanswered, the service opens an ordinary window of its own in the middle of the screen,
        /// under the studio: it sits a level above the notch panel (ShareCardWindowController.present) and spans
        /// most of a laptop's display, so from outside nothing would seem to have happened.
        func sharingService(_ sharingService: NSSharingService, sourceWindowForShareItems items: [Any],
                            sharingContentScope: UnsafeMutablePointer<NSSharingService.SharingContentScope>) -> NSWindow? {
            MainActor.assumeIsolated { anchor?.window }
        }
    }
}

/// The studio's window: the same non-activating panel as Settings and the dashboard, raised above the notch panel
/// and placed the same way (SettingsWindowController.frame), sized to the screen it opens on so a story card's
/// preview scrolls rather than the window running off the bottom.
@MainActor
final class ShareCardWindowController: NSWindowController {
    nonisolated static let contentSize = NSSize(width: 1000, height: 860)

    private let prefs: Preferences
    private let session = ShareCardSession()
    private var panelLevel: NSWindow.Level?
    private var aside = false

    init(store: UsageStore, prefs: Preferences) {
        self.prefs = prefs
        let panel = SettingsPanel(contentRect: NSRect(origin: .zero, size: Self.contentSize),
                                  styleMask: [.titled, .closable, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        let host = FirstMouseHostingView(rootView: ShareCardStudio(store: store, prefs: prefs, session: session, hostWindow: { [weak panel] in panel }))
        host.sizingOptions = []
        panel.title = L("Share usage card")
        panel.contentView = host
        panel.setContentSize(Self.contentSize)
        panel.contentMinSize = NSSize(width: 760, height: 520)
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        panel.wearCloseOnly()
        super.init(window: panel)
        followAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not supported")
    }

    /// The Appearance picker in Settings applies here as it does to the dashboard, while the window is open.
    private func followAppearance() {
        withObservationTracking {
            window?.appearance = prefs.appearance.nsAppearance
        } onChange: { [weak self] in
            Task { @MainActor in self?.followAppearance() }
        }
    }

    /// `cause` is what the banner reads: a card the app offered after an update says so and offers the off
    /// switch; one the reader asked for does not. `aside` is whether an update session or an alert is up as the
    /// window opens (DashboardWindowController.present says why).
    ///
    /// A card the reader asked for is made key, as Settings and the dashboard are. The offer's is only ordered
    /// front: it arrives at a moment nobody chose, twenty seconds after launch or on a poll after a full-screen
    /// app was left, and this panel takes keystrokes without the app activating (SettingsPanel.canBecomeKey), so
    /// made key it would take the next words typed in a terminal into the Signature field or a picker. The
    /// first click on it makes it key, as on any panel, and FirstMouseHostingView lets that click act.
    func present(on screen: NSScreen, below readouts: CGRect? = nil, above panelLevel: NSWindow.Level? = nil, aside: Bool? = nil,
                 cause: ShareCardCause) {
        guard let window else { return }
        session.offered = cause == .offer
        session.message = nil
        if let aside { self.aside = aside }
        if let panelLevel {
            self.panelLevel = panelLevel
        }
        window.level = self.aside ? .normal : (self.panelLevel.map(SettingsWindowController.level(above:)) ?? .floating)
        if !window.isVisible {
            let visible = screen.visibleFrame
            let size = NSSize(width: min(Self.contentSize.width, visible.width - 40), height: min(Self.contentSize.height, visible.height - 40))
            window.setContentSize(size)
            window.setFrame(SettingsWindowController.frame(for: window.frame.size, screen: screen.frame, safeAreaTop: screen.safeAreaInsets.top,
                                                           visible: visible, readouts: readouts), display: false)
        }
        if cause == .offer {
            window.orderFrontRegardless()
        } else {
            showWindow(nil)
            window.makeKeyAndOrderFront(nil)
        }
    }

    func standAside(_ aside: Bool) {
        self.aside = aside
        guard let window else { return }
        window.level = aside ? .normal : (panelLevel.map(SettingsWindowController.level(above:)) ?? .floating)
    }
}
