import AppKit
import SwiftUI

/// The Send Feedback sheet, over the Settings window (Settings › General › About, the button beside Copy
/// diagnostics, or the Options menu, which opens Settings with the sheet already up).
///
/// Top to bottom it is the whole decision: the message, whether the diagnostics go with it, which way it leaves,
/// and then the text itself, exactly as Send will hand it over, with a line counting what was replaced in it. The
/// preview is not a summary drawn beside the payload; it is the payload's own title and body (Feedback.Payload),
/// so a cut to fit a link is visible before it is sent and not discovered after.
///
/// Send is ⌘↩ rather than ↩, because ↩ in the message is a new line; Tab leaves the message for the checkbox, as
/// it leaves any field in a dialog (FeedbackTextView). The sheet takes no animation of its own, so there is
/// nothing for Reduce Motion to switch off; the system's sheet presentation already follows it.
struct FeedbackView: View {
    let store: UsageStore
    let prefs: Preferences
    /// The diagnostics report, read off the main thread (AppDelegate.diagnosticsOffMain), unredacted: it is
    /// redacted here before anything of it is drawn.
    let diagnostics: () async -> String
    /// How a destination leaves on this Mac (Feedback.liveRoute), a parameter so a render does not ask this Mac.
    let routeFor: (Feedback.Destination) -> Feedback.Route
    /// The names to replace (FeedbackRedaction.gather), asked again whenever the view is drawn, so a session that
    /// starts while the sheet is up is covered too.
    let redaction: () -> FeedbackRedaction
    /// The text was handed over: the line the Settings row shows afterwards.
    let sent: (String) -> Void
    let close: () -> Void
    /// The version line under the message (Feedback.about), fixed when the sheet opens.
    let about: String

    @State private var message: String
    /// The report as it came, before redaction; nil until it has been read.
    @State private var rawReport: String?
    /// The report split and through the redaction, redone when the names change.
    @State private var report: Feedback.Report?
    /// The redaction under way for a change of names, so a second change cancels the first.
    @State private var redacting: Task<Void, Never>?
    @State private var route: Feedback.Route
    @State private var failure: String?
    @State private var copied = false

    /// `about`, `message` and `report` are for `--render-assets`, which draws the sheet filled in, with a report of
    /// its own and a version line that does not change with every developer build; the app passes none of them.
    init(store: UsageStore, prefs: Preferences, diagnostics: @escaping () async -> String,
         routeFor: @escaping (Feedback.Destination) -> Feedback.Route, redaction: @escaping () -> FeedbackRedaction,
         sent: @escaping (String) -> Void, close: @escaping () -> Void, about: String = Feedback.about(), message: String = "",
         report: String? = nil) {
        self.store = store
        self.prefs = prefs
        self.diagnostics = diagnostics
        self.routeFor = routeFor
        self.redaction = redaction
        self.sent = sent
        self.close = close
        self.about = about
        _message = State(initialValue: message)
        _rawReport = State(initialValue: report)
        _report = State(initialValue: report.map { Feedback.Report(redacting: $0, with: redaction()) })
        _route = State(initialValue: routeFor(prefs.feedbackDestination))
    }

    static let width: CGFloat = 580
    /// How long a change of names waits before the report is redacted again: a session posting its task list
    /// changes the names on every item, and one pass at the end serves them all.
    static let redactionDebounce: Duration = .milliseconds(300)

    private var includesDiagnostics: Bool { prefs.feedbackDiagnostics }
    /// The diagnostics carry the readings, and the privacy setting keeps readings off a shared screen; the
    /// preview would put them there, so it waits, and Send with it, since nothing unseen may leave.
    private var hiddenBySharing: Bool { includesDiagnostics && store.hidesFigures }
    private var loading: Bool { includesDiagnostics && report == nil }
    private var names: FeedbackRedaction { redaction() }
    private var redactedMessage: FeedbackRedaction.Result { names.apply(message) }
    private var includedReport: Feedback.Report? { includesDiagnostics ? report : nil }

    private var payload: Feedback.Payload {
        Feedback.payload(message: redactedMessage.text, about: about, report: includedReport, route: route)
    }

