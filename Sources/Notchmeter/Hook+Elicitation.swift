import Foundation

/// An MCP server asking the user for input in the middle of a tool call (Claude Code's `Elicitation` event), and the
/// one kind of it the notch can answer.
///
/// Claude Code documents a hook decision for this event: `hookSpecificOutput` with an `action` (`accept`, `decline`,
/// `cancel`) and, to accept, the form's `content`, which skips its own dialog. So the protocol allows an answer
/// from the notch, and the question is only which requests a click can answer honestly. A form whose every field is
/// a fixed choice (an `enum`, or a `oneOf` of `const` values) or a yes-or-no, at most `fieldLimit` of them, and a
/// form with no fields at all (a confirmation), can be: every value the notch could send is one the server itself
/// listed. Anything else — a text or number field (the reference's own example asks for a username), a URL-mode
/// request (a sign-in in the browser), a schema the command cannot read — is shown as a wait and handed to the
/// terminal at once: the command sends it without a request, returns in milliseconds, and Claude Code draws its
/// dialog as it always has. Nothing typed ever crosses the socket, in either direction.
///
/// The `Elicitation` entry is synchronous for that reason (HookVendor.decidingEvents), and costs nothing more than
/// a millisecond or two when no request is made. The answer is checked again by the command against the payload
/// it read before it is printed (`Answer.output`), so a reply naming a field or a value the server did not offer
/// prints nothing and the dialog appears. `ElicitationResult`, which Claude Code runs after the user responds, ends
/// the wait; its `content`, the user's answer, is never read.
extension PendingRequest {
    struct Elicitation: Equatable, Sendable {
        struct Option: Equatable, Sendable {
            /// What goes back to the server, exactly as its schema listed it.
            var value: String
            /// What the button says: the schema's `enumNames` entry or `oneOf` title, else the value.
            var label: String
        }

        struct Field: Equatable, Sendable {
            enum Kind: Equatable, Sendable {
                case choice([Option])
                case toggle
            }

            var key: String
            /// The property's `title`, else its key.
            var title: String
            /// The property's `description`, one line.
            var detail: String?
            var kind: Kind
            var required: Bool
        }

        /// `mcp_server_name`; nil when the payload named none.
        var server: String?
        /// The server's `message`, one paragraph at most `Hook.elicitationMessageLimit` characters.
        var message: String
        /// Empty for a confirmation.
        var fields: [Field]
    }
}

/// What the user answered an MCP server from the notch.
enum ElicitationAnswer: Equatable, Sendable {
    /// Field key → value. Only fields the form offered, with values it listed.
    case accept([String: ElicitationValue])
    case decline
}

enum ElicitationValue: Equatable, Sendable {
    case choice(String)
    case flag(Bool)
}

extension PendingRequest.Kind {
    var isElicitation: Bool {
        if case .elicitation = self { return true }
        return false
    }
}

extension Hook {
    /// Claude Code's notification types for an MCP request's dialog, which follow the `Elicitation` event by a few
    /// seconds and are the same wait.
    static let elicitationNotificationTypes: Set<String> = ["elicitation_dialog", "elicitation_url_dialog"]
    static let elicitationKey = "elicitation"
    /// The MCP server an `Elicitation` or `ElicitationResult` names, on every such line whether or not it carries a
    /// request, so a wait the notch cannot answer can still say whose it is.
    static let mcpServerKey = "mcp_server"
    static let elicitationMessageLimit = 400
    /// The most fields a form may have and still be answered from the notch; a longer form is better filled in
    /// the terminal, which shows it whole.
    static let elicitationFieldLimit = 4
    /// The most values a choice may list and be answered with a click (⌘1…⌘9 across the whole form).
    static let elicitationOptionLimit = 9
    /// The longest value kept for a choice. Values go back to the server verbatim, so a longer one is not shortened
    /// but refused, and the request is left to the terminal.
    static let elicitationValueLimit = 256

    /// The request an `Elicitation` payload carries, when it is one the notch can answer (the type's comment says
    /// which); nil otherwise, and the event is then the display-only wait the terminal answers.
    static func elicitationRequest(object: [String: Any], id: String) -> Request? {
        elicitationForm(object: object).map { Request(id: id, kind: .elicitation($0)) }
    }

