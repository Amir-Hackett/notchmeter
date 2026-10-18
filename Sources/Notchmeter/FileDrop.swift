import AppKit
import Foundation
import UniformTypeIdentifiers

/// Drop a file on the notch and it lands in a session's prompt (0.9.24). The rings and the open panel take a drop
/// for the session that is waiting on you, or else the newest one with a terminal; a row takes it for that session.
/// What is dropped is the file's PATH, typed where the terminal can take text (a tmux pane, iTerm2, kitty, WezTerm)
/// and otherwise put on the clipboard with the jump (TerminalJump) to the terminal, so one ⌘V finishes it. Claude
/// Code's prompt gets `@` in front of each path, which is how Claude Code reads a file into the turn; every other
/// assistant gets the bare path. Nothing is read from the file and nothing leaves this Mac: the path goes to the
/// terminal the session's own hook named, or to the clipboard, and nowhere else (docs/privacy.md).
///
/// Pure resolution lives here, like TerminalJump's; `TerminalJump.Executor.drop` runs it, off the main thread, with
/// the same tools and the same Automation grant the jump already holds, so a drop never asks a new permission.
enum FileDrop {
    /// How the dropped text reaches the session's prompt.
    enum Delivery: Equatable {
        /// `tmux -S socket send-keys -t pane -l -- text`: literal keys, no Enter.
        case tmux(socket: String, pane: String, text: String)
        /// iTerm2's `write text … newline NO` on the session the jump would select.
        case appleScript(bundleID: String, source: String)
        /// kitty's `kitten @ send-text` (its backslashes doubled, since it reads escapes) or WezTerm's
        /// `wezterm cli send-text --no-paste`.
        case command(executable: String, arguments: [String])
        /// Terminal.app, Ghostty, an editor, anything the hook could not name: the clipboard, then the jump.
        case pasteboard

        var name: String {
            switch self {
            case .tmux: "tmux"
            case .appleScript: "applescript"
            case .command: "command"
            case .pasteboard: "pasteboard"
            }
        }
    }

