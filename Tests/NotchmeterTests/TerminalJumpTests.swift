import Foundation
import Testing
@testable import Notchmeter

/// Which way a jump goes for each terminal the hook can name, from a fixture reference per host: Warp by its
/// focus URL, iTerm2 by the session's unique id and else by tty, Terminal.app by tty, Ghostty by tty with the
/// app raised when the property is missing, kitty and WezTerm by their own command, tmux by its socket and then
/// the client's terminal, anything else by raising the app, and nothing for a reference with nothing in it. Pure
/// resolution only: nothing here runs a script or activates an app.
@Suite struct TerminalJumpResolution {
    @Test func warpsFocusURLWinsOverEverythingElse() {
        let ref = TerminalRef(program: "WarpTerminal", bundleID: "dev.warp.Warp-Stable", tty: "/dev/ttys004",
                              focusURL: "warp://session/0123456789abcdef0123456789abcdef", tmux: "/private/tmp/tmux-501/default,1,0")
        #expect(TerminalJump.resolve(ref) == .openURL("warp://session/0123456789abcdef0123456789abcdef", bundleIDPrefix: "dev.warp."))
    }

    @Test func iTermIsAddressedByItsUniqueIDAndElseByItsTTY() throws {
        let byID = TerminalJump.resolve(TerminalRef(program: "iTerm.app", bundleID: "com.googlecode.iterm2", tty: "/dev/ttys011",
                                                    sessionID: "w0t0p0:ABA06F98-9094-4382-953B-E41AFAC97761"))
        guard case .appleScript(let bundleID, let source) = byID else {
            Issue.record("iTerm2 with a session id is an AppleScript jump, got \(byID)")
            return
        }
        #expect(bundleID == "com.googlecode.iterm2")
        #expect(source.contains(#"tell application "iTerm2""#))
        #expect(source.contains(#"(unique id of s) is equal to "ABA06F98-9094-4382-953B-E41AFAC97761""#))
        #expect(!source.contains("ttys011"), "the id is exact; the tty is the fallback")
        let byTTY = TerminalJump.resolve(TerminalRef(program: "iTerm.app", tty: "/dev/ttys011"))
        guard case .appleScript(_, let ttySource) = byTTY else {
            Issue.record("iTerm2 with a tty alone is still an AppleScript jump")
            return
        }
        #expect(ttySource.contains(#"(tty of s) is equal to "/dev/ttys011""#))
        #expect(TerminalJump.resolve(TerminalRef(bundleID: "com.googlecode.iterm2")) == .activate(bundleID: "com.googlecode.iterm2"))
        #expect(TerminalJump.iTermUniqueID("w0t0p0:ABA06F98-9094-4382-953B-E41AFAC97761") == "ABA06F98-9094-4382-953B-E41AFAC97761")
        #expect(TerminalJump.iTermUniqueID("w0t0p0") == nil)
        #expect(TerminalJump.iTermUniqueID("w0t0p0:not an id\" -- injected") == nil, "only hex and dashes go inside the script's literal")
        #expect(TerminalJump.iTermUniqueID(nil) == nil)
    }

    @Test func terminalAppIsAddressedByTTYOnly() {
        let byTTY = TerminalJump.resolve(TerminalRef(program: "Apple_Terminal", bundleID: "com.apple.Terminal", tty: "/dev/ttys003",
                                                     sessionID: "5C3D0A2B-1234-4ABC-9DEF-0123456789AB"))
        guard case .appleScript(let bundleID, let source) = byTTY else {
            Issue.record("Terminal with a tty is an AppleScript jump")
            return
        }
        #expect(bundleID == "com.apple.Terminal")
        #expect(source.contains(#"tell application "Terminal""#))
        #expect(source.contains(#"(tty of t) is equal to "/dev/ttys003""#))
        #expect(!source.contains("5C3D0A2B"), "Terminal.app's TERM_SESSION_ID is not scriptable, so it is never used")
        #expect(TerminalJump.resolve(TerminalRef(program: "Apple_Terminal")) == .activate(bundleID: "com.apple.Terminal"))
    }