    /// The form a payload asks for, reduced to what a click can answer, or nil. The one reducer both ends use: the
    /// command builds the request from it, and checks the app's answer against it again before printing one.
    static func elicitationForm(object: [String: Any]) -> PendingRequest.Elicitation? {
        let mode = (object["mode"] as? String) ?? "form"
        guard mode == "form", let schema = object["requested_schema"] as? [String: Any],
              (schema["type"] as? String).map({ $0 == "object" }) ?? true else { return nil }
        let properties = schema["properties"] as? [String: Any] ?? [:]
        guard properties.count <= elicitationFieldLimit else { return nil }
        let required = (schema["required"] as? [String] ?? []).filter { properties[$0] != nil }
        // A JSON object has no order once parsed, so the form's is chosen: what the server requires first, in the
        // order it listed them, then the rest by name. Both ends derive it the same way.
        let order = required + properties.keys.filter { !required.contains($0) }.sorted()
        var fields: [PendingRequest.Elicitation.Field] = []
        for key in order {
            guard let property = properties[key] as? [String: Any], let field = elicitationField(key: key, property: property, required: required.contains(key))
            else { return nil }
            fields.append(field)
        }
        // Every button on the card gets a key, ⌘1 to ⌘9 across the whole form (a yes-or-no is two of them), so a
        // form with more to choose from than that is left to the terminal.
        let optionCount = fields.reduce(0) { total, field in
            if case .choice(let options) = field.kind { return total + options.count }
            return total + 2
        }
        guard optionCount <= elicitationOptionLimit else { return nil }
        return PendingRequest.Elicitation(server: shortName(object["mcp_server_name"]), message: paragraph(object["message"]) ?? "", fields: fields)
    }

