import Foundation

/// The two-way half of the hook: what a deciding event carries to the app, how it is put on the wire, and what
/// the command prints back to the assistant once the app has answered.
///
/// A permission request or a question is the one event whose payload the notch has to show something of, and
/// the one whose raw input must not leave the hook process: `tool_input` for a `Write` is the whole file, for a
/// `Bash` the whole command, and it lands in the app's memory, its panel and, through `title`, in a screenshot.
/// So the command reduces it to a display summary before it goes: one line naming what the tool wants to do
/// (`summary`), a bounded excerpt of it (`detail`, at most `detailLimit` bytes), the rules the assistant proposed
/// (`suggestions`, the allow rules, directories or edit mode each would grant and where it would be written,
/// with its position in the array), or the questions with their options; and the raw input stays in the
/// command, which needs it once more only to echo it back inside an answer (`Answer.output`). The app's side
/// never sees `tool_input`, and docs/hooks.md lists what it sees instead.
extension Hook {
    /// The prompt's first line, its whitespace collapsed, at most `titleLimit` characters with an ellipsis; nil
    /// for anything that is not a non-empty string.
    static func title(fromPrompt value: Any?) -> String? {
        guard let prompt = value as? String else { return nil }
        let firstLine = prompt.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let collapsed = firstLine.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        guard collapsed.count > titleLimit else { return collapsed }
        return String(collapsed.prefix(titleLimit)).trimmingCharacters(in: .whitespaces) + "…"
    }

    static let titleLimit = 96
    /// The most a `detail` carries, in UTF-8 bytes.
    static let detailLimit = 4 * 1024
    /// How many lines of a `Write`'s content the detail shows before it says how many more there are.
    static let writeDetailLines = 40

    /// The request a Claude-shaped payload carries, or nil for every event that is not one: a `PermissionRequest`
    /// with a `tool_name`, or a `PreToolUse` whose tool is `AskUserQuestion` with at least one question. Codex's
    /// and Copilot's parsers call the same function, since their deciding payloads are Claude-shaped too.
    static func request(event: String, object: [String: Any], id: String) -> Request? {
        let toolName = (object["tool_name"] as? String) ?? (object["toolName"] as? String)
        let toolInput = (object["tool_input"] as? [String: Any]) ?? (object["toolInput"] as? [String: Any]) ?? [:]
        switch event {
        case "PermissionRequest":
            guard let toolName, !toolName.isEmpty else { return nil }
            let (summary, detail) = ToolSummary.describe(tool: toolName, input: toolInput, cwd: object["cwd"] as? String)
            return Request(id: id, kind: .permission(tool: toolName, summary: summary, detail: detail,
                                                      suggestions: suggestions(from: object["permission_suggestions"], cwd: object["cwd"] as? String)))
        case "PreToolUse":
            guard toolName == askUserQuestionTool else { return nil }
            let questions = questions(from: toolInput["questions"])
            guard !questions.isEmpty else { return nil }
            return Request(id: id, kind: .question(questions))
        default:
            return nil
        }
    }

    static let askUserQuestionTool = "AskUserQuestion"

    /// The entries of `permission_suggestions` the card can offer as *Allow always*, in order, a repeat dropped.
    /// The array's shape is Claude Code's (docs/hooks.md, "Permission update entries"): each entry a `type` with
    /// its fields and a `destination`. `index` is always the entry's position in the array as it came, so a
    /// skipped entry does not shift the ones after it (`Answer.output` echoes the entry at that position).
    static func suggestions(from value: Any?, cwd: String? = nil, home: String = NSHomeDirectory()) -> [PendingRequest.Suggestion] {
        guard let entries = value as? [Any] else { return [] }
        var result: [PendingRequest.Suggestion] = []
        for (index, entry) in entries.enumerated() {
            guard let suggestion = suggestion(from: entry, index: index, cwd: cwd, home: home),
                  !result.contains(where: { $0.grant == suggestion.grant && $0.place == suggestion.place }) else { continue }
            result.append(suggestion)
        }
        return result
    }

