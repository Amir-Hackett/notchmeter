import AppKit
import SwiftUI

/// The Welcome tour's four steps, in the order a new user meets the things they name: the rings beside the notch,
/// the panel they open onto, the sessions the hook reports into it, and the hook itself.
///
/// The permissions the old three-step Welcome listed on a page of their own now sit on the step whose feature asks
/// for them — the Keychain and Accessibility beside the rings they feed, Automation beside the session rows that
/// jump to a terminal — because a permission read next to the thing it buys is one the reader can weigh, and one
/// read on a list of three is one they skim.
enum WelcomeStep: Int, CaseIterable, Sendable {
    case rings, panel, sessions, connect

    /// One-based, for the "Step 2 of 4" VoiceOver reads on the dots and the oracle writes.
    var number: Int { rawValue + 1 }

    /// The name the oracle writes, stable across languages.
    var name: String {
        switch self {
        case .rings: "rings"
        case .panel: "panel"
        case .sessions: "sessions"
        case .connect: "connect"
        }
    }

    var title: String {
        switch self {
        case .rings: L("The rings beside the notch")
        case .panel: L("The panel, and pace")
        case .sessions: L("Sessions, answered from the notch")
        case .connect: L("Connect Claude Code")
        }
    }
}

/// Where the tour is and where a key or a button takes it. Pure, so the tests can walk it without a window.
///
/// Two ways forward and they differ on the last step on purpose. Next, Return and the dots are deliberate, and on the
/// last step Next has become Done, so Return there closes the tour. The right arrow is the key a reader leans on to
/// flick through, and a flick that ran off the end would close the window on someone who only wanted to see whether
/// there was a fifth page — so it stops.
struct WelcomeTour: Equatable, Sendable {
    enum Key: Sendable { case left, right, enter, escape }

    enum Outcome: Equatable, Sendable {
        /// Nothing to do: Back on the first step, the right arrow on the last, a dot for the step already shown.
        case stayed
        case moved(WelcomeStep)
        /// Done, Return on the last step, or Escape: the window closes.
        case finished
    }

    private(set) var step: WelcomeStep
    /// Which way the last move went, so a slide comes in from the side the reader is heading towards.
    private(set) var forward = true

    init(step: WelcomeStep = .rings) {
        self.step = step
    }

    static let count = WelcomeStep.allCases.count

    var isFirst: Bool { step.rawValue == 0 }
    var isLast: Bool { step.rawValue == Self.count - 1 }

    mutating func back() -> Outcome {
        go(to: WelcomeStep(rawValue: step.rawValue - 1))
    }

    /// The right arrow: one step on, and nowhere past the last.
    mutating func next() -> Outcome {
        go(to: WelcomeStep(rawValue: step.rawValue + 1))
    }

    /// Next, Done and Return: one step on, and on the last step the end of the tour.
    mutating func advance() -> Outcome {
        isLast ? .finished : next()
    }

    mutating func go(to target: WelcomeStep?) -> Outcome {
        guard let target, target != step else { return .stayed }
        forward = target.rawValue > step.rawValue
        step = target
        return .moved(target)
    }

    mutating func press(_ key: Key) -> Outcome {
        switch key {
        case .left: back()
        case .right: next()
        case .enter: advance()
        case .escape: .finished
        }
    }

    /// The oracle's line for a step shown or the tour closed on one (docs/testing.md).
    static func oracleFields(_ action: String, step: WelcomeStep?) -> [String: Any] {
        ["action": action, "step": step?.name as Any, "index": step?.number as Any, "count": count]
    }
}

/// The stores the tour's previews draw from: the demo fixtures `--render-assets` draws the README from, one per
/// moment a step shows. They are the real views over the real store, fed by replayed hook events, so a change to
/// a card changes the tour with it and a state the app cannot reach cannot be shown in it.
///
/// Every preference a store needs is read while it is built, so the suite is emptied as soon as the last one is
/// up: a tour opened from Settings leaves nothing behind under ~/Library/Preferences. Nothing here is the user's —
/// no reading, no session, no prompt text — which is why the previews stay up while the screen is shared, where
/// the panel hides its figures, and why they carry a "Sample data" label, so nobody reads them as their own.
@MainActor
struct WelcomePreviews {
    /// A turn running and nothing asked: no mark on any ring.
    let working: UsageStore
    /// A permission request held open, for the Sessions step.
    let asking: UsageStore
    /// The two signals the hook lights, for the last step.
    let waiting: UsageStore
    let finished: UsageStore

