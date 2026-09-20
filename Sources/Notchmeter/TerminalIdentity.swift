import AppKit
import Darwin
import Foundation

/// Where the hook process's terminal is, read from what the process already has: its environment, which the
/// terminal, the multiplexer and the assistant handed down to it, and its own ancestry, walked up from its parent
/// through the shell and the assistant to whatever launched them. Nothing is asked of the window server, no
/// window is looked at and no title is read; every field is something the session's own terminal put in the
/// environment of every process under it, or a fact the kernel keeps about those processes (their parent and
/// their controlling tty). The result rides on every hook event as `TerminalRef` and is what a jump back to the
/// terminal resolves from (TerminalJump.swift); docs/hooks.md lists the fields.
///
/// The hook runs without a controlling terminal of its own (Claude Code runs command hooks in their own session),
/// and under `sh -c`, so its parent is a shell and its grandparent the assistant: the tty and the app come from
/// the ancestry, never from the hook's own descriptors, and the walk is bounded at `maximumHops` so a runaway
/// chain costs a fixed few syscalls. `resolve(environment:ancestry:)` is pure and pinned by tests against a
/// fixture environment and a scripted ancestry; `capture()` is the live wrapper the command calls.
enum TerminalIdentity {
    /// One process on the way up: its pid, its parent's, its controlling tty when it has one, and the bundle id
    /// the system knows it by when it is an app.
    struct Ancestor: Equatable, Sendable {
        let pid: pid_t
        let parent: pid_t
        let tty: String?
        let bundleID: String?

        init(pid: pid_t, parent: pid_t, tty: String? = nil, bundleID: String? = nil) {
            self.pid = pid
            self.parent = parent
            self.tty = tty
            self.bundleID = bundleID
        }
    }

    static let maximumHops = 8

    /// The terminal's own session ids, in the order one is taken: iTerm2's, then Apple Terminal's (which iTerm2
    /// and others also set), then WezTerm's pane, kitty's window, Zellij's pane.
    static let sessionVariables = ["ITERM_SESSION_ID", "TERM_SESSION_ID", "WEZTERM_PANE", "KITTY_WINDOW_ID", "ZELLIJ_PANE_ID"]

    /// What the environment alone says. `__CFBundleIdentifier` is set by LaunchServices for every process under
    /// an app it launched, which is the terminal for a shell it opened.
    static func fromEnvironment(_ environment: [String: String]) -> TerminalRef {
        func value(_ key: String) -> String? { environment[key].flatMap { $0.isEmpty ? nil : $0 } }
        return TerminalRef(program: value("TERM_PROGRAM"),
                           bundleID: value("__CFBundleIdentifier"),
                           tty: nil,
                           sessionID: sessionVariables.lazy.compactMap(value).first,
                           focusURL: value("WARP_FOCUS_URL").flatMap(focusURL),
                           tmux: value("TMUX"),
                           tmuxPane: value("TMUX_PANE"),
                           kittySocket: value("KITTY_LISTEN_ON"),
                           ghostty: value("GHOSTTY_RESOURCES_DIR") != nil)
    }

    /// Warp's focus URL, kept only when it is shaped like one: a scheme, `session/` and a 32-digit hex id. The
    /// app hands it to NSWorkspace to jump, so anything else in the variable is not a URL it will open.
    static func focusURL(_ value: String) -> String? {
        value.range(of: #"^[a-z]+://session/[0-9a-f]{32}$"#, options: .regularExpression) != nil ? value : nil
    }

    /// The environment's answer, with the tty and, failing `__CFBundleIdentifier`, the app filled in from the
    /// ancestry: the first ancestor with a controlling tty names it, and the first the system knows as an app
    /// names the bundle. `ancestry` is the chain from the process itself upward, so the process's own tty counts
    /// (a hook run by hand in a terminal has one) but its own bundle does not: the hook is this app's binary, and
    /// naming Notchmeter as the terminal would send a jump nowhere.
    static func resolve(environment: [String: String], ancestry: [Ancestor], ownBundleID: String? = Bundle.main.bundleIdentifier) -> TerminalRef? {
        var terminal = fromEnvironment(environment)
        terminal.tty = ancestry.lazy.compactMap(\.tty).first
        if terminal.bundleID == nil {
            terminal.bundleID = ancestry.dropFirst().lazy.compactMap(\.bundleID).first { $0 != ownBundleID }
        }
        return terminal.isEmpty ? nil : terminal
    }

    /// The chain from `pid` upward, at most `hops` long, stopping at launchd or a parent the kernel will not
    /// name. `parent` answers one process's parent and tty; `bundleID` names the app behind a pid, and is asked
    /// only for ancestors, never for `pid` itself.
    static func ancestry(of pid: pid_t, hops: Int = maximumHops, parent: (pid_t) -> (parent: pid_t, tty: String?)?,
                         bundleID: (pid_t) -> String?) -> [Ancestor] {
        var chain: [Ancestor] = []
        var current = pid
        while chain.count < hops, current > 1, let info = parent(current) {
            chain.append(Ancestor(pid: current, parent: info.parent, tty: info.tty, bundleID: chain.isEmpty ? nil : bundleID(current)))
            current = info.parent
        }
        return chain
    }

    /// The live capture the command runs: the environment, then the ancestry through `proc_pidinfo` and
    /// LaunchServices. The bundle lookup is skipped altogether when the environment already names the app, since
    /// it is the one call here that leaves the kernel.
    static func capture(environment: [String: String] = ProcessInfo.processInfo.environment, pid: pid_t = getpid()) -> TerminalRef? {
        let needsBundle = environment["__CFBundleIdentifier"].map(\.isEmpty) ?? true
        let chain = ancestry(of: pid, parent: liveParent, bundleID: needsBundle ? liveBundleID : { _ in nil })
        return resolve(environment: environment, ancestry: chain)
    }

    /// The parent pid and the controlling tty (`/dev/ttys003`) of `pid`, from `PROC_PIDTBSDINFO`; nil when the
    /// kernel will not describe the process (gone, or another user's).
    static func liveParent(_ pid: pid_t) -> (parent: pid_t, tty: String?)? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        var tty: String?
        if info.e_tdev != UInt32.max, let name = devname(dev_t(bitPattern: info.e_tdev), S_IFCHR) {
            tty = "/dev/" + String(cString: name)
        }
        return (pid_t(info.pbi_ppid), tty)
    }

    /// The bundle identifier LaunchServices records for `pid`, or nil for a process that is not an app (a shell,
    /// the assistant's node process).
    static func liveBundleID(_ pid: pid_t) -> String? {
        NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }
}
