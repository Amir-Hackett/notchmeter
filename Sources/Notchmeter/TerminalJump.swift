import AppKit
import Foundation
import os

private let log = Logger(subsystem: "com.amirhackett.notchmeter", category: "jump")

/// A click on a session row takes the user back to the terminal the session runs in, resolved from what the
/// session's own hook reported about it (`TerminalRef`, TerminalIdentity.swift) and nothing else: no window is
/// searched, no title is read, and nothing is asked of the Accessibility API.
///
/// `resolve` is pure and pinned by tests: one `TerminalRef` in, one `Strategy` out, in a fixed order of
/// preference. Warp exports a focus URL that LaunchServices routes to the right pane with no permission at all;
/// iTerm2 and Terminal.app expose the tab's session id or tty over AppleScript, which needs the Automation grant
/// (docs/permissions.md); Ghostty's AppleScript names a terminal's tty from 1.4.0 and only its working directory
/// before, so its script tries the tty and settles for raising the app; kitty and WezTerm take a focus command on
/// their own socket; a session inside tmux first selects its pane, then raises whichever terminal the most
/// recent tmux client is attached from; anything else is raised as an app. A session with nothing to go on
/// resolves to `none`, and a session on another Mac is never a jump at all.
///
/// The executor runs one jump at a time on a serial queue, never launches an app that is not running (an
/// AppleScript `tell` would), gives activation back with `NSApp.deactivate()` so the panel does not linger in
/// front, and reports a failure to the log and the oracle rather than to the user: a jump that did not land is a
/// row that did nothing, and the row's own help says why it can.
enum TerminalJump {
    /// What the jump does, in order of how exact it is.
    enum Strategy: Equatable, Sendable {
        /// Warp's focus URL, opened with LaunchServices while a Warp channel app is running.
        case openURL(String, bundleIDPrefix: String)
        /// An AppleScript against a running app named by bundle id; `activate` when the script fails.
        case appleScript(bundleID: String, source: String)
        /// A command-line focus (kitty, WezTerm) followed by activating the app.
        case command(executable: String, arguments: [String], activate: String?)
        /// A tmux pane to select on its socket, then the terminal the client is attached from, resolved again
        /// from the client's tty (`outer` is the reference with the pane's tty removed).
        case tmux(socket: String, pane: String?, outer: TerminalRef)
        /// Bring the app to the front and nothing more.
        case activate(bundleID: String)
        case none

        /// The word the oracle records.
        var name: String {
            switch self {
            case .openURL: "url"
            case .appleScript: "applescript"
            case .command: "command"
            case .tmux: "tmux"
            case .activate: "activate"
            case .none: "none"
            }
        }
    }

    enum BundleID {
        static let iTerm = "com.googlecode.iterm2"
        static let terminal = "com.apple.Terminal"
        static let ghostty = "com.mitchellh.ghostty"
        static let kitty = "net.kovidgoyal.kitty"
        static let wezterm = "com.github.wez.wezterm"
        static let warpPrefix = "dev.warp."
    }

    /// The terminal app's short name for a chip on a session row, from the bundle id the hook read. Proper nouns,
    /// so never localised; nil for an app the table does not know, and the row shows no chip rather than an id.
    static func displayName(bundleID: String?) -> String? {
        guard let bundleID else { return nil }
        if bundleID.hasPrefix(BundleID.warpPrefix) { return "Warp" }
        switch bundleID {
        case BundleID.iTerm: return "iTerm"
        case BundleID.terminal: return "Terminal"
        case BundleID.ghostty: return "Ghostty"
        case BundleID.kitty: return "kitty"
        case BundleID.wezterm: return "WezTerm"
        case "io.alacritty", "org.alacritty": return "Alacritty"
        case "co.zeit.hyper": return "Hyper"
        case "com.todesktop.230313mzl4w4u92": return "Cursor"
        case "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders": return "VS Code"
        case "com.zed.Zed", "dev.zed.Zed": return "Zed"
        case "com.tabby.terminal": return "Tabby"
        case "com.apple.dt.Xcode": return "Xcode"
        case "com.jetbrains.intellij", "com.jetbrains.pycharm", "com.jetbrains.WebStorm": return "JetBrains"
        case "com.anthropic.claudefordesktop": return "Claude"
        default: return nil
        }
    }