    /// What became of a drop, for the line the panel shows (DropNoticeLine).
    struct Notice: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            /// The text is in the session's prompt.
            case typed
            /// The text is on the clipboard and the terminal is in front.
            case copied
            /// No session with a terminal to drop on.
            case nothing
        }
        let kind: Kind
        let session: AgentSession?
        let files: Int
        let at: Date

        init(kind: Kind, session: AgentSession?, files: Int, at: Date = Date()) {
            self.kind = kind
            self.session = session
            self.files = files
            self.at = at
        }

        /// How long the line stays on the panel.
        static let duration: TimeInterval = 6

        /// The session as the line names it: the assistant, and the project when there is one.
        static func label(_ session: AgentSession) -> String {
            if let project = session.project, !project.isEmpty { return "\(session.assistantName) · \(project)" }
            return session.assistantName
        }

        var text: String {
            switch kind {
            case .typed: L("Dropped into %@", session.map(Self.label) ?? "")
            case .copied: L("Copied for %@ — paste it with ⌘V", session.map(Self.label) ?? "")
            case .nothing: L("Nothing to drop that on: no session with a terminal")
            }
        }
    }

    /// Which session a drop on the rings or the panel's background goes to: the one waiting on you; the newest
    /// waiting one when several are; else the newest session of any state. Only sessions on this Mac whose hook
    /// named a terminal count, since the others have nowhere to type. Nil when there is none.
    static func target(among sessions: [AgentSession]) -> AgentSession? {
        let local = sessions.filter { $0.host == nil && $0.terminal != nil }
        let waiting = local.filter(\.isWaiting)
        if let newest = waiting.max(by: { $0.lastEvent < $1.lastEvent }) { return newest }
        return local.max { $0.lastEvent < $1.lastEvent }
    }

    /// The text typed for `urls`: each file's path escaped the way Finder escapes a path dragged into a terminal
    /// (a backslash before a space and before every character a shell would read), a space between paths and one
    /// after the last so typing can go on. A Claude Code session gets `@` before each path; anything that is not a
    /// file URL is left out, as is a path with a control character in it (below), and no files gives an empty string.
    static func text(for urls: [URL], tool: ToolID) -> String {
        let paths = urls.filter { $0.isFileURL && isTypeable($0.path) }.map { escape($0.path) }
        guard !paths.isEmpty else { return "" }
        let mention = tool == .claude ? "@" : ""
        return paths.map { mention + $0 }.joined(separator: " ") + " "
    }

    /// The characters a shell reads, and a space: each gets a backslash.
    static let shellSpecials: Set<Character> = [" ", "\t", "\"", "'", "\\", "`", "$", "&", "|", ";", "(", ")", "<", ">", "*", "?", "[", "]", "{", "}", "#", "~", "!"]

    static func escape(_ path: String) -> String {
        var out = ""
        out.reserveCapacity(path.count + 8)
        for character in path {
            if shellSpecials.contains(character) { out.append("\\") }
            out.append(character)
        }
        return out
    }

    /// A macOS file name can hold a newline or any other control character, and in a prompt a newline is Enter: a
    /// name shaped `report\nDo this instead` would submit the first line as a turn and type the rest as the next
    /// one. The drop types a path and nothing more, so such a path is left out rather than escaped; a backslash
    /// before a newline is still a newline to the terminal. Format characters (a zero-width joiner inside an emoji)
    /// are not control characters and stay.
    static func isTypeable(_ path: String) -> Bool {
        !path.unicodeScalars.contains { scalar in
            switch scalar.properties.generalCategory {
            case .control, .lineSeparator, .paragraphSeparator: true
            default: false
            }
        }
    }

    /// What goes on the clipboard when the text could not be typed: the text without the one separator space
    /// `text(for:tool:)` appends, and nothing else trimmed, since an escaped space at the end of a path is part of it.
    static func clipboardText(_ text: String) -> String {
        text.hasSuffix(" ") ? String(text.dropLast()) : text
    }

    /// Where `text` can be typed for a session in `ref`'s terminal, resolved the way TerminalJump.resolve picks the
    /// jump, in the same order: a tmux pane on its socket, iTerm2 by the session's unique id and else by tty, kitty
    /// and WezTerm by their command-line tools. Terminal.app and Ghostty have no way to put text in a prompt
    /// without running it (`do script` executes), an editor has no prompt, and an empty reference has nothing, so
    /// those are the clipboard. The strings that go into a script or a command are validated the same way the jump
    /// validates them: a tty, a unique id or a pane that is not shaped like one is not used.
    static func resolve(_ ref: TerminalRef, text: String) -> Delivery {
        if let tmux = ref.tmux, let socket = TerminalJump.tmuxSocket(tmux), let pane = validTmuxPane(ref.tmuxPane) {
            return .tmux(socket: socket, pane: pane, text: text)
        }
        if ref.bundleID == TerminalJump.BundleID.iTerm || ref.program == "iTerm.app" {
            if let id = TerminalJump.iTermUniqueID(ref.sessionID) {
                return .appleScript(bundleID: TerminalJump.BundleID.iTerm, source: iTermScript(match: "unique id", value: id, text: text))
            }
            if let tty = TerminalJump.validTTY(ref.tty) {
                return .appleScript(bundleID: TerminalJump.BundleID.iTerm, source: iTermScript(match: "tty", value: tty, text: text))
            }
            return .pasteboard
        }
        if ref.bundleID == TerminalJump.BundleID.kitty || ref.program == "kitty" || ref.kittySocket != nil {
            if let socket = ref.kittySocket, let id = ref.sessionID, Int(id) != nil {
                // `send-text` reads Python-style escapes in its argument (`\n`, `\e`, `\\`), so every backslash the
                // path's escaping put in is doubled, and kitty types the single one.
                let literal = text.replacingOccurrences(of: "\\", with: "\\\\")
                return .command(executable: "kitten", arguments: ["@", "--to", socket, "send-text", "--match", "id:\(id)", "--", literal])
            }
            return .pasteboard
        }
        if ref.bundleID == TerminalJump.BundleID.wezterm || ref.program == "WezTerm" {
            if let pane = ref.sessionID, Int(pane) != nil {
                return .command(executable: "wezterm", arguments: ["cli", "send-text", "--pane-id", pane, "--no-paste", "--", text])
            }
            return .pasteboard
        }
        return .pasteboard
    }

    /// `%3`: the shape `TMUX_PANE` has, and nothing a shell could read; anything else is not used.
    static func validTmuxPane(_ pane: String?) -> String? {
        guard let pane, pane.range(of: #"^%[0-9]{1,6}$"#, options: .regularExpression) != nil else { return nil }
        return pane
    }

    /// The text inside an AppleScript string literal: a backslash and a quote are the two characters it reads.
    static func appleScriptLiteral(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// iTerm2: find the session the jump would select and type into it without a newline. The jump itself follows
    /// (TerminalJump.Executor.drop), which is what brings the window forward.
    static func iTermScript(match property: String, value: String, text: String) -> String {
        """
        tell application "iTerm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if (\(property) of s) is equal to "\(value)" then
                            tell s to write text "\(appleScriptLiteral(text))" newline NO
                            return
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        """
    }

    /// The file URLs in a drop, delivered on the main thread once every provider has answered; providers that
    /// carry no file URL are left out. Empty when nothing was a file.
    static func urls(from providers: [NSItemProvider], completion: @escaping @MainActor ([URL]) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var found: [(Int, URL)] = []
        for (index, provider) in providers.enumerated() where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                let url: URL?
                if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                else if let string = item as? String { url = URL(string: string) }
                else { url = item as? URL }
                guard let url, url.isFileURL else { return }
                lock.lock(); found.append((index, url)); lock.unlock()
            }
        }
        group.notify(queue: .main) {
            let ordered = found.sorted { $0.0 < $1.0 }.map(\.1)
            MainActor.assumeIsolated { completion(ordered) }
        }
    }
}