    private var replaced: Feedback.Replaced {
        Feedback.Replaced(message: redactedMessage, report: includedReport)
    }

    private var messageIsEmpty: Bool { message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var sendBlock: Feedback.SendBlock? {
        Feedback.sendBlock(messageEmpty: messageIsEmpty, loading: loading, hiddenBySharing: hiddenBySharing)
    }
    private var canSend: Bool { sendBlock == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Send Feedback"))
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text(L("%@ has no server. Send hands what you write to GitHub in your browser or to your own mail app, and nothing is filed or mailed until you send it there. The text under What will be sent is exactly what goes.", AppInfo.name))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            messageField
            HStack(alignment: .firstTextBaseline, spacing: 20) {
                Toggle(L("Include diagnostics"), isOn: Binding(get: { prefs.feedbackDiagnostics }, set: { prefs.feedbackDiagnostics = $0 }))
                    .toggleStyle(.checkbox)
                    .help(L("The same report as Copy diagnostics: the last 10 minutes of this app's log, each assistant's status, the hooks, the layout and the macOS version. Never a token."))
                Picker(L("Send through"), selection: Binding(get: { prefs.feedbackDestination }, set: { prefs.feedbackDestination = $0 })) {
                    ForEach(Feedback.Destination.allCases, id: \.self) { destination in
                        Text(destination.title).tag(destination)
                    }
                }
                .pickerStyle(.radioGroup)
                .horizontalRadioGroupLayout()
                .fixedSize()
            }
            Divider()
            preview
            Text(routeNote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            buttons
        }
        .padding(16)
        .frame(width: Self.width)
        .onAppear {
            Oracle.shared.emit("feedback", Feedback.oracleFields(action: "shown", destination: prefs.feedbackDestination, includesDiagnostics: includesDiagnostics))
        }
        // A preview that changed is not the one Copy put on the clipboard, or the one Send failed to open.
        .onChange(of: message) { _, _ in
            copied = false
            failure = nil
        }
        .onChange(of: prefs.feedbackDestination) { _, destination in
            route = routeFor(destination)
            copied = false
            failure = nil
        }
        .onChange(of: prefs.feedbackDiagnostics) { _, _ in
            copied = false
            failure = nil
        }
        // Read once, when first wanted; unticking and ticking again reuses it.
        .task(id: includesDiagnostics) {
            guard includesDiagnostics, rawReport == nil else { return }
            let text = await diagnostics()
            rawReport = text
            await redact(text, with: names)
        }
        // A name the app learns while the sheet is up (a session starting) is replaced in the report as well.
        .onChange(of: names) { _, fresh in
            guard let rawReport else { return }
            redacting?.cancel()
            redacting = Task {
                try? await Task.sleep(for: Self.redactionDebounce)
                guard !Task.isCancelled else { return }
                await redact(rawReport, with: fresh)
            }
        }
        .onDisappear { redacting?.cancel() }
    }

    /// The report through the names, off the main actor: it is the whole of the last ten minutes of log, and the
    /// pass, quick as it is, has no business between two keystrokes. A pass overtaken by a newer set of names
    /// leaves the newer one to set the report.
    private func redact(_ raw: String, with names: FeedbackRedaction) async {
        let redacted = await Task.detached(priority: .userInitiated) { Feedback.Report(redacting: raw, with: names) }.value
        guard !Task.isCancelled else { return }
        report = redacted
    }

    // MARK: - Parts

    private var messageField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L("Message")).font(.subheadline.weight(.semibold))
            FeedbackEditor(text: $message, label: L("Message"), hint: placeholder)
                .frame(height: 110)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
                .overlay(alignment: .topLeading) {
                    if message.isEmpty {
                        // A placeholder, which a text view has not got. VoiceOver hears the same words as the
                        // field's help, so this is decoration to it.
                        Text(placeholder)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
        }
    }

    private var placeholder: String { L("What happened, and what did you expect? Or what would make it better?") }

