import Foundation

/// The two-way half of the hook: what a deciding event carries to the app, how it is put on the wire, and what
/// the command prints back to the assistant once the app has answered.
///
/// A permission request or a question is the one event whose payload the notch has to show something of, and
/// the one whose raw input must not leave the hook process: `tool_input` for a `Write` is the whole file, for a
/// `Bash` the whole command, and it lands in the app's memory, its panel and, through `title`, in a screenshot.
/// So the command reduces it to a display summary before it goes: one line naming what the tool wants to do
/// (`summary`), a bounded excerpt of it (`detail`, at most `detailLimit` bytes), the rules the assistant proposed
/// (`suggestions`, the rule strings only), or the questions with their options; and the raw input stays in the
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
            let (summary, detail) = ToolSummary.describe(tool: toolName, input: toolInput)
            return Request(id: id, kind: .permission(tool: toolName, summary: summary, detail: detail,
                                                      suggestions: suggestions(from: object["permission_suggestions"])))
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

    /// The `ruleContent` strings of every rule in `permission_suggestions`, in order, without duplicates. The
    /// array's shape is Claude Code's (`[{type, rules: [{toolName, ruleContent}], behavior, destination}]`);
    /// anything else in it is left where it is.
    static func suggestions(from value: Any?) -> [String] {
        guard let entries = value as? [[String: Any]] else { return [] }
        var seen: Set<String> = []
        var result: [String] = []
        for entry in entries {
            for rule in entry["rules"] as? [[String: Any]] ?? [] {
                guard let content = rule["ruleContent"] as? String, !content.isEmpty, seen.insert(content).inserted else { continue }
                result.append(content)
            }
        }
        return result
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
        static func describe(tool: String, input: [String: Any]) -> (summary: String, detail: String?) {
            let path = string(input["file_path"]) ?? string(input["notebook_path"]) ?? string(input["path"])
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
            if !suggestions.isEmpty { info[suggestionsKey] = suggestions }
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
                                                      suggestions: userInfo?[suggestionsKey] as? [String] ?? []))
        }
        let questions = questions(from: userInfo?[questionsKey])
        return questions.isEmpty ? nil : Request(id: id, kind: .question(questions))
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
        return info
    }

    /// nil when the line carries no terminal key at all, so an event from a hook that could read nothing leaves
    /// the session's terminal as it was.
    static func terminal(userInfo: [AnyHashable: Any]?) -> TerminalRef? {
        func field(_ key: String) -> String? { (userInfo?[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        let terminal = TerminalRef(program: field(terminalProgramKey), bundleID: field(terminalBundleKey), tty: field(terminalTTYKey),
                                   sessionID: field(terminalSessionKey), focusURL: field(terminalFocusURLKey).flatMap(TerminalIdentity.focusURL),
                                   tmux: field(terminalTmuxKey), tmuxPane: field(terminalTmuxPaneKey), kittySocket: field(terminalKittySocketKey),
                                   ghostty: field(terminalGhosttyKey) == "1")
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
            case "allow": return .allow
            case "deny": return .deny(message: body["message"] as? String)
            default: return nil
            }
        }

        /// What the command prints for `event` given the app's reply and the payload it read: Claude Code's
        /// `PermissionRequest` decision (the shape Codex and Copilot's PascalCase event document too), or a
        /// `PreToolUse` allow whose `updatedInput` is the tool's input unchanged plus the `answers`. nil, and so
        /// nothing printed, for a pass, a reply that is no decision, an answer to a permission or a permission to a
        /// question, or a payload the command can no longer read; the terminal then asks.
        static func output(event: String, reply: Data, payload: Data) -> String? {
            guard let decision = decision(from: reply) else { return nil }
            let object: [String: Any]
            switch (event, decision) {
            case ("PermissionRequest", .allow):
                object = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": ["behavior": "allow"]]]
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
    }
}

private extension String {
    /// Whether `index`, a UTF-8 view index, falls on a character boundary.
    func isValidIndex(_ index: String.Index) -> Bool {
        index == endIndex || index.samePosition(in: self) != nil
    }
}
