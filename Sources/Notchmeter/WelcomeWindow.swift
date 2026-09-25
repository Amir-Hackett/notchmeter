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
    /// The layout the reader's own panel uses (Preferences.panelMode), so the panel step shows and describes the
    /// panel they will open: Simple's rows by default, the Detailed cards for someone who chose them.
    let panelMode: PanelMode

    init(now: Date = Date(), panelMode: PanelMode = .simple) {
        self.panelMode = panelMode
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
    /// Opens Settings on Claude Code's page with the hook offer and the status line install queued (AppDelegate).
    let install: () -> Void
    /// Closes the window, whether by Skip, Done or Escape.
    let finish: () -> Void
    /// A step came on screen, including the first; the controller writes it to the oracle.
    var onStep: (WelcomeStep) -> Void = { _ in }
    /// Claude Code's hook and status line are both already in, so the last step says so above the button.
    var connected = false
    @State private var tour: WelcomeTour
    @State private var previews: WelcomePreviews
    /// Which way the next slide goes. It trails `tour.forward` by one render on a reversal (`move`), because the
    /// page on its way out leaves with the transition it was last drawn with.
    @State private var heading = true
    /// Each preview's own size, measured before the first frame and kept here rather than on the stage, which
    /// every step rebuilds: a scale worked out a turn after the page arrived would jump in the middle of its slide.
    @State private var natural: [WelcomeStep: CGSize]

    static let steps = WelcomeTour.count
    static let size: CGSize = WelcomeWindowController.contentSize
    /// The black stage every preview is drawn on: the window's width less its padding.
    static let stageWidth: CGFloat = size.width - 40

    @MainActor
    init(start: WelcomeStep = .rings, previews: WelcomePreviews? = nil, panelMode: PanelMode = .simple, connected: Bool = false,
         install: @escaping () -> Void, finish: @escaping () -> Void, onStep: @escaping (WelcomeStep) -> Void = { _ in }) {
        self.install = install
        self.finish = finish
        self.onStep = onStep
        self.connected = connected
        let previews = previews ?? WelcomePreviews(panelMode: panelMode)
        _tour = State(initialValue: WelcomeTour(step: start))
        _previews = State(initialValue: previews)
        _natural = State(initialValue: Dictionary(uniqueKeysWithValues: WelcomeStep.allCases.map { ($0, Self.measure($0, previews: previews)) }))
    }

    /// A preview's size as the stage lays it out, from a host of its own, so the stage has its scale on the frame
    /// it first draws.
    @MainActor
    static func measure(_ step: WelcomeStep, previews: WelcomePreviews) -> CGSize {
        NSHostingView(rootView: preview(step, previews: previews).fixedSize().modifier(StageEnvironment())).fittingSize
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
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

    /// The incoming page eases out as it arrives; the outgoing one eases in and is gone sooner, so the two never
    /// read as one block sliding.
    static let arrival = Animation.easeOut(duration: 0.25)
    static let departure = Animation.easeIn(duration: 0.18)

    /// A slide from the side the reader is heading towards; under Reduce Motion the page is simply replaced, with
    /// no animation at all (`move`).
    private var transition: AnyTransition {
        guard !AccessibilityDisplay.shared.motionReduced else { return .identity }
        return .asymmetric(insertion: .move(edge: heading ? .trailing : .leading).combined(with: .opacity).animation(Self.arrival),
                           removal: .move(edge: heading ? .leading : .trailing).combined(with: .opacity).animation(Self.departure))
    }

    /// Works the move out on a copy first, so a reversal can turn `heading` round in a render of its own and change
    /// the step on the next turn: the page leaving then slides off the side the reader is heading away from.
    private func move(_ change: (inout WelcomeTour) -> WelcomeTour.Outcome) {
        var next = tour
        switch change(&next) {
        case .stayed:
            break
        case .finished:
            finish()
        case .moved(let step):
            let still = AccessibilityDisplay.shared.motionReduced
            let show = {
                withAnimation(still ? nil : Self.arrival) { tour = next }
                onStep(step)
            }
            if still || next.forward == heading {
                show()
            } else {
                heading = next.forward
                DispatchQueue.main.async(execute: show)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
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
        VStack(alignment: .leading, spacing: 12) {
            PreviewStage(title: step.title, height: Self.stageHeight(step), largest: step == .rings ? 2 : step == .connect ? 1.6 : 1,
                         natural: natural[step] ?? .zero, measured: { size in
                             if natural[step] != size { natural[step] = size }
                         }) {
                Self.preview(step, previews: previews)
            }
            Text(step.title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
                .padding(.top, 4)
            Text(Self.summary(step, panelMode: previews.panelMode))
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

    static func summary(_ step: WelcomeStep, panelMode: PanelMode) -> String {
        switch step {
        case .panel where panelMode == .simple:
            L("The panel has a row for each assistant with its most urgent figure; click a row for every window, when it resets and what it has cost. Pace compares how fast a window is being used with the time it has left, so the warning comes while there is still time to slow down, long before the window is full.")
        case .rings:
            L("Each assistant has a nest of rings in its own colour: the outer ring is its main limit, the rings inside it are its other windows, and each arc fills as that window is used. A dashed ring has nothing to read yet. Hover the rings to open the panel.")
        case .panel:
            L("The panel has a card for each assistant with every window, when it resets and what it has cost. Pace compares how fast a window is being used with the time it has left, so the warning comes while there is still time to slow down, long before the window is full.")
        case .sessions:
            L("With the hook in, the panel lists your Claude Code sessions and what each one is doing. When one asks for permission or puts a question to you, answer it here; leave it, and it goes back to the terminal.")
        case .connect:
            L("One entry in ~/.claude/settings.json lets Claude Code tell the notch when a session starts, a turn ends or it waits for you, and a status line hands over the context fill and the official limits after every turn. Both are backed up first; Claude Code's page in Settings can repair or remove them later.")
        }
    }

    @MainActor @ViewBuilder
    static func preview(_ step: WelcomeStep, previews: WelcomePreviews) -> some View {
        switch step {
        case .rings:
            CompactStripPreview(store: previews.working)
        case .panel where previews.panelMode == .simple:
            // The rows as the Simple panel draws them, closed: one figure each, which is what the words above say.
            // Not clickable: opening one here would grow a preview the stage has already scaled.
            PanelColumn(store: previews.working) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(previews.working.visibleTools, id: \.self) { tool in
                        SimpleToolRow(tool: tool, store: previews.working, prefs: previews.working.prefs, actions: NotchActions(), advice: [])
                    }
                }
                .allowsHitTesting(false)
            }
        case .panel:
            PanelColumn(store: previews.working) {
                ToolCard(tool: .claude, status: previews.working.status(.claude), store: previews.working, prefs: previews.working.prefs)
            }
        case .sessions:
            HStack(alignment: .top, spacing: 16) {
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
    @MainActor
    private static func signalRow(_ store: UsageStore, _ signal: ToolSignal) -> some View {
        HStack(spacing: 16) {
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
                           L("It reads the usage each assistant already keeps on this Mac — Claude Code, Codex, Cursor, Gemini CLI, Antigravity, GitHub Copilot and Kimi Code — and asks each vendor's usage endpoint over the login that tool saved. It never signs in, keeps no token, and sends nothing anywhere else: no account, no analytics."))
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
            // With both already in, the button offers only what pressing it does: Settings on Claude Code's page,
            // where they can be repaired or removed. Queuing an install of what is there would queue nothing.
            VStack(alignment: .leading, spacing: 12) {
                if connected {
                    Label(L("The hook and the status line are both installed."), systemImage: "checkmark.circle.fill")
                        .font(.callout)
                }
                Button(connected ? L("Open Claude Code in Settings…") : L("Install the hook and status line…")) { install() }
                    .controlSize(.large)
            }
        }
    }

    /// A pace state as the ring draws it — the real `RingView`, on a scrap of the notch's black, with the cap that
    /// carries it — beside the symbol and the words the card prints for it. Three channels, so none of them is
    /// colour alone.
    private func paceRow(_ pace: Pace.Status, fraction: Double, _ text: String) -> some View {
        HStack(spacing: 8) {
            RingView(fraction: fraction, color: ToolID.claude.color, lineWidth: 2.5, pace: pace)
                .frame(width: 18, height: 18)
                .padding(4)
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
        HStack(alignment: .top, spacing: 12) {
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
/// on colour, and each a button with a 24-point target that goes straight to its step. The others are `.secondary`,
/// not `.tertiary`: they are controls, and tertiary falls under 3:1 on the dark window.
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
                        .fill(here ? (contrast ? AnyShapeStyle(.primary) : AnyShapeStyle(Palette.accent)) : AnyShapeStyle(.secondary))
                        .frame(width: here ? 16 : 8, height: 8)
                        .frame(width: 24, height: 24)
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
///
/// The size it scales from is the view's (`WelcomeView.natural`), measured before the page is drawn; the stage only
/// reports back when a live preview's size really changes, such as a fixture's finish mark running out.
private struct PreviewStage<Content: View>: View {
    let title: String
    let height: CGFloat
    /// How far a short preview may be enlarged: the strips are drawn at twice their size or so, the cards never.
    var largest: CGFloat = 1
    let natural: CGSize
    let measured: (CGSize) -> Void
    @ViewBuilder let content: Content

    static var inset: CGFloat { 12 }
    /// Room above the preview for the label, so the two never overlap.
    static var labelRoom: CGFloat { 24 }

    var body: some View {
        let contrast = AccessibilityDisplay.shared.contrast
        let room = CGSize(width: WelcomeView.stageWidth - 2 * Self.inset, height: height - Self.labelRoom - Self.inset)
        let scale = PreviewScale.fit(natural, in: room, largest: largest)
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        content
            .fixedSize()
            .modifier(StageEnvironment())
            .onGeometryChange(for: CGSize.self) { $0.size } action: { measured($0) }
            .scaleEffect(scale)
            .frame(width: room.width, height: room.height)
            .padding(.top, Self.labelRoom)
            .padding([.horizontal, .bottom], Self.inset)
            .frame(width: WelcomeView.stageWidth, height: height)
            .background(shape.fill(Color.black))
            .overlay(shape.strokeBorder(.white.opacity(contrast ? 0.4 : 0.12)))
            .overlay(alignment: .topLeading) {
                Chip(text: L("Sample data"))
                    .foregroundStyle(.white.opacity(contrast ? 1 : 0.8))
                    .padding(8)
            }
            .clipShape(shape)
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L("Sample data"))
            .accessibilityValue(title)
    }
}

/// What a preview is drawn under, on the stage and in the host that measures it (`WelcomeView.measure`), so the
/// two agree on its size: the notch's dark appearance and white text, the panel's comfortable density, and type
/// no larger than the panel allows.
private struct StageEnvironment: ViewModifier {
    func body(content: Content) -> some View {
        content
            .foregroundStyle(.white)
            .environment(\.colorScheme, .dark)
            .environment(\.density, .comfortable)
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
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

    /// `emit` is the oracle's, and a test's capture: the controller writes a line for each step as it comes on
    /// screen and one when the window closes, whichever way it closes.
    init(connected: Bool = false, panelMode: PanelMode = .simple, install: @escaping () -> Void, finish: @escaping () -> Void,
         emit: @escaping (String, [String: Any]) -> Void = { Oracle.shared.emit($0, $1) }) {
        let panel = SettingsPanel(contentRect: NSRect(origin: .zero, size: Self.contentSize),
                                  styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        let log = StepLog(emit: emit)
        self.log = log
        let host = FirstMouseHostingView(rootView: WelcomeView(panelMode: panelMode, connected: connected, install: install, finish: finish,
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
        // A selector observer goes when the controller does, with nothing to remove by hand.
        NotificationCenter.default.addObserver(self, selector: #selector(windowWillClose(_:)), name: NSWindow.willCloseNotification, object: panel)
    }

    @objc private func windowWillClose(_ notification: Notification) {
        log.closed()
    }

    /// Whether the last step can say Claude Code is already connected: the hook and the status line both in. A
    /// hook that needs repair is not in, so the step still offers the install that repairs it.
    nonisolated static func connected(hook: HookSettings.Status, statusline: HookSettings.Status) -> Bool {
        if case .installed = hook, case .installed = statusline { return true }
        return false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not supported")
    }

    /// Centred under the notch of the given screen, the way Settings is placed, and made key without activating
    /// the app. The step on screen is logged here as well as when the view appears, so a tour brought forward a
    /// second time writes nothing new (`StepLog` drops a repeat).
    func present(on screen: NSScreen) {
        guard let window else { return }
        window.setFrame(SettingsWindowController.frame(for: window.frame.size, screen: screen.frame, safeAreaTop: screen.safeAreaInsets.top,
                                                       visible: screen.visibleFrame), display: false)
        log.shown(log.last ?? .rings)
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    /// Each step as it comes on screen, and the step the window closed on, to the oracle: the tour is otherwise
    /// invisible to a tester who cannot see the window.
    @MainActor
    private final class StepLog {
        private(set) var last: WelcomeStep?
        private let emit: (String, [String: Any]) -> Void

        init(emit: @escaping (String, [String: Any]) -> Void) {
            self.emit = emit
        }

        func shown(_ step: WelcomeStep) {
            guard step != last else { return }
            last = step
            emit("welcome", WelcomeTour.oracleFields("step", step: step))
        }

        func closed() {
            emit("welcome", WelcomeTour.oracleFields("closed", step: last))
        }
    }
}