    /// The server's message as one paragraph: its whitespace collapsed, at most `elicitationMessageLimit` characters.
    static func paragraph(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        guard collapsed.count > elicitationMessageLimit else { return collapsed }
        return String(collapsed.prefix(elicitationMessageLimit)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// One property of the schema as a field a click can fill, or nil for any other kind of property.
    static func elicitationField(key: String, property: [String: Any], required: Bool) -> PendingRequest.Elicitation.Field? {
        guard !key.isEmpty, key.count <= shortNameLimit else { return nil }
        let title = shortName(property["title"]) ?? key
        let detail = shortName(property["description"], limit: 160)
        switch property["type"] as? String {
        case "boolean":
            return .init(key: key, title: title, detail: detail, kind: .toggle, required: required)
        case "string", nil:
            var options: [PendingRequest.Elicitation.Option] = []
            if let values = property["enum"] as? [Any] {
                let names = property["enumNames"] as? [Any]
                for (index, value) in values.enumerated() {
                    guard let value = value as? String, !value.isEmpty, value.count <= elicitationValueLimit else { return nil }
                    let label = names.flatMap { $0.indices.contains(index) ? shortName($0[index], limit: titleLimit) : nil }
                    options.append(.init(value: value, label: label ?? shortName(value, limit: titleLimit) ?? value))
                }
            } else if let variants = property["oneOf"] as? [Any] ?? property["anyOf"] as? [Any] {
                for variant in variants {
                    guard let variant = variant as? [String: Any], let value = variant["const"] as? String, !value.isEmpty,
                          value.count <= elicitationValueLimit else { return nil }
                    options.append(.init(value: value, label: shortName(variant["title"], limit: titleLimit) ?? shortName(value, limit: titleLimit) ?? value))
                }
            } else {
                return nil
            }
            guard !options.isEmpty, options.count <= elicitationOptionLimit, Set(options.map(\.value)).count == options.count else { return nil }
            return .init(key: key, title: title, detail: detail, kind: .choice(options), required: required)
        default:
            return nil
        }
    }

    // MARK: - The wire

    static func userInfo(elicitation form: PendingRequest.Elicitation) -> [String: Any] {
        var entry: [String: Any] = ["message": form.message]
        if let server = form.server { entry["server"] = server }
        entry["fields"] = form.fields.map { field -> [String: Any] in
            var item: [String: Any] = ["key": field.key, "title": field.title, "required": field.required]
            if let detail = field.detail { item["detail"] = detail }
            switch field.kind {
            case .toggle: item["kind"] = "toggle"
            case .choice(let options):
                item["kind"] = "choice"
                item["options"] = options.map { ["value": $0.value, "label": $0.label] }
            }
            return item
        }
        return entry
    }

    /// A form read back off the socket under the command's own limits; nil for anything the command would not
    /// have sent.
    static func elicitation(wire value: Any?) -> PendingRequest.Elicitation? {
        guard let entry = value as? [String: Any], let items = entry["fields"] as? [[String: Any]], items.count <= elicitationFieldLimit else { return nil }
        var fields: [PendingRequest.Elicitation.Field] = []
        for item in items {
            guard let key = item["key"] as? String, !key.isEmpty, key.count <= shortNameLimit, let title = shortName(item["title"]) else { return nil }
            let kind: PendingRequest.Elicitation.Field.Kind
            switch item["kind"] as? String {
            case "toggle": kind = .toggle
            case "choice":
                let options = (item["options"] as? [[String: Any]] ?? []).compactMap { option -> PendingRequest.Elicitation.Option? in
                    guard let value = option["value"] as? String, !value.isEmpty, value.count <= elicitationValueLimit,
                          let label = shortName(option["label"], limit: titleLimit) else { return nil }
                    return .init(value: value, label: label)
                }
                guard !options.isEmpty, options.count <= elicitationOptionLimit else { return nil }
                kind = .choice(options)
            default: return nil
            }
            fields.append(.init(key: key, title: title, detail: shortName(item["detail"], limit: 160), kind: kind, required: item["required"] as? Bool ?? false))
        }
        return PendingRequest.Elicitation(server: shortName(entry["server"]), message: paragraph(entry["message"]) ?? "", fields: fields)
    }
}

extension Hook.Answer {
    /// The reply line's body for an answer to an MCP server: `{"elicitation":"accept","content":{…}}` or
    /// `{"elicitation":"decline"}`.
    static func body(for answer: ElicitationAnswer) -> [String: Any] {
        switch answer {
        case .decline: return ["elicitation": "decline"]
        case .accept(let content):
            return ["elicitation": "accept", "content": content.mapValues { value -> Any in
                switch value {
                case .choice(let text): text
                case .flag(let flag): flag
                }
            }]
        }
    }

    /// The answer a reply line's body carries, or nil. A flag is only a JSON `true` or `false`: JSONSerialization
    /// hands numbers and booleans back as the same NSNumber, and a 1 is not a yes.
    static func elicitationAnswer(from body: [String: Any]) -> ElicitationAnswer? {
        switch body["elicitation"] as? String {
        case "decline": return .decline
        case "accept":
            var content: [String: ElicitationValue] = [:]
            for (key, value) in body["content"] as? [String: Any] ?? [:] {
                if let text = value as? String {
                    content[key] = .choice(text)
                } else if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
                    content[key] = .flag(number.boolValue)
                } else {
                    return nil
                }
            }
            return .accept(content)
        default: return nil
        }
    }

    /// What the command prints for the app's answer to `Elicitation`, checked against the form the payload asks
    /// for: a decline as it is; an accept only when every value names a field of the form with a value the form
    /// offered, and every required field has one. Anything else prints nothing, and Claude Code shows its dialog.
    static func elicitationOutput(_ answer: ElicitationAnswer, payload: Data) -> [String: Any]? {
        switch answer {
        case .decline:
            return ["hookSpecificOutput": ["hookEventName": "Elicitation", "action": "decline"]]
        case .accept(let content):
            guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
                  let form = Hook.elicitationForm(object: object) else { return nil }
            var accepted: [String: Any] = [:]
            for (key, value) in content {
                guard let field = form.fields.first(where: { $0.key == key }) else { return nil }
                switch (field.kind, value) {
                case (.choice(let options), .choice(let text)) where options.contains(where: { $0.value == text }): accepted[key] = text
                case (.toggle, .flag(let flag)): accepted[key] = flag
                default: return nil
                }
            }
            guard form.fields.filter(\.required).allSatisfy({ accepted[$0.key] != nil }) else { return nil }
            return ["hookSpecificOutput": ["hookEventName": "Elicitation", "action": "accept", "content": accepted]]
        }
    }
}
