import Foundation

/// The Claude Code hook events the 0.11 round added, and what the command keeps of each: the lifecycle events that
/// were on Claude Code's list and not on Notchmeter's (docs/hooks.md, *The events and what each one keeps*). Every
/// reducer here reads the one or two fields its feature needs and bounds them before they leave the process; the
/// rest of each payload — a failed tool's `error`, a compaction's summary, the tool calls of a batch, an auto-mode
/// denial's `reason`, an MCP answer's `content` — never leaves the command, because none of it is needed to say
/// what the notch says, and most of it is the user's work.
///
/// Three events that Claude Code documents and that the report asked for are deliberately not registered, and the
/// reasons are Claude Code's own contract rather than taste: `WorktreeCreate` replaces git's own worktree creation
/// and must print the path it made, so an entry of ours (which prints nothing) would fail every `--worktree`
/// session, every `isolation: "worktree"` subagent and every background session; `WorktreeRemove` fails a removal
/// on any non-zero exit, a crash or a timeout of ours included; and `PreModelSwitch` runs in sequence before the
/// switch it announces, so a process launch of ours would sit in front of every `/model`. `CwdChanged` (the move
/// into a worktree as it happens) and `PostModelSwitch` (the switch once made) carry what the notch needs of both.
extension Hook {
    /// The one 0.11 event that fires often: once per model step that ran tools. The others fire on a compaction, a
    /// model switch, an MCP request for input, a teammate going idle, a failed or auto-denied tool call, or a change
    /// of directory.
    static let batchEvent = "PostToolBatch"

    /// The 0.11 events, none of which asks for a meter read. Each reports something that happened inside a turn —
    /// a batch, a failure, a denial, a compaction, a switch, a move, an MCP request, a teammate going idle — and none
    /// of it is spend that the turn's own `Stop` does not report when the turn ends, while one of them arrives with
    /// every model step. So they change the session and leave the meter alone: the card redraws at the step, and
    /// the vendor's endpoint is asked no more often than before they were registered (UsageStore.hookReceived).
    static let quietEvents: Set<String> = ["PreCompact", "PostCompact", "PostModelSwitch", "Elicitation", "ElicitationResult", "TeammateIdle",
                                           "PostToolUseFailure", "PermissionDenied", batchEvent, "CwdChanged"]

    /// How far a batch boundary may move a session's clock before the change is worth publishing on its own:
    /// under this, a boundary that changes nothing else is kept from the views and the panel's measure, which
    /// would otherwise redraw once per model step to show a timestamp no view prints.
    static let batchSlack: TimeInterval = 60

    /// The events whose payload can run past what the command reads (64 KB within 25 ms): a batch carries every
    /// tool's response in full, a failure or a denial its tool's input, a compaction its summary. For these alone
    /// a payload cut short is read up to its first bulky field (`headObject`), which is where the fields the command
    /// keeps sit. No deciding event is on the list: a request shown without the input it asks about would be one the
    /// user could approve blind.
    static let headEvents: Set<String> = [batchEvent, "PostToolUseFailure", "PermissionDenied", "PostCompact"]

    /// The fields a head is cut before. Each is a value that can be large, and each comes after the common fields
    /// in Claude Code's payloads (the hooks reference's examples, 2026-09-24), so what precedes the first of them is
    /// the event's name, the session, the working directory and the tool's name.
    static let bulkyKeys = ["tool_calls", "tool_input", "tool_response", "compact_summary", "error", "reason", "content", "requested_schema"]

    /// The top-level fields of a payload cut short, read up to the first bulky field: the bytes before it, closed
    /// with a brace, parsed as JSON. nil when no bulky field is found or the head does not parse. A key's name
    /// cannot occur unescaped inside a string value (its quotes would be escaped there), so the first `"<key>":` in
    /// the bytes is the top-level one. Searched as bytes, each key only in front of the earliest cut found so far,
    /// so the common case — the batch's `tool_calls` a few hundred bytes in — costs a few hundred bytes of search
    /// rather than eight passes over 64 KB of text.
    static func headObject(of payload: Data) -> [String: Any]? {
        let whitespace: Set<UInt8> = [0x20, 0x0A, 0x0D, 0x09]
        var cut = payload.endIndex
        var found = false
        for key in bulkyKeys {
            let needle = Data("\"\(key)\"".utf8)
            var from = payload.startIndex
            while from < cut, let range = payload.range(of: needle, in: from..<cut) {
                var next = range.upperBound
                while next < payload.endIndex, whitespace.contains(payload[next]) { next += 1 }
                if next < payload.endIndex, payload[next] == UInt8(ascii: ":") {
                    cut = range.lowerBound
                    found = true
                    break
                }
                from = range.upperBound
            }
        }
        guard found else { return nil }
        var end = cut
        while end > payload.startIndex, whitespace.contains(payload[end - 1]) { end -= 1 }
        if end > payload.startIndex, payload[end - 1] == UInt8(ascii: ",") { end -= 1 }
        var head = Data(payload[payload.startIndex..<end])
        head.append(UInt8(ascii: "}"))
        return (try? JSONSerialization.jsonObject(with: head)) as? [String: Any]
    }