    @ViewBuilder private var preview: some View {
        let payload = payload
        VStack(alignment: .leading, spacing: 6) {
            Text(L("What will be sent")).font(.subheadline.weight(.semibold))
            Text(replacedLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if hiddenBySharing {
                Label(sharingNote, systemImage: "eye.slash")
                    .font(.callout)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 2) {
                            GridRow {
                                Text(L("Goes to")).foregroundStyle(.secondary)
                                Text(verbatim: payload.recipient)
                            }
                            GridRow {
                                Text(payload.route == .browser ? L("Title") : L("Subject")).foregroundStyle(.secondary)
                                Text(verbatim: payload.title)
                            }
                        }
                        .font(.caption)
                        Divider()
                        Text(verbatim: payload.body)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if loading {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text(loadingNote).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .textSelection(.enabled)
                    .padding(8)
                }
                .frame(height: 220)
                .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
                .accessibilityLabel(L("What will be sent"))
                if let cutLine = cutLine(payload.cut) {
                    // A symbol and words, in the caption's own colour: the sheet is drawn light as well as dark, and
                    // Palette.warn is 1.9:1 on a light window, under the 3:1 a glyph needs.
                    Label {
                        Text(cutLine)
                    } icon: {
                        Image(systemName: "scissors")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var buttons: some View {
        HStack {
            Button(L("Copy")) { copy() }
                .disabled(loading || hiddenBySharing)
                .help(L("Puts the title and the whole text on the clipboard, not cut to fit a link and with the diagnostics in a code block, for pasting wherever you like."))
            if copied {
                Text(L("Copied.")).font(.caption).foregroundStyle(.secondary)
            }
            if let failure {
                Label {
                    Text(failure).foregroundStyle(.secondary)
                } icon: {
                    // Vermillion rather than the orange: at least 3.3:1 on a light window (#ECECEC) and on a dark sheet
                    // (#323232), where the orange is 1.9:1 on the light one.
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.danger)
                }
                .font(.caption)
            }
            Spacer()
            Button(L("Cancel")) { cancel() }
                .keyboardShortcut(.cancelAction)
            Button(L("Send…")) { send() }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(!canSend)
                .help(sendHelp)
        }
    }

    // MARK: - Copy

    private var replacedLine: String {
        let counts = replaced
        // A label and its count rather than a count and a noun, so one of a kind reads as well as three do.
        return L("Replaced: project names %1$ld · branches %2$ld · session titles %3$ld · other names and paths %4$ld. Your home folder reads ~.",
                 counts.projects, counts.branches, counts.titles, counts.other)
    }

    private var sharingNote: String {
        L("The diagnostics are hidden while the screen is shared or recorded. Untick Include diagnostics, or send once sharing stops.")
    }

    private var loadingNote: String { L("Reading the diagnostics…") }

    /// Send's tooltip names why it is off, when it is (Feedback.sendBlock): the preview's own sentence for a
    /// shared screen and for a report still being read, and the missing message only when that is what is missing.
    private var sendHelp: String {
        switch sendBlock {
        case .hiddenBySharing: sharingNote
        case .loading: loadingNote
        case .emptyMessage: L("Write a message first.")
        case nil: L("Opens the text above where it is going (⌘↩); nothing leaves until you send it there.")
        }
    }

    private func cutLine(_ cut: Feedback.Cut) -> String? {
        switch cut {
        case .none: nil
        case .logLines(let lines): L("Older log lines left out so the text fits in a link: %ld.", lines)
        case .diagnostics: L("The diagnostics are left out so the text fits in a link.")
        case .message: L("The message is cut short so it fits in a link.")
        }
    }

    private var routeNote: String {
        switch route {
        case .browser:
            L("Send opens a new issue on %@ in your browser with this text filled in. GitHub receives the text as the page loads and publishes nothing until you press Submit new issue; a browser not signed in to GitHub goes through its sign-in page first. Issues are public, and filed under your GitHub account.", Feedback.repository)
        case .mailCompose:
            L("Send opens a new message to %@ in Mail with this text filled in. Nothing is sent until you press Send there, from your own address.", Feedback.address)
        case .mailto:
            L("Send opens a new message to %@ in your mail app with this text filled in. Nothing is sent until you press Send there, from your own address.", Feedback.address)
        }
    }

    // MARK: - Actions

    private func copy() {
        let payload = Feedback.clipboard(message: redactedMessage.text, about: about, report: includedReport, route: route)
        Diagnostics.copy(payload.plainText, kind: "feedback")
        copied = true
        Self.announce(L("Copied."), priority: .medium)
        Oracle.shared.emit("feedback", Feedback.oracleFields(action: "copied", destination: prefs.feedbackDestination,
                                                             includesDiagnostics: includesDiagnostics, payload: payload, replaced: replaced))
    }

    private func cancel() {
        Oracle.shared.emit("feedback", Feedback.oracleFields(action: "cancelled", destination: prefs.feedbackDestination, includesDiagnostics: includesDiagnostics))
        close()
    }

    private func send() {
        guard canSend else { return }
        let payload = payload
        guard Feedback.send(payload) else {
            let failure = payload.route == .browser ? L("No browser took the link.") : L("No mail app took the message.")
            self.failure = failure
            Self.announce(failure, priority: .high)
            // The route and the counts, as for a send that went, so a tester can tell a failed hand-over from a
            // sheet still being edited; never the text.
            Oracle.shared.emit("feedback", Feedback.oracleFields(action: "failed", destination: prefs.feedbackDestination,
                                                                 includesDiagnostics: includesDiagnostics, payload: payload))
            return
        }
        Oracle.shared.emit("feedback", Feedback.oracleFields(action: "sent", destination: prefs.feedbackDestination,
                                                             includesDiagnostics: includesDiagnostics, payload: payload, replaced: replaced))
        switch payload.route {
        case .browser: sent(L("Opened in your browser. Nothing is filed until you press Submit new issue there."))
        case .mailCompose, .mailto: sent(L("Opened in your mail app. Nothing is sent until you press Send there."))
        }
        close()
    }

    /// Tells VoiceOver what a sighted person sees appear beside the buttons: "Copied.", or why nothing opened. A
    /// caption that appears is silent to a listener otherwise.
    private static func announce(_ words: String, priority: NSAccessibilityPriorityLevel) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: words, .priority: priority.rawValue])
    }
}

// MARK: - The message field

/// The message field's text view: Tab and Shift-Tab move to the next and previous control instead of typing a
/// tab, which is what a field in a dialog does. A TextEditor, being a text view for prose, types one, and from a
/// field that has the keyboard as the sheet opens that left no way to Include diagnostics, the radio buttons or
/// the buttons but the mouse. Return is still a new line, ⌘↩ is still Send and Escape still Cancel: both reach the
/// window as key equivalents before the text view sees the key. Where the window has no other key view to go to
/// (Full Keyboard Access off, which keeps checkboxes and buttons out of the Tab order), Tab does nothing, as it
/// does in any dialog's one text field.
final class FeedbackTextView: NSTextView {
    override func insertTab(_ sender: Any?) { window?.selectNextKeyView(self) }
    override func insertBacktab(_ sender: Any?) { window?.selectPreviousKeyView(self) }
}

/// A FeedbackTextView in a scroll view, bound to the message. Plain text only, with the automatic quotes and
/// dashes off, since a message quotes paths and code more often than it quotes prose. It takes the keyboard when
/// it appears, being the reason the sheet is open.
struct FeedbackEditor: NSViewRepresentable {
    @Binding var text: String
    /// What VoiceOver calls the field.
    let label: String
    /// What VoiceOver says it is for: the placeholder's words, which the placeholder itself does not carry to it.
    let hint: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        let view = FeedbackTextView(frame: NSRect(origin: .zero, size: scroll.contentSize))
        view.delegate = context.coordinator
        view.isRichText = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.font = NSFont.preferredFont(forTextStyle: .body)
        view.drawsBackground = false
        view.textContainerInset = NSSize(width: 4, height: 6)
        view.minSize = NSSize(width: 0, height: scroll.contentSize.height)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = true
        view.setAccessibilityLabel(label)
        view.setAccessibilityHelp(hint)
        view.string = text
        scroll.documentView = view
        // The view has no window yet; on the next turn of the run loop it does.
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? FeedbackTextView, view.string != text else { return }
        view.string = text
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let text: Binding<String>

        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            text.wrappedValue = view.string
        }
    }
}