    init(now: Date = Date()) {
        let suite = DemoFixtures.previewSuiteName
        working = DemoFixtures.store(now: now, moment: .working, suite: suite).store
        asking = DemoFixtures.store(now: now, moment: .permissionRequest, suite: suite).store
        waiting = DemoFixtures.store(now: now, moment: .waiting, suite: suite).store
        finished = DemoFixtures.store(now: now, moment: .justFinished, suite: suite).store
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }
}

/// The first-launch Welcome, and the tour Settings can show again: four steps, each a live preview of the real
/// views over sample data with a few lines on what it shows, and what the app reads and never sends folded into
/// the step it belongs to. Shown once at first launch (`Preferences.welcomed`), skippable at every step, and
/// reopened from Settings › General.
///
/// It took over the hook offer's slot at launch: a copy that has never seen either gets this, whose last step is
/// that offer with the status line beside it; a copy set up before it existed is marked welcomed without being
/// shown it, because it has nothing left to be told.
///
/// Every install goes through `SettingsRequests` and lands in the Settings window, whose hook sheet already
/// backs the file up first and reads the result back: the Welcome asks, Settings does, and there is one
/// installer rather than two.
///
/// Keys: ← and → move a step, Return is Next (and Done on the last step), Escape closes (SettingsPanel). The
/// arrows are shortcuts on buttons rather than a key handler, because in a panel that never activates the app,
/// focus is not something a view can count on having.
struct WelcomeView: View {
    /// Opens Settings on Integrations with the hook offer and the status line install queued (AppDelegate).
    let install: () -> Void
    /// Closes the window, whether by Skip, Done or Escape.
    let finish: () -> Void
    /// A step came on screen, including the first; the controller writes it to the oracle.
    var onStep: (WelcomeStep) -> Void = { _ in }
    /// Claude Code's hook and status line are both already in, so the last step says so above the button.
    var connected = false
    @State private var tour: WelcomeTour
    @State private var previews: WelcomePreviews

    static let steps = WelcomeTour.count
    static let size: CGSize = WelcomeWindowController.contentSize
    /// The black stage every preview is drawn on: the window's width less its padding.
    static let stageWidth: CGFloat = size.width - 40

    @MainActor
    init(start: WelcomeStep = .rings, previews: WelcomePreviews? = nil, connected: Bool = false,
         install: @escaping () -> Void, finish: @escaping () -> Void, onStep: @escaping (WelcomeStep) -> Void = { _ in }) {
        self.install = install
        self.finish = finish
        self.onStep = onStep
        self.connected = connected
        _tour = State(initialValue: WelcomeTour(step: start))
        _previews = State(initialValue: previews ?? WelcomePreviews())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Welcome to %@", AppInfo.name))
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            page(tour.step)
                .id(tour.step)
                .transition(transition)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
            footer
        }
        .padding(20)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .background {
            // The right arrow's shortcut: Next already answers Return, and a button takes one shortcut.
            Button { move { $0.press(.right) } } label: { EmptyView() }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .onAppear { onStep(tour.step) }
    }

