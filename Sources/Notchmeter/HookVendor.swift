import Foundation

/// One assistant's hook contract: the ring it lights, where its user-level hooks file lives, that file's shape,
/// the events Notchmeter registers, the flag its command carries so the app knows the sender before it reads a
/// byte of payload, and the handler dictionary its file wants. Claude Code, Codex, Cursor, Gemini CLI and GitHub
/// Copilot ship. A vendor adds a case here, a parser in Hook+<Tool>.swift and one `case` in Hook.message(from:),
/// and nothing above Hook.Message changes.
enum HookVendor: String, CaseIterable, Identifiable, Equatable, Sendable {
    // The raw values are ToolID's raw values on purpose: `vendor(for:)` is a plain lookup and the two never drift.
    // The declaration order is ToolID's order, which is the rings' order and the Settings rows' order.
    case claude, codex, cursor, antigravity, copilot

    var id: String { rawValue }

    /// The ring the vendor's events light.
    var tool: ToolID {
        switch self {
        case .claude: .claude
        case .codex: .codex
        case .cursor: .cursor
        case .antigravity: .antigravity
        case .copilot: .copilot
        }
    }

    /// The product whose hook this is: the name the Settings rows and the snippet titles use. `.antigravity` is
    /// the one case whose hook is not the ring's namesake: Gemini CLI's hook lights the Antigravity ring, because
    /// the two meter against the same Google backend and the Antigravity IDE's own hooks file documents no
    /// session, prompt or wait event that the notch could act on.
    var displayName: String {
        switch self {
        case .antigravity: "Gemini CLI"
        default: tool.productName
        }
    }

    /// The basename of the hooks file, for button and alert copy.
    var fileName: String {
        switch self {
        case .claude, .antigravity: "settings.json"
        case .codex, .cursor: "hooks.json"
        case .copilot: "notchmeter.json"
        }
    }

    var fileURL: URL { fileURL(environment: ProcessInfo.processInfo.environment) }

