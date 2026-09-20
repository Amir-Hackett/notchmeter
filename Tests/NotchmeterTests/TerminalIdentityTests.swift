import Darwin
import Foundation
import Testing
@testable import Notchmeter

/// Where the hook's terminal is, read from a fixture environment and a scripted ancestry: which variable wins
/// for the session id, what the ancestry adds and what it may not, the shape a Warp focus URL must have, and the
/// wire round trip of the reference. The live capture is exercised once against this process, whose ancestry the
/// kernel will describe whatever launched it.
@Suite struct TerminalIdentityResolution {
    static let iterm: [String: String] = [
        "TERM_PROGRAM": "iTerm.app", "TERM_PROGRAM_VERSION": "3.5.0", "__CFBundleIdentifier": "com.googlecode.iterm2",
        "ITERM_SESSION_ID": "w0t1p0:9F1A2B3C-0000-1111-2222-333344445555", "TERM_SESSION_ID": "w0t1p0:9F1A2B3C-0000-1111-2222-333344445555",
        "HOME": "/Users/me", "PATH": "/usr/bin", "ANTHROPIC_API_KEY": "sk-secret",
    ]

    @Test func theEnvironmentNamesTheAppAndItsSession() {
        let ref = TerminalIdentity.fromEnvironment(Self.iterm)
        #expect(ref.program == "iTerm.app")
        #expect(ref.bundleID == "com.googlecode.iterm2")
        #expect(ref.sessionID == "w0t1p0:9F1A2B3C-0000-1111-2222-333344445555")
        #expect(ref.tty == nil, "the environment never names the tty; that is the ancestry's")
        #expect(ref.focusURL == nil)
        #expect(ref.tmux == nil)
        #expect(!ref.ghostty)
        #expect(!ref.isEmpty)
        #expect(TerminalIdentity.fromEnvironment([:]).isEmpty)
        #expect(TerminalIdentity.fromEnvironment(["TERM_PROGRAM": ""]).isEmpty, "an empty value is no value")
    }

    @Test func theSessionVariableIsTakenInAFixedOrder() {
        #expect(TerminalIdentity.fromEnvironment(["TERM_SESSION_ID": "t", "WEZTERM_PANE": "3"]).sessionID == "t")
        #expect(TerminalIdentity.fromEnvironment(["WEZTERM_PANE": "3", "KITTY_WINDOW_ID": "7"]).sessionID == "3")
        #expect(TerminalIdentity.fromEnvironment(["KITTY_WINDOW_ID": "7", "ZELLIJ_PANE_ID": "2"]).sessionID == "7")
        #expect(TerminalIdentity.fromEnvironment(["ZELLIJ_PANE_ID": "2"]).sessionID == "2")
        #expect(TerminalIdentity.fromEnvironment(["ITERM_SESSION_ID": "i", "TERM_SESSION_ID": "t"]).sessionID == "i")
        let multiplexed = TerminalIdentity.fromEnvironment(["TMUX": "/private/tmp/tmux-501/default,4242,0", "TMUX_PANE": "%3",
                                                            "KITTY_LISTEN_ON": "unix:/tmp/kitty-77", "GHOSTTY_RESOURCES_DIR": "/Applications/Ghostty.app/Contents/Resources/ghostty"])
        #expect(multiplexed.tmux == "/private/tmp/tmux-501/default,4242,0")
        #expect(multiplexed.tmuxPane == "%3")
        #expect(multiplexed.kittySocket == "unix:/tmp/kitty-77")
        #expect(multiplexed.ghostty)
    }

    @Test func aWarpFocusURLIsKeptOnlyInItsDocumentedShape() {
        let good = "warp://session/0123456789abcdef0123456789abcdef"
        #expect(TerminalIdentity.focusURL(good) == good)
        #expect(TerminalIdentity.focusURL("warppreview://session/0123456789abcdef0123456789abcdef") != nil)
        #expect(TerminalIdentity.focusURL("warp://session/0123456789abcdef0123456789abcde") == nil, "31 digits")
        #expect(TerminalIdentity.focusURL("warp://session/0123456789ABCDEF0123456789abcdef") == nil, "upper case")
        #expect(TerminalIdentity.focusURL("file:///Volumes/X/Setup.app") == nil)
        #expect(TerminalIdentity.focusURL("warp://session/0123456789abcdef0123456789abcdef?x=1") == nil)
        #expect(TerminalIdentity.fromEnvironment(["WARP_FOCUS_URL": "javascript:alert(1)"]).focusURL == nil)
        #expect(TerminalIdentity.fromEnvironment(["WARP_FOCUS_URL": good]).focusURL == good)
    }

