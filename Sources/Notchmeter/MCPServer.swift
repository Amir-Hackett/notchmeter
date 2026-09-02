import Foundation

/// `Notchmeter --mcp`: a Model Context Protocol server over stdio (newline-delimited JSON-RPC 2.0) with one tool,
/// `get_limits`, answering with the `notchmeter.limits.v1` object, so Cursor, Codex and Claude Desktop can ask for
/// the windows and the advice the way Claude Code does through the skill. The report comes from the running app's
/// cache when it has one, else from a live probe. Nothing is written; the token never leaves the providers.
struct MCPServer {
    static let protocolVersion = "2024-11-05"

    let report: () async -> UsageReport

    static let tools: [[String: Any]] = [[
        "name": "get_limits",
        "description": "This Mac's AI coding-tool usage windows (Claude Code, Codex, Cursor, Gemini CLI, Copilot), the local Claude Code cost estimate and Notchmeter's advice, as the notchmeter.limits.v1 object. Read it before long work to decide whether to switch models or wait for a reset.",
        "inputSchema": ["type": "object", "properties": ["tool": ["type": "string", "description": "Limit the answer to one tool: claude, codex, cursor, antigravity or copilot."]], "additionalProperties": false],
    ]]

    /// The client's configuration snippet, for Settings.
    static func snippet(executable: String) -> String {
        let encoded = (try? JSONSerialization.data(withJSONObject: executable, options: [.fragmentsAllowed, .withoutEscapingSlashes]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "\"\(executable)\""
        return "{\n  \"mcpServers\": {\n    \"notchmeter\": { \"command\": \(encoded), \"args\": [\"--mcp\"] }\n  }\n}\n"
    }

    /// One request in, one response out; nil for a notification, which gets no answer.
    func handle(_ request: [String: Any]) async -> [String: Any]? {
        let id = request["id"]
        guard let method = request["method"] as? String else {
            return id.map { Self.error(id: $0, code: -32600, message: "invalid request") }
        }
        switch method {
        case "initialize":
            return Self.result(id: id, ["protocolVersion": Self.protocolVersion, "capabilities": ["tools": [:]],
                                        "serverInfo": ["name": AppInfo.name.lowercased(), "version": AppInfo.version]])
        case "notifications/initialized", "notifications/cancelled":
            return nil
        case "ping":
            return Self.result(id: id, [:])
        case "tools/list":
            return Self.result(id: id, ["tools": Self.tools])
        case "tools/call":
            let params = request["params"] as? [String: Any] ?? [:]
            guard params["name"] as? String == "get_limits" else {
                return Self.error(id: id ?? NSNull(), code: -32602, message: "unknown tool")
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            var full = await report()
            if let name = arguments["tool"] as? String, let tool = ToolID(rawValue: name.lowercased()) {
                full = full.limited(to: tool)
            }
            let text = String(decoding: full.json, as: UTF8.self)
            return Self.result(id: id, ["content": [["type": "text", "text": text]], "isError": false])
        default:
            return id.map { Self.error(id: $0, code: -32601, message: "method not found: \(method)") }
        }
    }

    static func result(id: Any?, _ value: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": value]
    }

    static func error(id: Any, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }

    /// Reads one JSON object per line from standard input until it closes, answering each on standard output.
    func run() async {
        while let line = readLine(strippingNewline: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            guard let object = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any] else {
                emit(Self.error(id: NSNull(), code: -32700, message: "parse error"))
                continue
            }
            if let response = await handle(object) { emit(response) }
        }
    }

    private func emit(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    }
}