    /// Where the user-level hooks file lives, with the vendor's documented override. Claude Code: CLAUDE_CONFIG_DIR,
    /// as before (still the body of HookSettings.settingsURL). Codex: $CODEX_HOME, else ~/.codex — the two places
    /// Codex documents and the only two its own resolver knows — and hooks.json sits beside config.toml in that
    /// folder. The usage reader (CodexProvider.defaultHome) also probes ~/.config/codex, a folder Codex never reads;
    /// that probe is not taken here, so a stray folder there can never make the row read Installed for a file
    /// Codex would not load. Cursor documents no override for `~/.cursor/hooks.json`, so none is invented. Gemini
    /// CLI: GEMINI_CLI_HOME replaces the home directory that `.gemini` is appended to. Copilot: $COPILOT_HOME/hooks/,
    /// else ~/.copilot/hooks/.
    func fileURL(environment: [String: String], home: URL = Paths.home) -> URL {
        switch self {
        case .claude: return HookSettings.settingsURL(environment: environment, home: home)
        case .codex: return CodexProvider.defaultHome(environment: environment, home: home, exists: { _ in false }).appendingPathComponent("hooks.json")
        case .cursor: return home.appendingPathComponent(".cursor/hooks.json")
        case .antigravity:
            let root = environment["GEMINI_CLI_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? home
            return root.appendingPathComponent(".gemini/settings.json")
        case .copilot:
            let root = environment["COPILOT_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
                ?? home.appendingPathComponent(".copilot")
            return root.appendingPathComponent("hooks/notchmeter.json")
        }
    }

    var shape: HookFileShape {
        switch self {
        case .claude, .codex, .antigravity: .nestedGroups
        case .cursor, .copilot: .flatCommands
        }
    }

    /// The events Notchmeter registers, in the order they are written. Claude Code's array in HookSettings stays
    /// the source of truth; every other list is the events the session tracker can act on — the rest of each
    /// vendor's vocabulary (shell, MCP, model and file events) would only cost a process launch per tool call.
    /// Codex's Interrupt ends a turn without a tick; Gemini CLI's BeforeAgent and AfterAgent bracket a turn and its
    /// Notification carries the one documented wait; Copilot's notification is matched to its two waiting types
    /// in `handler(command:event:)`.
    var events: [String] {
        switch self {
        case .claude: HookSettings.events
        case .codex: ["SessionStart", "UserPromptSubmit", "PermissionRequest", "Stop", "Interrupt", "SubagentStart", "SubagentStop", "SessionEnd"]
        case .cursor: ["sessionStart", "beforeSubmitPrompt", "stop", "subagentStart", "subagentStop", "sessionEnd"]
        case .antigravity: ["SessionStart", "BeforeAgent", "AfterAgent", "Notification", "SessionEnd"]
        case .copilot: ["sessionStart", "userPromptSubmitted", "agentStop", "subagentStart", "subagentStop", "notification", "sessionEnd"]
        }
    }

    /// What follows the executable in the command: the base flag, for the copy and for `isNotchmeterHook`. Claude
    /// Code's payload needs no tag; every other vendor names itself so the app never has to guess from the
    /// payload's shape (Codex's and Gemini CLI's payloads are shaped like Claude Code's).
    var flag: String {
        switch self {
        case .claude: "--hook"
        case .codex: "--hook --tool codex"
        case .cursor: "--hook --tool cursor"
        case .antigravity: "--hook --tool antigravity"
        case .copilot: "--hook --tool copilot"
        }
    }

    /// The flag for one event. Copilot's camelCase payloads carry no event name, so each of its entries names its
    /// event on the command line; every other vendor's payload names the event itself.
    func flag(for event: String) -> String {
        self == .copilot ? "\(flag) --event \(event)" : flag
    }

    /// The handler dictionary the vendor's file wants for one event. Only documented keys are written. Claude
    /// Code's and Cursor's are what they have always been, byte for byte. Codex's `timeout` is in seconds;
    /// SessionEnd is documented as always synchronous, and Interrupt shares its 1 s default and 3 s cap, which is why
    /// both entries omit `async` and carry `"timeout": 3`. PermissionRequest stays synchronous too, because an async hook's output lands "at the next safe point", which may be after the
    /// prompt is drawn. Gemini CLI's `timeout` is in milliseconds and it has no `async` field; the `name` is what
    /// its /hooks panel lists. Copilot's `timeoutSec` is its own unit, and its notification entry is matched to the
    /// two types that document a wait so the other four never cost a launch.
    func handler(command: String, event: String) -> [String: Any] {
        switch self {
        case .claude: HookSettings.handler(command: command)
        case .cursor: ["command": command]
        case .codex:
            switch event {
            case "SessionEnd", "Interrupt": ["type": "command", "command": command, "timeout": 3]
            case "PermissionRequest": ["type": "command", "command": command, "timeout": 5]
            default: ["type": "command", "command": command, "async": true, "timeout": 5]
            }
        case .antigravity: ["name": "notchmeter", "type": "command", "command": command, "timeout": 5000]
        case .copilot:
            event == "notification"
                ? ["type": "command", "command": command, "matcher": "permission_prompt|elicitation_dialog", "timeoutSec": 5]
                : ["type": "command", "command": command, "timeoutSec": 5]
        }
    }

    /// Whether the vendor picks a saved file up without a restart; drives the note after Add and Repair. Cursor
    /// reloads hooks.json as soon as it is saved; Codex reads hooks.json when a session starts and skips a new or
    /// changed entry until it is trusted in /hooks; Gemini CLI reads settings.json when it starts; Copilot reads its
    /// hooks directory when it starts.
    var reloadsLive: Bool { self == .cursor }

    /// The vendor whose hook lights `tool`; non-nil for every ToolID now that each has a parser.
    static func vendor(for tool: ToolID) -> HookVendor? {
        HookVendor(rawValue: tool.rawValue)
    }
}

/// How a hooks file nests its command entries. Claude Code, Codex and Gemini CLI nest a `hooks` array of
/// {type, command, …} handlers inside each group; Cursor and GitHub Copilot list command objects directly under
/// the event and want a top-level "version": 1. Copilot's `matcher` sits on the flat element itself, which
/// `handlers(in:)` returns whole and `settingHandlers` writes back whole, so Repair keeps it.
enum HookFileShape: Equatable, Sendable {
    case nestedGroups, flatCommands

    /// The element appended under an event on install: the vendor's handler, wrapped in a group for the nested shape.
    func entry(handler: [String: Any]) -> [String: Any] {
        switch self {
        case .nestedGroups: ["hooks": [handler]]
        case .flatCommands: handler
        }
    }

    /// The command-bearing handlers inside one element of an event's array.
    func handlers(in element: [String: Any]) -> [[String: Any]] {
        switch self {
        case .nestedGroups: element["hooks"] as? [[String: Any]] ?? []
        case .flatCommands: [element]
        }
    }

    /// The element with its handlers replaced (repair writes back through this).
    func settingHandlers(_ handlers: [[String: Any]], in element: [String: Any]) -> [String: Any] {
        switch self {
        case .nestedGroups:
            var updated = element
            updated["hooks"] = handlers
            return updated
        case .flatCommands:
            return handlers.first ?? element
        }
    }

    /// Root keys the file must carry besides "hooks", added only when absent.
    var requiredRootKeys: [String: Any] {
        switch self {
        case .nestedGroups: [:]
        case .flatCommands: ["version": 1]
        }
    }
}