    /// The project a working directory belongs to (ProjectName: the folder's name, or the repository's when the
    /// folder is a git worktree) and whether it is a worktree, from one walk of its `.git`: the resolver keeps the
    /// answer it found for the name, so asking again for the worktree costs no second stat. The worktree's own
    /// folder name is never kept, only that there is one, which is what a row needs to say "worktree" beside the
    /// branch the worktree has checked out.
    static func place(ofPath path: String) -> (project: String?, worktree: Bool) {
        let resolver = ProjectName.Resolver()
        let project = resolver.name(ofPath: path)
        return (project, resolver.repository(containing: URL(fileURLWithPath: path).standardizedFileURL) != nil)
    }

    // MARK: - Bounded names

    /// The longest tool, model or server name kept. Claude Code's MCP tool names (`mcp__server__tool`) and its
    /// provider model ids are the longest of them and sit well under it.
    static let nameLimit = 128
    /// The longest teammate or MCP server name kept: a name, not a sentence.
    static let shortNameLimit = 64

    /// A name as the notch shows it: the first line, its whitespace collapsed, at most `limit` characters with an
    /// ellipsis; nil for anything that is not a non-empty string.
    static func shortName(_ value: Any?, limit: Int = shortNameLimit) -> String? {
        guard let text = value as? String else { return nil }
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let collapsed = firstLine.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// A tool's name (`Bash`, `mcp__github__create_issue`) as a failure or a denial carries it: at most
    /// `nameLimit` characters, one line, nothing a tool name does not contain.
    static func toolName(_ value: Any?) -> String? {
        guard let name = value as? String, !name.isEmpty, name.count <= nameLimit,
              name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && !CharacterSet.whitespacesAndNewlines.contains($0) })
        else { return nil }
        return name
    }

    /// A model id as `PostModelSwitch` carries it (`claude-opus-5`, `claude-sonnet-4-6[1m]`, a Bedrock id such as
    /// `us.anthropic.claude-opus-4-6-v1:0`, or whatever a gateway names its model): kept only when it is shaped
    /// like an id, so a field that carried anything else carries nothing.
    static func modelID(_ value: Any?) -> String? {
        guard let id = value as? String, !id.isEmpty, id.count <= nameLimit else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._:/@[]"))
        return id.unicodeScalars.allSatisfy(allowed.contains) ? id : nil
    }

    /// "Opus 4.6" for `claude-opus-4-6`, "Sonnet 3.5" for `claude-3-5-sonnet-20241022`, "Opus 4.6" for the Bedrock
    /// `us.anthropic.claude-opus-4-6-v1:0`: the family and its version, the way Claude Code's status line names a
    /// model, so a row does not change its words when the status line and a switch take turns. A context suffix
    /// (`[1m]`), a date, a provider prefix and a version tail are dropped; an id that names no Claude family is shown
    /// as it came, because a gateway's name for its own model is the only name there is.
    static func modelDisplayName(_ id: String) -> String {
        var core = id
        if let bracket = core.firstIndex(of: "[") { core = String(core[..<bracket]) }
        guard let claude = core.range(of: "claude-") else { return id }
        core = String(core[claude.upperBound...])
        if let at = core.firstIndex(of: "@") { core = String(core[..<at]) }
        if let tail = core.range(of: #"-v\d+(:\d+)?$"#, options: .regularExpression) { core.removeSubrange(tail) }
        let parts = core.split(separator: "-").map(String.init).filter { !($0.count == 8 && $0.allSatisfy(\.isNumber)) }
        guard let family = parts.first(where: { $0.first?.isLetter == true }) else { return id }
        let version = parts.filter { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
        let name = family.prefix(1).uppercased() + family.dropFirst()
        return version.isEmpty ? name : "\(name) \(version.joined(separator: "."))"
    }

    // MARK: - Per event

    /// `trigger` on `PreCompact` and `PostCompact`: `manual` for `/compact`, `auto` when the conversation reached the
    /// auto-compact window. `custom_instructions` (what the user typed after `/compact`) and `compact_summary` (the
    /// conversation, summarised) are never read.
    static func compactionTrigger(_ value: Any?) -> Compaction.Trigger? {
        (value as? String).flatMap(Compaction.Trigger.init(rawValue:))
    }

    /// `PostModelSwitch`'s `to_model`, `from_model` and `source`; nil without a `to_model` shaped like an id. The
    /// cost fields beside them (`context_tokens`, `estimated_cache_write_usd`, `pricing`, `prompt_cache_warm`,
    /// `cache_ttl`) and `requested_model` are left in the payload: the notch shows the model a session runs on and
    /// how it got there, not what the switch cost.
    static func modelSwitch(object: [String: Any]) -> ModelSwitch? {
        guard let to = modelID(object["to_model"]) else { return nil }
        return ModelSwitch(from: modelID(object["from_model"]), to: to,
                           source: (object["source"] as? String).flatMap(ModelSwitch.Source.init(rawValue:)))
    }

    /// `PostToolUseFailure`'s `tool_name` and `is_interrupt`; never `error` (the failed command's output, the file
    /// it could not write) or `tool_input`. nil without a tool name.
    static func toolFailure(object: [String: Any]) -> ToolFailure? {
        guard let tool = toolName(object["tool_name"]) else { return nil }
        return ToolFailure(tool: tool, interrupt: object["is_interrupt"] as? Bool == true)
    }

    /// `PermissionDenied`'s `tool_name`, and which of the documented kinds of denial it was, told from the shape of
    /// `reason` without keeping a character of it: a rule the classifier matched (`[Data Exfiltration]`), a denial
    /// without a verdict, or the classifier being unavailable. The reason itself is free text, and can quote the
    /// action, so it stays in the command. nil without a tool name.
    static func denial(object: [String: Any]) -> Denial? {
        guard let tool = toolName(object["tool_name"]) else { return nil }
        return Denial(tool: tool, kind: Denial.Kind(reason: object["reason"] as? String))
    }

    /// How many tool calls `PostToolBatch` resolved: the length of `tool_calls`, and nothing of any call in it.
    /// nil when the array is absent, which is what a payload read only up to its head looks like.
    static func batchSize(object: [String: Any]) -> Int? {
        (object["tool_calls"] as? [Any])?.count
    }
}

/// A compaction, as `PreCompact` and `PostCompact` report it.
enum Compaction {
    enum Trigger: String, Equatable, Sendable {
        case manual, auto
    }
}

/// A switch of the session's model, as `PostModelSwitch` reports it once made.
struct ModelSwitch: Equatable, Sendable {
    /// Where it came from: `/model` or the Model setting (`command`), a picker, an SDK host or Remote Control
    /// (`sdk`), Claude Code falling back or changing the model by itself (`auto`), or the model restored on resume.
    enum Source: String, Equatable, Sendable {
        case command, picker, sdk, auto, resume
    }

    var from: String?
    var to: String
    var source: Source?

    /// Whether Claude Code made the change by itself, which is the one a reader did not ask for.
    var isFallback: Bool { source == .auto }
}

/// A tool call that started and failed, as `PostToolUseFailure` reports it.
struct ToolFailure: Equatable, Sendable {
    var tool: String
    /// True when the failure reached Claude Code as an abort rather than an error the tool reported. Not counted
    /// towards a session looking stuck: an abort is something that happened to the agent, not something it tried.
    var interrupt: Bool
}

/// A tool call auto mode denied, as `PermissionDenied` reports it: only auto mode's classifier fires it, never a
/// denial the user made at a prompt, a `deny` rule or another hook.
struct Denial: Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        /// The classifier matched a rule: `reason` names it in square brackets.
        case rule
        /// "Auto mode could not evaluate this action and is blocking it for safety".
        case noVerdict
        /// "Classifier unavailable".
        case unavailable
        /// Any other reason, or none.
        case other

        init(reason: String?) {
            let trimmed = reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if trimmed.hasPrefix("["), trimmed.contains("]") {
                self = .rule
            } else if trimmed.hasPrefix("Auto mode could not evaluate") {
                self = .noVerdict
            } else if trimmed == "Classifier unavailable" {
                self = .unavailable
            } else {
                self = .other
            }
        }
    }

    var tool: String
    var kind: Kind
}