    /// One entry as the card would offer it, or nil for one it would not. Only updates that widen what runs
    /// without asking are offered, because the button says *Allow always*: `addRules` with `behavior` `allow`
    /// (each rule `Tool(content)`, or the tool's name alone when it has no content), `addDirectories`, and
    /// `setMode` to `acceptEdits`. A deny or ask rule, a replace or remove, and any other mode (`bypassPermissions`
    /// above all) are left to the terminal, which can explain them better than a one-line button could. The
    /// command runs the same check before it echoes an entry, so a reply naming any other index is a plain allow.
    static func suggestion(from value: Any?, index: Int, cwd: String? = nil, home: String = NSHomeDirectory()) -> PendingRequest.Suggestion? {
        guard let entry = value as? [String: Any] else { return nil }
        let place = (entry["destination"] as? String).flatMap(PendingRequest.Suggestion.Place.init(rawValue:))
        let grant: PendingRequest.Suggestion.Grant
        switch entry["type"] as? String {
        case "addRules":
            guard entry["behavior"] as? String == "allow" else { return nil }
            var rules: [String] = []
            for rule in entry["rules"] as? [[String: Any]] ?? [] {
                guard let tool = rule["toolName"] as? String, !tool.isEmpty else { continue }
                let content = (rule["ruleContent"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                let text = content.map { "\(tool)(\($0))" } ?? tool
                if !rules.contains(text) { rules.append(text) }
            }
            guard !rules.isEmpty else { return nil }
            grant = .rules(rules)
        case "addDirectories":
            let directories = (entry["directories"] as? [Any] ?? []).compactMap { ($0 as? String).flatMap { $0.isEmpty ? nil : $0 } }
            guard !directories.isEmpty else { return nil }
            grant = .directories(directories.map { ToolSummary.shortened($0, cwd: cwd, home: home) })
        case "setMode":
            guard entry["mode"] as? String == "acceptEdits" else { return nil }
            grant = .acceptEdits
        default:
            return nil
        }
        return PendingRequest.Suggestion(index: index, grant: grant, place: place)
    }

    /// `AskUserQuestion`'s `questions` array as the tracker's type: each with its text, its short header, its
    /// options (label and an optional description) and whether several may be chosen. A question without text
    /// or without an option is dropped, since the notch could not ask it.
    static func questions(from value: Any?) -> [PendingRequest.Question] {
        guard let entries = value as? [[String: Any]] else { return [] }
        return entries.compactMap { entry in
            guard let text = entry["question"] as? String, !text.isEmpty else { return nil }
            let options = (entry["options"] as? [[String: Any]] ?? []).compactMap { option -> PendingRequest.Option? in
                guard let label = option["label"] as? String, !label.isEmpty else { return nil }
                return PendingRequest.Option(label: label, description: (option["description"] as? String).flatMap { $0.isEmpty ? nil : $0 })
            }
            guard !options.isEmpty else { return nil }
            return PendingRequest.Question(text: text, header: entry["header"] as? String ?? "", options: options,
                                           multiSelect: entry["multiSelect"] as? Bool ?? false)
        }
    }

    /// One line and a bounded excerpt for a tool's input, per tool. The rules are Claude Code's tool vocabulary
    /// (Codex's `apply_patch` and MCP names fall through to the generic ones): a shell command's first line and
    /// the whole command; a file tool's path and, for `Edit`, the old and new text as `-`/`+` lines, for `Write`,
    /// the first forty lines of the content; an MCP tool's name alone. Anything else names the tool and shows
    /// whichever of a few well-known input fields it carries.
    enum ToolSummary {
        static func describe(tool: String, input: [String: Any], cwd: String? = nil,
                             home: String = NSHomeDirectory()) -> (summary: String, detail: String?) {
            let path = (string(input["file_path"]) ?? string(input["notebook_path"]) ?? string(input["path"]))
                .map { shortened($0, cwd: cwd, home: home) }
            switch tool {
            case "Edit", "MultiEdit":
                let old = string(input["old_string"]) ?? ""
                let new = string(input["new_string"]) ?? ""
                let diff = old.split(separator: "\n", omittingEmptySubsequences: false).map { "- \($0)" }
                    + new.split(separator: "\n", omittingEmptySubsequences: false).map { "+ \($0)" }
                return (path ?? tool, old.isEmpty && new.isEmpty ? nil : bounded(diff.joined(separator: "\n")))
            case "Write":
                let content = string(input["content"]) ?? ""
                let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
                var shown = lines.prefix(writeDetailLines).joined(separator: "\n")
                if lines.count > writeDetailLines { shown += "\n… (\(lines.count - writeDetailLines) more lines)" }
                return (path ?? tool, content.isEmpty ? nil : bounded(shown))
            case "Read", "NotebookEdit", "NotebookRead":
                return (path ?? tool, nil)
            default:
                if tool.hasPrefix("mcp__") { return (tool, string(input["description"]).map(bounded)) }
                if let command = string(input["command"]) { return (firstLine(of: command), bounded(command)) }
                if let path { return (path, nil) }
                if let field = ["url", "pattern", "query", "description", "prompt"].lazy.compactMap({ string(input[$0]) }).first {
                    return (firstLine(of: field), nil)
                }
                return (tool, nil)
            }
        }

        /// A path as the card names it: relative to the session's working directory when it is under it (the
        /// project is already a chip on the card), else with the home folder as `~`, else as it came. The full
        /// path is what the tool gets; only the summary is shortened.
        static func shortened(_ path: String, cwd: String?, home: String) -> String {
            if let cwd, !cwd.isEmpty {
                let base = cwd.hasSuffix("/") ? cwd : cwd + "/"
                if path.hasPrefix(base), path.count > base.count { return String(path.dropFirst(base.count)) }
                if path == cwd { return "." }
            }
            if !home.isEmpty {
                let base = home.hasSuffix("/") ? home : home + "/"
                if path.hasPrefix(base) { return "~/" + path.dropFirst(base.count) }
            }
            return path
        }

        private static func string(_ value: Any?) -> String? {
            (value as? String).flatMap { $0.isEmpty ? nil : $0 }
        }

        static func firstLine(of text: String) -> String {
            let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
            return line.trimmingCharacters(in: .whitespaces)
        }

        /// `text` cut to `detailLimit` bytes on a character boundary, with an ellipsis when it was cut.
        static func bounded(_ text: String) -> String {
            guard text.utf8.count > Hook.detailLimit else { return text }
            var end = text.utf8.index(text.utf8.startIndex, offsetBy: Hook.detailLimit)
            while end > text.startIndex, !text.isValidIndex(end) { end = text.utf8.index(before: end) }
            return String(text[..<end]) + "…"
        }
    }

    // MARK: - The wire

    static func userInfo(request: Request) -> [String: Any] {
        var info: [String: Any] = [awaitsDecisionKey: true, requestIDKey: request.id]
        switch request.kind {
        case .permission(let tool, let summary, let detail, let suggestions):
            info[toolNameKey] = tool
            info[toolSummaryKey] = summary
            if let detail { info[toolDetailKey] = detail }
            if !suggestions.isEmpty { info[suggestionsKey] = suggestions.map(wire(suggestion:)) }
        case .question(let questions):
            info[questionsKey] = questions.map { question -> [String: Any] in
                ["question": question.text, "header": question.header, "multiSelect": question.multiSelect,
                 "options": question.options.map { option -> [String: Any] in
                     var entry: [String: Any] = ["label": option.label]
                     if let description = option.description { entry["description"] = description }
                     return entry
                 }]
            }
        }
        return info
    }

    /// A request is read back only when the line says it awaits a decision and names its id; a permission needs
    /// its tool and summary, a question at least one question. Anything less is no request, and the event lands
    /// as the display-only wait it always was.
    static func request(userInfo: [AnyHashable: Any]?) -> Request? {
        guard userInfo?[awaitsDecisionKey] as? Bool == true, let id = userInfo?[requestIDKey] as? String, !id.isEmpty else { return nil }
        if let tool = userInfo?[toolNameKey] as? String, let summary = userInfo?[toolSummaryKey] as? String {
            return Request(id: id, kind: .permission(tool: tool, summary: summary, detail: userInfo?[toolDetailKey] as? String,
                                                      suggestions: (userInfo?[suggestionsKey] as? [Any] ?? []).compactMap(suggestion(wire:))))
        }
        let questions = questions(from: userInfo?[questionsKey])
        return questions.isEmpty ? nil : Request(id: id, kind: .question(questions))
    }

    /// A suggestion on the line: `index`, then exactly one of `rules` or `directories` (string arrays) or `mode`
    /// (`acceptEdits`), and `destination` when it is one Claude Code documents.
    static func wire(suggestion: PendingRequest.Suggestion) -> [String: Any] {
        var entry: [String: Any] = ["index": suggestion.index]
        switch suggestion.grant {
        case .rules(let rules): entry["rules"] = rules
        case .directories(let directories): entry["directories"] = directories
        case .acceptEdits: entry["mode"] = "acceptEdits"
        }
        if let place = suggestion.place { entry["destination"] = place.rawValue }
        return entry
    }

    /// The suggestion a line's entry carries, or nil for one without a non-negative index or a grant. A 0.7.x
    /// command sent bare rule strings here; those read as no suggestion, so its card offers plain Allow only.
    static func suggestion(wire value: Any) -> PendingRequest.Suggestion? {
        guard let entry = value as? [String: Any], let index = entry["index"] as? Int, index >= 0 else { return nil }
        func strings(_ key: String) -> [String] {
            (entry[key] as? [Any] ?? []).compactMap { ($0 as? String).flatMap { $0.isEmpty ? nil : $0 } }
        }
        let grant: PendingRequest.Suggestion.Grant
        if !strings("rules").isEmpty {
            grant = .rules(strings("rules"))
        } else if !strings("directories").isEmpty {
            grant = .directories(strings("directories"))
        } else if entry["mode"] as? String == "acceptEdits" {
            grant = .acceptEdits
        } else {
            return nil
        }
        let place = (entry["destination"] as? String).flatMap(PendingRequest.Suggestion.Place.init(rawValue:))
        return PendingRequest.Suggestion(index: index, grant: grant, place: place)
    }

    static func userInfo(terminal: TerminalRef) -> [String: Any] {
        var info: [String: Any] = [:]
        if let program = terminal.program { info[terminalProgramKey] = program }
        if let bundleID = terminal.bundleID { info[terminalBundleKey] = bundleID }
        if let tty = terminal.tty { info[terminalTTYKey] = tty }
        if let sessionID = terminal.sessionID { info[terminalSessionKey] = sessionID }
        if let focusURL = terminal.focusURL { info[terminalFocusURLKey] = focusURL }
        if let tmux = terminal.tmux { info[terminalTmuxKey] = tmux }
        if let tmuxPane = terminal.tmuxPane { info[terminalTmuxPaneKey] = tmuxPane }
        if let kittySocket = terminal.kittySocket { info[terminalKittySocketKey] = kittySocket }
        if terminal.ghostty { info[terminalGhosttyKey] = "1" }
        if let workspace = terminal.workspace { info[terminalWorkspaceKey] = workspace }
        return info
    }

    /// nil when the line carries no terminal key at all, so an event from a hook that could read nothing leaves
    /// the session's terminal as it was.
    static func terminal(userInfo: [AnyHashable: Any]?) -> TerminalRef? {
        func field(_ key: String) -> String? { (userInfo?[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        let terminal = TerminalRef(program: field(terminalProgramKey), bundleID: field(terminalBundleKey), tty: field(terminalTTYKey),
                                   sessionID: field(terminalSessionKey), focusURL: field(terminalFocusURLKey).flatMap(TerminalIdentity.focusURL),
                                   tmux: field(terminalTmuxKey), tmuxPane: field(terminalTmuxPaneKey), kittySocket: field(terminalKittySocketKey),
                                   ghostty: field(terminalGhosttyKey) == "1",
                                   workspace: field(terminalWorkspaceKey).flatMap(TerminalJump.validWorkspace))
        return terminal.isEmpty ? nil : terminal
    }

    // MARK: - The answer

    /// The reply line the app writes back on the socket, `{"decision":{…}}`, and what the command prints to the
    /// assistant on reading it. The app's line is the app's own vocabulary (allow, deny with a message, answers by
    /// question, or nothing for a pass); the printed JSON is the vendor's, and one shape serves Claude Code,
    /// Codex and Copilot's PascalCase event alike, which is why the command and not the app renders it: the app
    /// says what the user chose, and the command, which knows the event, says it in the vendor's words.
    enum Answer {
        static let deniedMessage = "Denied from Notchmeter"

        /// The line the app writes: nil for a pass, which is answered by hanging up with nothing.
        static func line(for decision: Decision) -> Data? {
            let body: [String: Any]
            switch decision {
            case .allow: body = ["behavior": "allow"]
            case .allowAlways(let index): body = ["behavior": "allow", "suggestion": index]
            case .deny(let message): body = ["behavior": "deny", "message": message ?? deniedMessage]
            case .answers(let answers): body = ["answers": answers]
            case .pass: return nil
            }
            guard var data = try? JSONSerialization.data(withJSONObject: ["decision": body], options: [.sortedKeys]) else { return nil }
            data.append(0x0A)
            return data
        }

        /// The decision a reply line carries, or nil for an empty reply or one that is not a decision.
        static func decision(from reply: Data) -> Decision? {
            guard let object = try? JSONSerialization.jsonObject(with: reply) as? [String: Any],
                  let body = object["decision"] as? [String: Any] else { return nil }
            if let answers = body["answers"] as? [String: String], !answers.isEmpty { return .answers(answers) }
            switch body["behavior"] as? String {
            case "allow":
                if let index = body["suggestion"] as? Int, index >= 0 { return .allowAlways(suggestion: index) }
                return .allow
            case "deny": return .deny(message: body["message"] as? String)
            default: return nil
            }
        }

        /// What the command prints for `event` given the app's reply and the payload it read: Claude Code's
        /// `PermissionRequest` decision (the shape Codex and Copilot's PascalCase event document too; *Allow always*
        /// adds `updatedPermissions` with the one suggestion chosen, `offeredEntry(at:payload:)`), or a
        /// `PreToolUse` allow whose `updatedInput` is the tool's input unchanged plus the `answers`. nil, and so
        /// nothing printed, for a pass, a reply that is no decision, an answer to a permission or a permission to a
        /// question, or a payload the command can no longer read; the terminal then asks.
        static func output(event: String, reply: Data, payload: Data) -> String? {
            guard let decision = decision(from: reply) else { return nil }
            let object: [String: Any]
            switch (event, decision) {
            case ("PermissionRequest", .allow):
                object = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": ["behavior": "allow"]]]
            case ("PermissionRequest", .allowAlways(let index)):
                var allow: [String: Any] = ["behavior": "allow"]
                if let entry = offeredEntry(at: index, payload: payload) { allow["updatedPermissions"] = [entry] }
                object = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": allow]]
            case ("PermissionRequest", .deny(let message)):
                object = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": ["behavior": "deny", "message": message ?? deniedMessage]]]
            case ("PreToolUse", .answers(let answers)):
                guard let payload = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
                      var input = payload["tool_input"] as? [String: Any] else { return nil }
                input["answers"] = answers
                object = ["hookSpecificOutput": ["hookEventName": "PreToolUse", "permissionDecision": "allow", "updatedInput": input]]
            default:
                return nil
            }
            guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else { return nil }
            return String(decoding: data, as: UTF8.self)
        }

        /// The `permission_suggestions` entry at `index` in the payload, exactly as Claude Code sent it, when it
        /// is one the card could have offered (`Hook.suggestion(from:index:)`). Echoing the assistant's own entry,
        /// which Claude Code documents as a valid `updatedPermissions` item, means the app never writes a rule,
        /// and a reply naming an entry the card would not offer (a deny rule, `bypassPermissions`) cannot turn
        /// into one. nil otherwise, and the answer is then a plain allow: the user did say yes to this call.
        static func offeredEntry(at index: Int, payload: Data) -> [String: Any]? {
            guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
                  let entries = object["permission_suggestions"] as? [Any], entries.indices.contains(index),
                  let entry = entries[index] as? [String: Any], Hook.suggestion(from: entry, index: index) != nil else { return nil }
            return entry
        }
    }
}

private extension String {
    /// Whether `index`, a UTF-8 view index, falls on a character boundary.
    func isValidIndex(_ index: String.Index) -> Bool {
        index == endIndex || index.samePosition(in: self) != nil
    }
}