    /// Which terminal a reference names, by bundle id first and `TERM_PROGRAM` second.
    private static func isITerm(_ ref: TerminalRef) -> Bool { ref.bundleID == BundleID.iTerm || ref.program == "iTerm.app" }
    private static func isTerminal(_ ref: TerminalRef) -> Bool { ref.bundleID == BundleID.terminal || ref.program == "Apple_Terminal" }
    private static func isGhostty(_ ref: TerminalRef) -> Bool { ref.bundleID == BundleID.ghostty || ref.program == "ghostty" || ref.ghostty }
    private static func isKitty(_ ref: TerminalRef) -> Bool { ref.bundleID == BundleID.kitty || ref.program == "kitty" || ref.kittySocket != nil }
    private static func isWezTerm(_ ref: TerminalRef) -> Bool { ref.bundleID == BundleID.wezterm || ref.program == "WezTerm" }

    /// The strategy for a reference, in order of preference; see the type's note.
    static func resolve(_ ref: TerminalRef) -> Strategy {
        if let url = ref.focusURL { return .openURL(url, bundleIDPrefix: BundleID.warpPrefix) }
        // Inside tmux the captured tty is the pane's pty, which no terminal's tab carries, so the pane is
        // selected first and the outer terminal found from the client's tty afterwards.
        if let tmux = ref.tmux, let socket = tmuxSocket(tmux) {
            var outer = ref
            outer.tmux = nil
            outer.tmuxPane = nil
            outer.tty = nil
            return .tmux(socket: socket, pane: ref.tmuxPane, outer: outer)
        }
        if isITerm(ref) {
            if let id = iTermUniqueID(ref.sessionID) { return .appleScript(bundleID: BundleID.iTerm, source: iTermScript(uniqueID: id)) }
            if let tty = validTTY(ref.tty) { return .appleScript(bundleID: BundleID.iTerm, source: iTermScript(tty: tty)) }
            return .activate(bundleID: BundleID.iTerm)
        }
        if isTerminal(ref) {
            if let tty = validTTY(ref.tty) { return .appleScript(bundleID: BundleID.terminal, source: terminalScript(tty: tty)) }
            return .activate(bundleID: BundleID.terminal)
        }
        if isGhostty(ref) {
            if let tty = validTTY(ref.tty) { return .appleScript(bundleID: BundleID.ghostty, source: ghosttyScript(tty: tty)) }
            return .activate(bundleID: BundleID.ghostty)
        }
        if isKitty(ref) {
            if let socket = ref.kittySocket, let id = ref.sessionID, Int(id) != nil {
                return .command(executable: "kitten", arguments: ["@", "--to", socket, "focus-window", "--match", "id:\(id)"], activate: BundleID.kitty)
            }
            return .activate(bundleID: BundleID.kitty)
        }
        if isWezTerm(ref) {
            if let pane = ref.sessionID, Int(pane) != nil {
                return .command(executable: "wezterm", arguments: ["cli", "activate-pane", "--pane-id", pane], activate: BundleID.wezterm)
            }
            return .activate(bundleID: BundleID.wezterm)
        }
        if let bundleID = ref.bundleID, !bundleID.isEmpty { return .activate(bundleID: bundleID) }
        return .none
    }

    /// The socket path from `TMUX` (`/private/tmp/tmux-501/default,1234,0`): the first field.
    static func tmuxSocket(_ value: String) -> String? {
        let socket = value.split(separator: ",", maxSplits: 1).first.map(String.init) ?? ""
        return socket.hasPrefix("/") ? socket : nil
    }