    @Test func ghosttyTriesTheTTYAndSettlesForTheApp() {
        let ref = TerminalRef(program: "ghostty", bundleID: "com.mitchellh.ghostty", tty: "/dev/ttys016", ghostty: true)
        guard case .appleScript(let bundleID, let source) = TerminalJump.resolve(ref) else {
            Issue.record("Ghostty with a tty is an AppleScript jump")
            return
        }
        #expect(bundleID == "com.mitchellh.ghostty")
        #expect(source.contains(#"(tty of term) is equal to "/dev/ttys016""#))
        #expect(source.contains("try"), "the tty property is 1.4.0's; an older build errors inside the try and the activate above it stands")
        #expect(source.contains("activate"))
        #expect(TerminalJump.resolve(TerminalRef(ghostty: true)) == .activate(bundleID: "com.mitchellh.ghostty"))
    }

    @Test func kittyAndWezTermTakeACommandWhenTheyCanAndTheAppOtherwise() {
        let kitty = TerminalRef(program: "xterm-kitty", bundleID: "net.kovidgoyal.kitty", sessionID: "7", kittySocket: "unix:/tmp/kitty-77")
        #expect(TerminalJump.resolve(kitty) == .command(executable: "kitten", arguments: ["@", "--to", "unix:/tmp/kitty-77", "focus-window", "--match", "id:7"],
                                                        activate: "net.kovidgoyal.kitty"))
        #expect(TerminalJump.resolve(TerminalRef(bundleID: "net.kovidgoyal.kitty", sessionID: "7")) == .activate(bundleID: "net.kovidgoyal.kitty"),
                "without the listening socket kitty cannot be addressed")
        #expect(TerminalJump.resolve(TerminalRef(bundleID: "net.kovidgoyal.kitty", sessionID: "7; rm -rf /", kittySocket: "unix:/tmp/k")) == .activate(bundleID: "net.kovidgoyal.kitty"),
                "a window id that is not a number never reaches a command line")
        let wezterm = TerminalRef(program: "WezTerm", bundleID: "com.github.wez.wezterm", sessionID: "12")
        #expect(TerminalJump.resolve(wezterm) == .command(executable: "wezterm", arguments: ["cli", "activate-pane", "--pane-id", "12"], activate: "com.github.wez.wezterm"))
        #expect(TerminalJump.resolve(TerminalRef(program: "WezTerm")) == .activate(bundleID: "com.github.wez.wezterm"))
    }

    @Test func tmuxSelectsThePaneFirstAndThenTheClientsTerminal() {
        let ref = TerminalRef(program: "tmux", bundleID: "com.googlecode.iterm2", tty: "/dev/ttys020", sessionID: "w0t0p0:ABA06F98-9094-4382-953B-E41AFAC97761",
                              tmux: "/private/tmp/tmux-501/default,4242,0", tmuxPane: "%3")
        guard case .tmux(let socket, let pane, let outer) = TerminalJump.resolve(ref) else {
            Issue.record("a session inside tmux is a tmux jump")
            return
        }
        #expect(socket == "/private/tmp/tmux-501/default")
        #expect(pane == "%3")
        #expect(outer.tty == nil, "the pane's pty is not a tab's tty; the client's is found at jump time")
        #expect(outer.tmux == nil && outer.tmuxPane == nil, "the outer reference can never resolve to tmux again")
        #expect(outer.bundleID == "com.googlecode.iterm2")
        #expect(TerminalJump.tmuxSocket("/private/tmp/tmux-501/default,4242,0") == "/private/tmp/tmux-501/default")
        #expect(TerminalJump.tmuxSocket("relative,1,0") == nil)
        #expect(TerminalJump.resolve(TerminalRef(tmux: "relative,1,0", tmuxPane: "%1")) == .none, "a socket that is not a path is nothing to select on")
        #expect(TerminalJump.Executor.parseLatestClient("1726000000 /dev/ttys004\n1726000900 /dev/ttys011\n1726000100 /dev/ttys002\n") == "/dev/ttys011")
        #expect(TerminalJump.Executor.parseLatestClient("garbage\n") == nil)
        #expect(TerminalJump.Executor.parseLatestClient("1 /dev/ttys004; rm -rf /") == nil, "a client tty that is not a tty never goes in a script")
    }

    @Test func anythingElseIsRaisedAsAnAppAndNothingIsNothing() {
        #expect(TerminalJump.resolve(TerminalRef(program: "vscode", bundleID: "com.todesktop.230313mzl4w4u92", tty: "/dev/ttys001")) == .activate(bundleID: "com.todesktop.230313mzl4w4u92"))
        #expect(TerminalJump.resolve(TerminalRef(bundleID: "io.alacritty")) == .activate(bundleID: "io.alacritty"))
        #expect(TerminalJump.resolve(TerminalRef()) == .none)
        #expect(TerminalJump.resolve(TerminalRef(tty: "/dev/ttys001")) == .none, "a tty alone names no app to send it to")
        #expect(TerminalJump.resolve(TerminalRef(program: "unknown-terminal")) == .none)
    }

    @Test func onlyAWellFormedTTYGoesInsideAScript() {
        #expect(TerminalJump.validTTY("/dev/ttys003") == "/dev/ttys003")
        #expect(TerminalJump.validTTY("/dev/ttys0031") == "/dev/ttys0031")
        #expect(TerminalJump.validTTY("/dev/ttys03") == nil)
        #expect(TerminalJump.validTTY("/dev/ttys003\" -- injected") == nil)
        #expect(TerminalJump.validTTY("/dev/pts/3") == nil)
        #expect(TerminalJump.validTTY(nil) == nil)
    }

    @Test func theChipNamesTheTerminalsItKnowsAndNoOther() {
        #expect(TerminalJump.displayName(bundleID: "com.googlecode.iterm2") == "iTerm")
        #expect(TerminalJump.displayName(bundleID: "com.apple.Terminal") == "Terminal")
        #expect(TerminalJump.displayName(bundleID: "com.mitchellh.ghostty") == "Ghostty")
        #expect(TerminalJump.displayName(bundleID: "dev.warp.Warp-Stable") == "Warp")
        #expect(TerminalJump.displayName(bundleID: "dev.warp.Warp") == "Warp")
        #expect(TerminalJump.displayName(bundleID: "com.github.wez.wezterm") == "WezTerm")
        #expect(TerminalJump.displayName(bundleID: "net.kovidgoyal.kitty") == "kitty")
        #expect(TerminalJump.displayName(bundleID: "org.alacritty") == "Alacritty")
        #expect(TerminalJump.displayName(bundleID: "com.todesktop.230313mzl4w4u92") == "Cursor")
        #expect(TerminalJump.displayName(bundleID: "com.microsoft.VSCode") == "VS Code")
        #expect(TerminalJump.displayName(bundleID: "dev.zed.Zed") == "Zed")
        #expect(TerminalJump.displayName(bundleID: "com.example.unknown") == nil, "an id the table does not know is not shown as an id")
        #expect(TerminalJump.displayName(bundleID: nil) == nil)
        // Every terminal the notifier suppresses banners for has a chip name, so the two lists agree on what a terminal is.
        for bundleID in Notifier.terminalBundleIDs {
            #expect(TerminalJump.displayName(bundleID: bundleID) != nil, "\(bundleID) is a terminal to the notifier and unnamed here")
        }
    }

    @Test func theAutomationStatusHasAWordForTheSmokeLineAndCopyForSettings() {
        #expect(TerminalJump.AutomationStatus.granted.word == "granted")
        #expect(TerminalJump.AutomationStatus.denied.word == "denied")
        #expect(TerminalJump.AutomationStatus.notAsked.word == "not-asked")
        #expect(TerminalJump.AutomationStatus.notRunning.word == "not-running")
        #expect(TerminalJump.AutomationStatus.unknown(-1708).word == "unknown(-1708)")
        #expect(TerminalJump.AutomationStatus.granted.text == L("Granted"))
        #expect(TerminalJump.scriptedApps.map(\.name) == ["iTerm2", "Terminal", "Ghostty"])
        #expect(TerminalJump.automationSettingsURL.scheme == "x-apple.systempreferences")
        // An app that is not running is never asked about, and asking about one is what would show a prompt.
        #expect(TerminalJump.automationStatus(bundleID: "com.example.not-running-\(UUID().uuidString)") == .notRunning)
    }

    /// The command-line tools are looked for where the terminals install them and never on the app's own PATH;
    /// a tool that is not there is nil, and the executor falls back to raising the app.
    @Test func aMissingToolIsNil() {
        #expect(TerminalJump.Executor.locate("no-such-tool-\(UUID().uuidString)") == nil)
    }
}