    /// A slide from the side the reader is heading towards; under Reduce Motion the page is simply replaced, with
    /// no animation at all (`move`).
    private var transition: AnyTransition {
        guard !AccessibilityDisplay.shared.motionReduced else { return .identity }
        let forward = tour.forward
        return .asymmetric(insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                           removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity))
    }

    private func move(_ change: (inout WelcomeTour) -> WelcomeTour.Outcome) {
        var outcome = WelcomeTour.Outcome.stayed
        withAnimation(AccessibilityDisplay.shared.motionReduced ? nil : .easeInOut(duration: 0.25)) {
            outcome = change(&tour)
        }
        switch outcome {
        case .stayed: break
        case .moved(let step): onStep(step)
        case .finished: finish()
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Button(L("Back")) { move { $0.press(.left) } }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(tour.isFirst)
            Spacer()
            if !tour.isLast {
                Button(L("Skip")) { finish() }
                    .buttonStyle(.link)
                    .keyboardShortcut(.cancelAction)
            }
            Button(tour.isLast ? L("Done") : L("Next")) { move { $0.press(.enter) } }
                .keyboardShortcut(.defaultAction)
        }
        .controlSize(.large)
        .overlay { StepDots(current: tour.step) { step in move { $0.go(to: step) } } }
    }

    // MARK: - The four steps

    private func page(_ step: WelcomeStep) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            PreviewStage(title: step.title, height: Self.stageHeight(step), largest: step == .rings ? 2 : step == .connect ? 1.6 : 1) {
                preview(step)
            }
            Text(step.title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
                .padding(.top, 4)
            Text(summary(step))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            details(step)
        }
    }

    /// The strips are short and the cards tall; the words below take whatever each step's stage leaves.
    static func stageHeight(_ step: WelcomeStep) -> CGFloat {
        switch step {
        case .rings: 130
        case .panel, .sessions: 250
        case .connect: 190
        }
    }

    private func summary(_ step: WelcomeStep) -> String {
        switch step {
        case .rings:
            L("Each assistant has a nest of rings in its own colour: the outer ring is its main limit, the rings inside it are its other windows, and each arc fills as that window is used. A dashed ring has nothing to read yet. Hover the rings to open the panel.")
        case .panel:
            L("The panel has a card for each assistant with every window, when it resets and what it has cost. Pace compares how fast a window is being used with the time it has left, so the warning comes while there is still time to slow down, long before the window is full.")
        case .sessions:
            L("With the hook in, the panel lists your Claude Code sessions and what each one is doing. When one asks for permission or puts a question to you, answer it here; leave it, and it goes back to the terminal.")
        case .connect:
            L("One entry in ~/.claude/settings.json lets Claude Code tell the notch when a session starts, a turn ends or it waits for you, and a status line hands over the context fill and the official limits after every turn. Both are backed up first; Settings › Integrations can repair or remove them later.")
        }
    }

    @ViewBuilder private func preview(_ step: WelcomeStep) -> some View {
        switch step {
        case .rings:
            CompactStripPreview(store: previews.working)
        case .panel:
            PanelColumn(store: previews.working) {
                ToolCard(tool: .claude, status: previews.working.status(.claude), store: previews.working, prefs: previews.working.prefs)
            }
        case .sessions:
            HStack(alignment: .top, spacing: 18) {
                PanelColumn(store: previews.asking) {
                    SessionsCard(store: previews.asking, prefs: previews.asking.prefs, actions: NotchActions())
                }
                if let newest = previews.asking.sessions.pending(now: Date()).first {
                    // Answering here would answer nothing: the request is a fixture, and the card's own shortcuts
                    // (⌘Y, ⌘N) stay live in this window, so the decision goes nowhere.
                    PanelColumn(store: previews.asking) {
                        PromptCard(session: newest.session, request: newest.request)
                    }
                }
            }
        case .connect:
            VStack(alignment: .leading, spacing: 12) {
                signalRow(previews.waiting, .waiting(count: 1))
                signalRow(previews.finished, .finished(turn: 0))
            }
        }
    }

    /// One strip and the words for the mark on it. The words are the card's own (`ToolSignal.cardText`) and the
    /// symbol the card's, so the step teaches the vocabulary the panel will use.
    private func signalRow(_ store: UsageStore, _ signal: ToolSignal) -> some View {
        HStack(spacing: 14) {
            CompactStripPreview(store: store)
            Label(signal.cardText, systemImage: signal.symbolName)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
        }
    }

    @ViewBuilder private func details(_ step: WelcomeStep) -> some View {
        switch step {
        case .rings:
            VStack(alignment: .leading, spacing: 8) {
                permission("lock.shield.fill", L("What %@ reads", AppInfo.name),
                           L("It reads the usage each assistant already keeps on this Mac — Claude Code, Codex, Cursor, Gemini CLI and GitHub Copilot — and asks each vendor's usage endpoint over the login that tool saved. It never signs in, keeps no token, and sends nothing anywhere else: no account, no analytics."))
                permission("key.fill", L("Keychain"),
                           L("To read Claude Code's saved login, once. Choose Always Allow so it stays quiet; the timed reads never raise the dialog."))
                permission("accessibility", L("Accessibility"),
                           L("Only if you pick Readouts › Auto, which shifts the readouts clear of the frontmost app's menu titles. It reads the menu bar's geometry and nothing else."))
            }
        case .panel:
            VStack(alignment: .leading, spacing: 8) {
                paceRow(.onTrack, fraction: 0.55, L("Cutting it close (on track)"))
                paceRow(.behind, fraction: 0.72, L("Will run out (behind pace)"))
            }
        case .sessions:
            permission("arrow.up.forward.app.fill", L("Automation"),
                       L("Only to jump to a session's terminal window, the first time you do. Nothing else in the app drives another app."))
        case .connect:
            VStack(alignment: .leading, spacing: 10) {
                if connected {
                    Label(L("The hook and the status line are both installed."), systemImage: "checkmark.circle.fill")
                        .font(.callout)
                }
                Button(L("Install the hook and status line…")) { install() }
                    .controlSize(.large)
            }
        }
    }

    /// A pace state as the ring draws it — the real `RingView`, on a scrap of the notch's black, with the cap that
    /// carries it — beside the symbol and the words the card prints for it. Three channels, so none of them is
    /// colour alone.
    private func paceRow(_ pace: Pace.Status, fraction: Double, _ text: String) -> some View {
        HStack(spacing: 10) {
            RingView(fraction: fraction, color: ToolID.claude.color, lineWidth: 2.5, pace: pace)
                .frame(width: 18, height: 18)
                .padding(5)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.black))
                .accessibilityHidden(true)
            if let symbol = pace.symbolName {
                Image(systemName: symbol)
                    .foregroundStyle(pace.noteColor)
                    .frame(width: 16)
                    .accessibilityHidden(true)
            }
            Text(text).font(.callout)
        }
        .accessibilityElement(children: .combine)
    }

    private func permission(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The dots under the tour: one per step, the current one drawn as a wider bar so where the reader is does not rest
/// on colour, and each a button with a 24-point target that goes straight to its step.
private struct StepDots: View {
    let current: WelcomeStep
    let select: (WelcomeStep) -> Void

    var body: some View {
        let contrast = AccessibilityDisplay.shared.contrast
        HStack(spacing: 0) {
            ForEach(WelcomeStep.allCases, id: \.self) { step in
                let here = step == current
                Button { select(step) } label: {
                    Capsule()
                        .fill(here ? (contrast ? AnyShapeStyle(.primary) : AnyShapeStyle(Palette.accent))
                                   : AnyShapeStyle(contrast ? .secondary : .tertiary))
                        .frame(width: here ? 18 : 7, height: 7)
                        .frame(width: 26, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("Step %1$ld of %2$ld", step.number, WelcomeTour.count))
                .accessibilityValue(step.title)
                .accessibilityAddTraits(here ? .isSelected : [])
            }
        }
    }
}

/// The black the notch is drawn in, with a preview laid out at its own size and scaled into the room the step
/// gives it. The preview is a picture rather than a panel: it takes no clicks, and VoiceOver reads it as one element
/// named for the step rather than walking a fixture's buttons as if they would do something.
private struct PreviewStage<Content: View>: View {
    let title: String
    let height: CGFloat
    /// How far a short preview may be enlarged: the strips are drawn at twice their size or so, the cards never.
    var largest: CGFloat = 1
    @ViewBuilder let content: Content
    @State private var natural: CGSize = .zero

    static var inset: CGFloat { 14 }
    /// Room above the preview for the label, so the two never overlap.
    static var labelRoom: CGFloat { 26 }

    var body: some View {
        let contrast = AccessibilityDisplay.shared.contrast
        let room = CGSize(width: WelcomeView.stageWidth - 2 * Self.inset, height: height - Self.labelRoom - Self.inset)
        let scale = PreviewScale.fit(natural, in: room, largest: largest)
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        content
            .fixedSize()
            .onGeometryChange(for: CGSize.self) { $0.size } action: { natural = $0 }
            .scaleEffect(scale)
            .frame(width: room.width, height: room.height)
            .padding(.top, Self.labelRoom)
            .padding([.horizontal, .bottom], Self.inset)
            .frame(width: WelcomeView.stageWidth, height: height)
            .foregroundStyle(.white)
            .environment(\.colorScheme, .dark)
            .environment(\.density, .comfortable)
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            .background(shape.fill(Color.black))
            .overlay(shape.strokeBorder(.white.opacity(contrast ? 0.4 : 0.12)))
            .overlay(alignment: .topLeading) {
                Chip(text: L("Sample data"))
                    .foregroundStyle(.white.opacity(contrast ? 1 : 0.8))
                    .padding(10)
            }
            .clipShape(shape)
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L("Sample data"))
            .accessibilityValue(title)
    }
}

/// How much a preview is scaled to sit inside its stage. Pure so the tests can pin it: nothing is scaled before
/// it has been measured, a preview that is too big comes down to fit both ways, and one that is small grows no
/// further than `largest`, because a strip of 14-point rings is unreadable at its own size in a stage 580 wide
/// and a card drawn larger than the panel draws it would be a picture of something the app never shows.
enum PreviewScale {
    static func fit(_ natural: CGSize, in room: CGSize, largest: CGFloat) -> CGFloat {
        guard natural.width > 0, natural.height > 0, room.width > 0, room.height > 0 else { return 1 }
        return min(largest, room.width / natural.width, room.height / natural.height)
    }
}

/// A card at the width the panel gives its cards, so a preview wraps its lines where the panel would.
private struct PanelColumn<Content: View>: View {
    let store: UsageStore
    @ViewBuilder let content: Content

    var body: some View {
        content.frame(width: store.prefs.panelWidth.points - 2 * NotchExpandedView.contentHorizontalPadding, alignment: .leading)
    }
}

/// The compact strip as it sits around the notch: the leading and trailing readouts, the hardware notch between
/// them, and the black shape that holds all three, hanging from a scrap of menu bar over a scrap of desktop. The
/// notch is black and so is the stage, so without the bar behind it the shape would not read as a notch at all.
/// The notch is drawn narrower than a real one so the readouts, which are what the step is about, get the room.
private struct CompactStripPreview: View {
    let store: UsageStore

    /// The menu bar and desktop tones `AssetRenderer` paints behind the README's pictures of the same strip.
    static let menuBar = Color(red: 0.10, green: 0.11, blue: 0.13)
    static let desktop = Color(red: 0.13, green: 0.14, blue: 0.17)

    var body: some View {
        let shape = UnevenRoundedRectangle(bottomLeadingRadius: 12, bottomTrailingRadius: 12, style: .continuous)
        HStack(spacing: 0) {
            NotchCompactView(store: store, side: .leading)
                .padding(.horizontal, 10)
            Color.black.frame(width: 96)
            NotchCompactView(store: store, side: .trailing)
                .padding(.horizontal, 10)
        }
        .frame(height: 32)
        .background(shape.fill(Color.black))
        .padding(.horizontal, 28)
        .background(Self.menuBar)
        .padding(.bottom, 14)
        .background(Self.desktop)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// The Welcome as a floating, non-activating panel like Settings (SettingsPanel): the app the person was in stays
/// in front, a first click lands on a button, Escape closes it. The panel controller holds the compact state
/// while it is up so the full-height panel never opens over it (PanelHolds.welcome).
@MainActor
final class WelcomeWindowController: NSWindowController {
    nonisolated static let contentSize = NSSize(width: 620, height: 600)

    /// The step on screen, for the oracle's closing line.
    var shownStep: WelcomeStep? { log.last }
    private let log: StepLog

    init(connected: Bool = false, install: @escaping () -> Void, finish: @escaping () -> Void) {
        let panel = SettingsPanel(contentRect: NSRect(origin: .zero, size: Self.contentSize),
                                  styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        let log = StepLog()
        self.log = log
        let host = FirstMouseHostingView(rootView: WelcomeView(connected: connected, install: install, finish: finish,
                                                               onStep: { log.shown($0) }))
        host.sizingOptions = []
        panel.title = L("Welcome to %@", AppInfo.name)
        panel.contentView = host
        panel.setContentSize(Self.contentSize)
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        panel.wearCloseOnly()
        super.init(window: panel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not supported")
    }

    /// Centred under the notch of the given screen, the way Settings is placed, and made key without activating
    /// the app.
    func present(on screen: NSScreen) {
        guard let window else { return }
        window.setFrame(SettingsWindowController.frame(for: window.frame.size, screen: screen.frame, safeAreaTop: screen.safeAreaInsets.top,
                                                       visible: screen.visibleFrame), display: false)
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    /// Each step as it comes on screen, to the oracle: the tour is otherwise invisible to a tester who cannot see
    /// the window.
    @MainActor
    private final class StepLog {
        private(set) var last: WelcomeStep?

        func shown(_ step: WelcomeStep) {
            guard step != last else { return }
            last = step
            Oracle.shared.emit("welcome", WelcomeTour.oracleFields("step", step: step))
        }
    }
}