    /// The hook under `sh -c` under the assistant under the terminal: the tty is the shell's and the app is the
    /// terminal's, found by walking up; the hook's own bundle is never the answer.
    @Test func theAncestryFillsTheTTYAndTheAppTheEnvironmentDidNotName() {
        let chain = [
            TerminalIdentity.Ancestor(pid: 500, parent: 400, tty: nil, bundleID: nil),
            TerminalIdentity.Ancestor(pid: 400, parent: 300, tty: "/dev/ttys003", bundleID: nil),
            TerminalIdentity.Ancestor(pid: 300, parent: 200, tty: "/dev/ttys003", bundleID: nil),
            TerminalIdentity.Ancestor(pid: 200, parent: 1, tty: nil, bundleID: "com.mitchellh.ghostty"),
        ]
        let ref = TerminalIdentity.resolve(environment: ["TERM_PROGRAM": "ghostty", "GHOSTTY_RESOURCES_DIR": "/x"], ancestry: chain, ownBundleID: "com.amirhackett.notchmeter")
        #expect(ref?.tty == "/dev/ttys003")
        #expect(ref?.bundleID == "com.mitchellh.ghostty")
        #expect(ref?.program == "ghostty")
        #expect(ref?.ghostty == true)

        let named = TerminalIdentity.resolve(environment: Self.iterm, ancestry: chain, ownBundleID: "com.amirhackett.notchmeter")
        #expect(named?.bundleID == "com.googlecode.iterm2", "an app the environment names outranks the ancestry's")
        #expect(named?.tty == "/dev/ttys003")

        let own = [TerminalIdentity.Ancestor(pid: 500, parent: 400, tty: "/dev/ttys009", bundleID: "com.amirhackett.notchmeter"),
                   TerminalIdentity.Ancestor(pid: 400, parent: 1, tty: nil, bundleID: "com.amirhackett.notchmeter")]
        let self_ = TerminalIdentity.resolve(environment: [:], ancestry: own, ownBundleID: "com.amirhackett.notchmeter")
        #expect(self_?.bundleID == nil, "neither the hook's own pid nor its own bundle can be the terminal")
        #expect(self_?.tty == "/dev/ttys009", "the hook's own tty counts: a hook run by hand in a terminal has one")
        #expect(TerminalIdentity.resolve(environment: [:], ancestry: [], ownBundleID: nil) == nil)
    }

    @Test func theWalkIsBoundedAndStopsAtLaunchd() {
        // A chain that never ends: every pid's parent is pid - 1, down to launchd.
        var asked: [pid_t] = []
        let chain = TerminalIdentity.ancestry(of: 1000, parent: { pid in
            asked.append(pid)
            return (pid - 1, nil)
        }, bundleID: { _ in nil })
        #expect(chain.count == TerminalIdentity.maximumHops)
        #expect(asked.count == TerminalIdentity.maximumHops)
        #expect(chain.first?.pid == 1000)
        #expect(chain.last?.pid == 1000 - pid_t(TerminalIdentity.maximumHops) + 1)

        let short = TerminalIdentity.ancestry(of: 3, parent: { pid in (pid - 1, nil) }, bundleID: { _ in "app" })
        #expect(short.map(\.pid) == [3, 2], "pid 1 is launchd, and is never asked")
        #expect(short.map(\.bundleID) == [nil, "app"], "the process itself is never asked for a bundle")

        let orphan = TerminalIdentity.ancestry(of: 9, parent: { _ in nil }, bundleID: { _ in nil })
        #expect(orphan.isEmpty, "a process the kernel will not describe ends the walk")
    }

    @Test func theLiveCaptureDescribesThisProcess() throws {
        let parent = try #require(TerminalIdentity.liveParent(getpid()))
        #expect(parent.parent == getppid())
        let chain = TerminalIdentity.ancestry(of: getpid(), parent: TerminalIdentity.liveParent, bundleID: TerminalIdentity.liveBundleID)
        #expect(!chain.isEmpty)
        #expect(chain.first?.pid == getpid())
        #expect(chain.first?.bundleID == nil, "the process itself is never asked")
        // Whatever launched the test runner, nothing here may throw or hang; the answer itself depends on it.
        _ = TerminalIdentity.capture(environment: Self.iterm)
        _ = TerminalIdentity.capture(environment: [:])
    }

    @Test func theReferenceRoundTripsOnTheWireAndMergesFieldByField() throws {
        let ref = TerminalRef(program: "WezTerm", bundleID: "com.github.wez.wezterm", tty: "/dev/ttys004", sessionID: "5",
                              focusURL: nil, tmux: "/tmp/tmux-501/default,1,0", tmuxPane: "%1", kittySocket: nil, ghostty: false)
        var message = Hook.Message(event: "Stop", needsInput: false, sessionID: "s")
        message.terminal = ref
        let info = message.userInfo
        #expect(Set(info.keys) == ["hook_event_name", "needsInput", "session_id", "terminal_program", "terminal_bundle", "terminal_tty",
                                   "terminal_session", "terminal_tmux", "terminal_tmux_pane"])
        #expect(Hook.Message(userInfo: info) == message)
        #expect(Hook.Message(userInfo: info)?.terminal == ref)
        let line = try #require(HookSocket.encode(.hook, info))
        #expect(HookSocket.decode(line) == .hook(message))
        #expect(Hook.Message(userInfo: ["hook_event_name": "Stop", "terminal_focus_url": "javascript:x"])?.terminal == nil,
                "a focus URL is checked on the way in as well as on the way out")
        #expect(Hook.Message(userInfo: ["hook_event_name": "Stop", "terminal_ghostty": "1"])?.terminal == TerminalRef(ghostty: true))

        let older = TerminalRef(program: "iTerm.app", bundleID: "com.googlecode.iterm2", tty: "/dev/ttys001", sessionID: "w0t0p0:A")
        let newer = TerminalRef(program: nil, bundleID: nil, tty: "/dev/ttys002", sessionID: nil)
        let merged = older.merging(newer)
        #expect(merged.tty == "/dev/ttys002")
        #expect(merged.program == "iTerm.app")
        #expect(merged.sessionID == "w0t0p0:A", "a field the newer event lacks is kept")
    }
}
