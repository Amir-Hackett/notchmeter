import AppKit
import SwiftUI

/// The first-launch Welcome: three short steps — what the app reads and never sends, which permissions it may ask
/// for and why, and the Claude Code hook and status line — shown once (`Preferences.welcomed`) and skippable at
/// every step. It took over the hook offer's slot at launch: a copy that has never seen either gets this, whose
/// last step is that offer with the status line beside it; a copy set up before it existed is marked welcomed
/// without being shown it, because it has nothing left to be told.
///
/// Every install goes through `SettingsRequests` and lands in the Settings window, whose hook sheet already
/// backs the file up first and reads the result back: the Welcome asks, Settings does, and there is one
/// installer rather than two.
struct WelcomeView: View {
    /// Opens Settings on Integrations with the hook offer and the status line install queued (AppDelegate).
    let install: () -> Void
    /// Closes the window, whether by Skip or Done.
    let finish: () -> Void
    @State private var step = 0

    static let steps = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Welcome to %@", AppInfo.name))
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Group {
                switch step {
                case 0: reads
                case 1: permissions
                default: connect
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            HStack {
                Text(L("Step %1$ld of %2$ld", step + 1, Self.steps))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                if step < Self.steps - 1 {
                    Button(L("Skip")) { finish() }
                        .buttonStyle(.link)
                        .font(.callout)
                    Button(L("Continue")) { step += 1 }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(L("Done")) { finish() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 480, height: 340, alignment: .topLeading)
        .animation(AccessibilityDisplay.shared.motionReduced ? nil : .easeInOut(duration: 0.18), value: step)
    }

    // MARK: - The three steps

    private var reads: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("What %@ reads", AppInfo.name)).font(.headline)
            Text(L("It reads the usage each assistant already keeps on this Mac — Claude Code, Codex, Cursor, Gemini CLI and GitHub Copilot — and asks each vendor's usage endpoint over the login that tool saved. It never signs in, keeps no token, and sends nothing anywhere else: no account, no analytics."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("What it may ask for")).font(.headline)
            permission("key.fill", L("Keychain"),
                       L("To read Claude Code's saved login, once. Choose Always Allow so it stays quiet; the timed reads never raise the dialog."))
            permission("accessibility", L("Accessibility"),
                       L("Only if you pick Readouts › Auto, which shifts the readouts clear of the frontmost app's menu titles. It reads the menu bar's geometry and nothing else."))
            permission("arrow.up.forward.app.fill", L("Automation"),
                       L("Only to jump to a session's terminal window, the first time you do. Nothing else in the app drives another app."))
        }
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

    private var connect: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Connect Claude Code")).font(.headline)
            Text(L("One entry in ~/.claude/settings.json lets Claude Code tell the notch when a session starts, a turn ends or it waits for you, and a status line hands over the context fill and the official limits after every turn. Both are backed up first; Settings › Integrations can repair or remove them later."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(L("Install the hook and status line…")) { install() }
        }
    }
}

/// The Welcome as a floating, non-activating panel like Settings (SettingsPanel): the app the person was in stays
/// in front, a first click lands on a button, Escape closes it. The panel controller holds the compact state
/// while it is up so the full-height panel never opens over it (PanelHolds.welcome).
@MainActor
final class WelcomeWindowController: NSWindowController {
    nonisolated static let contentSize = NSSize(width: 480, height: 340)

    init(install: @escaping () -> Void, finish: @escaping () -> Void) {
        let panel = SettingsPanel(contentRect: NSRect(origin: .zero, size: Self.contentSize),
                                  styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        let host = FirstMouseHostingView(rootView: WelcomeView(install: install, finish: finish))
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
}