/// A teammate of an agent team that went idle, as `TeammateIdle` names it. `key` tells two teammates apart and is
/// the name itself while *Show what a session is working on* is on; off, the store replaces it with an opaque key
/// and drops the name before the tracker holds either (UsageStore.hookReceived), since the lead names its
/// teammates after the work.
struct Teammate: Equatable, Sendable {
    var key: String
    var name: String?

    /// A key for a teammate whose name may not be held: a hash of the name with this process's seed, which tells
    /// the same teammate apart from another for as long as the app runs and cannot be read back into the name.
    static func opaqueKey(for name: String) -> String {
        var hasher = Hasher()
        hasher.combine(name)
        return "teammate-\(UInt(bitPattern: hasher.finalize()))"
    }
}

/// A value with the moment the app heard it, for the lists a session row opens: model switches, idle teammates and
/// auto-mode denials.
struct Stamped<Value: Equatable & Sendable>: Equatable, Sendable {
    var value: Value
    var at: Date
}

/// Something a session ran into that it did not stop for, and that the user may want to know without having to
/// answer it: a compaction Claude Code began by itself, a run of failed tool calls, or auto mode refusing a tool.
/// Each is a notice of its own (Notifier.SessionEvent.trouble) and a word beside the notch (NotchNews), and each is
/// on the session's row whether or not either is shown.
enum SessionTrouble: Equatable, Sendable {
    /// `context` is the fill the session's status line last reported before the compaction began, when it had.
    case compacting(context: Double?)
    case stuck(failures: Int)
    case blocked(tool: String)

    /// The notice's identifier suffix and the oracle's word.
    var name: String {
        switch self {
        case .compacting: "compacting"
        case .stuck: "stuck"
        case .blocked: "blocked"
        }
    }
}