    /// The GUID after the colon in `ITERM_SESSION_ID` (`w0t0p0:ABA06F98-…`), which is the session's AppleScript
    /// `unique id`; nil for anything not shaped like that.
    static func iTermUniqueID(_ sessionID: String?) -> String? {
        guard let sessionID, let colon = sessionID.firstIndex(of: ":") else { return nil }
        let id = String(sessionID[sessionID.index(after: colon)...])
        return id.range(of: #"^[0-9A-Fa-f-]{8,}$"#, options: .regularExpression) != nil ? id : nil
    }

    /// A tty the scripts will name: `/dev/ttys` and digits, nothing else, since the string goes inside an
    /// AppleScript literal and came from a payload another process wrote.
    static func validTTY(_ tty: String?) -> String? {
        guard let tty, tty.range(of: #"^/dev/ttys[0-9]{3,4}$"#, options: .regularExpression) != nil else { return nil }
        return tty
    }

    static func iTermScript(uniqueID: String) -> String {
        """
        tell application "iTerm2"
            activate
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if (unique id of s) is equal to "\(uniqueID)" then
                            set miniaturized of w to false
                            set index of w to 1
                            select t
                            tell s to select
                            return
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        """
    }

    static func iTermScript(tty: String) -> String {
        """
        tell application "iTerm2"
            activate
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if (tty of s) is equal to "\(tty)" then
                            set miniaturized of w to false
                            set index of w to 1
                            select t
                            tell s to select
                            return
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        """
    }

    static func terminalScript(tty: String) -> String {
        """
        tell application "Terminal"
            activate
            repeat with w in windows
                repeat with t in tabs of w
                    if (tty of t) is equal to "\(tty)" then
                        set miniaturized of w to false
                        set selected of t to true
                        set frontmost of w to true
                        return
                    end if
                end repeat
            end repeat
        end tell
        """
    }

    /// Ghostty names a terminal's `tty` from 1.4.0; on an older build the property is an error, which the `try`
    /// swallows so the `activate` above it still stands.
    static func ghosttyScript(tty: String) -> String {
        """
        tell application "Ghostty"
            activate
            try
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with term in terminals of t
                            if (tty of term) is equal to "\(tty)" then
                                activate window w
                                select tab t
                                focus term
                                return
                            end if
                        end repeat
                    end repeat
                end repeat
            end try
        end tell
        """
    }

    // MARK: - Automation permission

    /// Where the Automation grant for an app stands, from `AEDeterminePermissionToAutomateTarget` without asking.
    enum AutomationStatus: Equatable, Sendable {
        case granted
        case denied
        case notAsked
        case notRunning
        case unknown(Int)

        var text: String {
            switch self {
            case .granted: L("Granted")
            case .denied: L("Denied")
            case .notAsked: L("Not asked yet")
            case .notRunning: L("Not running")
            case .unknown: L("Unknown")
            }
        }

        /// The word `--smoke` prints.
        var word: String {
            switch self {
            case .granted: "granted"
            case .denied: "denied"
            case .notAsked: "not-asked"
            case .notRunning: "not-running"
            case .unknown(let code): "unknown(\(code))"
            }
        }
    }

    /// The three apps a jump drives over AppleScript, with the name each row shows.
    static let scriptedApps: [(name: String, bundleID: String)] = [("iTerm2", BundleID.iTerm), ("Terminal", BundleID.terminal), ("Ghostty", BundleID.ghostty)]

    /// System Settings › Privacy & Security › Automation.
    static let automationSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!

    /// Asks the system, never the user: the grant is requested by the first script, not here.
    static func automationStatus(bundleID: String) -> AutomationStatus {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first != nil else { return .notRunning }
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        let status = AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, false)
        switch Int(status) {
        case 0: return .granted
        case -1743: return .denied
        case -1744: return .notAsked
        case -600: return .notRunning
        default: return .unknown(Int(status))
        }
    }

    // MARK: - Executing

    /// One jump at a time, on its own queue: a slow script must not land after a later click and take the focus
    /// that one just gave.
    @MainActor
    final class Executor {
        private let queue = DispatchQueue(label: "com.amirhackett.notchmeter.jump", qos: .userInitiated)

        init() {}

        /// Jumps to `session`'s terminal, or does nothing for a session with none, or one on another Mac.
        func jump(_ session: AgentSession) {
            guard session.host == nil, let terminal = session.terminal else {
                Oracle.shared.emit("jump", ["session": session.id, "strategy": "none", "ok": false])
                return
            }
            let strategy = TerminalJump.resolve(terminal)
            Oracle.shared.emit("jump", ["session": session.id, "strategy": strategy.name])
            perform(strategy, session: session.id)
        }

        func perform(_ strategy: Strategy, session: String) {
            queue.async {
                let ok = Self.run(strategy)
                Oracle.shared.emit("jump", ["session": session, "strategy": strategy.name, "ok": ok])
                if !ok { log.info("jump \(strategy.name, privacy: .public) for \(session, privacy: .public) did not land") }
                DispatchQueue.main.async { NSApp.deactivate() }
            }
        }

        /// Runs off the main thread; returns whether the jump landed.
        nonisolated static func run(_ strategy: Strategy) -> Bool {
            switch strategy {
            case .openURL(let string, let prefix):
                guard let url = URL(string: string), let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier?.hasPrefix(prefix) == true }),
                      let appURL = app.bundleURL else { return false }
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: configuration)
                return true
            case .appleScript(let bundleID, let source):
                guard running(bundleID) != nil else { return false }
                var error: NSDictionary?
                NSAppleScript(source: source)?.executeAndReturnError(&error)
                if let error {
                    log.info("jump script for \(bundleID, privacy: .public) failed: \(error[NSAppleScript.errorNumber] as? Int ?? 0, privacy: .public)")
                    return activate(bundleID)
                }
                return true
            case .command(let executable, let arguments, let bundleID):
                guard let path = locate(executable) else { return bundleID.map(activate) ?? false }
                let ran = runCommand(path, arguments)
                let raised = bundleID.map(activate) ?? true
                return ran && raised
            case .tmux(let socket, let pane, let outer):
                guard let tmux = locate("tmux") else { return false }
                if let pane {
                    _ = runCommand(tmux, ["-S", socket, "select-window", "-t", pane])
                    _ = runCommand(tmux, ["-S", socket, "select-pane", "-t", pane])
                }
                var outer = outer
                if let tty = latestClientTTY(tmux: tmux, socket: socket) { outer.tty = tty }
                let next = TerminalJump.resolve(outer)
                if case .tmux = next { return false }
                return run(next)
            case .activate(let bundleID):
                return activate(bundleID)
            case .none:
                return false
            }
        }

        nonisolated private static func running(_ bundleID: String) -> NSRunningApplication? {
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        }

        /// Raises a running app and never launches one. macOS 14 makes activation cooperative, so from an app that
        /// is never frontmost this is best effort, which is why every path above it is preferred.
        nonisolated private static func activate(_ bundleID: String) -> Bool {
            guard let app = running(bundleID) else { return false }
            return app.activate(options: [.activateAllWindows])
        }

        /// Where the terminals' own command-line tools live: the app bundles first, then the usual prefixes. The
        /// app's own PATH is the launchd one, which has none of them.
        nonisolated static func locate(_ executable: String) -> String? {
            var candidates: [String] = []
            switch executable {
            case "kitten": candidates += ["/Applications/kitty.app/Contents/MacOS/kitten"]
            case "wezterm": candidates += ["/Applications/WezTerm.app/Contents/MacOS/wezterm"]
            default: break
            }
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            candidates += ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "/usr/bin"].map { "\($0)/\(executable)" }
            return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
        }

        /// The tty of the tmux client with the latest activity, which is the terminal tab the user is looking at.
        nonisolated static func latestClientTTY(tmux: String, socket: String) -> String? {
            guard let output = output(of: tmux, ["-S", socket, "list-clients", "-F", "#{client_activity} #{client_tty}"]) else { return nil }
            return parseLatestClient(output)
        }

        /// `<activity> <tty>` per line; the tty of the highest activity.
        nonisolated static func parseLatestClient(_ output: String) -> String? {
            output.split(whereSeparator: \.isNewline).compactMap { line -> (Int, String)? in
                let parts = line.split(separator: " ", maxSplits: 1)
                guard parts.count == 2, let activity = Int(parts[0]) else { return nil }
                return (activity, String(parts[1]))
            }.max { $0.0 < $1.0 }.map(\.1).flatMap(TerminalJump.validTTY)
        }

        nonisolated private static func runCommand(_ path: String, _ arguments: [String]) -> Bool {
            output(of: path, arguments) != nil
        }

        /// Runs a tool and returns its standard output, or nil on a non-zero exit, a launch failure or five seconds.
        nonisolated private static func output(of path: String, _ arguments: [String]) -> String? {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return nil }
            let deadline = DispatchTime.now() + 5
            let done = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in done.signal() }
            if done.wait(timeout: deadline) == .timedOut {
                process.terminate()
                return nil
            }
            guard process.terminationStatus == 0 else { return nil }
            return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        }
    }
}
