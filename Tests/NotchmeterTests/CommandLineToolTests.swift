import Foundation
import Testing
@testable import Notchmeter

/// The command-line tool's choice of source, its argument parsing and the link it installs; the MCP server's
/// handshake and tool call round trip.
@Suite struct CommandLineToolRules {
    init() { Localization.use(language: "en") }

    let now = DateParsing.iso8601("2026-09-01T12:00:00Z")!

    func report(pid: Int?, generatedAt: Date) -> Data {
        var object: [String: Any] = ["schema": UsageReport.schema, "generatedAt": Oracle.timestamp(generatedAt), "exitCode": 10,
                                     "tools": [["tool": "claude", "name": "Claude", "status": "ready", "plan": "Max 5x",
                                                "windows": [["id": "five_hour", "label": "Session", "usedFraction": 0.61, "pace": "behind", "source": "statusline"]]],
                                               ["tool": "codex", "name": "Codex", "status": "notInstalled"]],
                                     "advice": [["id": "x", "tool": "claude", "text": "Wait."]], "cost": ["today": 118.31, "last30Days": 6600]]
        if let pid { object["pid"] = pid }
        return try! JSONSerialization.data(withJSONObject: object)
    }

    @Test func aFreshReportFromALiveProcessCountsAsTheAppRunning() {
        #expect(CommandLineTool.isFresh(report(pid: 4242, generatedAt: now.addingTimeInterval(-60)), now: now, alive: { $0 == 4242 }))
        #expect(!CommandLineTool.isFresh(report(pid: 4242, generatedAt: now.addingTimeInterval(-60)), now: now, alive: { _ in false }))
        #expect(!CommandLineTool.isFresh(report(pid: 4242, generatedAt: now.addingTimeInterval(-20 * 60)), now: now, alive: { _ in true }))
        #expect(CommandLineTool.isFresh(report(pid: nil, generatedAt: now), now: now, alive: { _ in false }))
        #expect(!CommandLineTool.isFresh(Data("nope".utf8), now: now, alive: { _ in true }))
        #expect(CommandLineTool.cachedReport(force: true, reportFile: URL(fileURLWithPath: "/nonexistent")) == nil)
    }

    @Test func argumentsNameAToolAndTheFlags() {
        #expect(CommandLineTool.tool(in: ["notchmeter", "codex", "--json"]) == .codex)
        #expect(CommandLineTool.tool(in: ["notchmeter", "--force"]) == nil)
        #expect(CommandLineTool.tool(in: ["notchmeter", "Claude"]) == .claude)
        #expect(CommandLineTool.isInvokedAsTool(arguments: ["/Users/me/.local/bin/notchmeter"]))
        #expect(CommandLineTool.isInvokedAsTool(arguments: ["/Applications/Notchmeter.app/Contents/MacOS/Notchmeter", "--cli"]))
        #expect(!CommandLineTool.isInvokedAsTool(arguments: ["/Applications/Notchmeter.app/Contents/MacOS/Notchmeter", "--probe"]))
        #expect(CommandLineTool.isOnPath(URL(fileURLWithPath: "/Users/me/.local/bin"), path: "/usr/bin:/Users/me/.local/bin"))
        #expect(!CommandLineTool.isOnPath(URL(fileURLWithPath: "/Users/me/.local/bin"), path: "/usr/bin"))
    }

    @Test func aCachedReportIsNarrowedAndDescribedWithItsSource() {
        let parsed = CommandLineTool.parsed(report(pid: nil, generatedAt: now), tool: .claude)
        #expect(parsed.exitCode == 10)
        #expect(parsed.text.contains("Claude (Max 5x): ready"))
        #expect(parsed.text.contains("Session: 61% (behind) [statusline]"))
        #expect(parsed.text.contains("advice: Wait."))
        #expect(parsed.text.contains("exit code 10"))
        #expect(!parsed.text.contains("Codex"))
        let codex = CommandLineTool.parsed(report(pid: nil, generatedAt: now), tool: .codex)
        #expect(codex.text.contains("Codex: notInstalled"))
        #expect(!codex.text.contains("cost:"))
        #expect(!String(decoding: codex.data, as: UTF8.self).contains("\"cost\""))
    }

    @Test func installsASymlinkAndReplacesAStaleOne() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("notchmeter-cli-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let link = try CommandLineTool.install(executable: "/Applications/Notchmeter.app/Contents/MacOS/Notchmeter", directory: dir)
        #expect(link.lastPathComponent == "notchmeter")
        #expect(try fm.destinationOfSymbolicLink(atPath: link.path) == "/Applications/Notchmeter.app/Contents/MacOS/Notchmeter")
        let again = try CommandLineTool.install(executable: "/Users/me/Applications/Notchmeter.app/Contents/MacOS/Notchmeter", directory: dir)
        #expect(try fm.destinationOfSymbolicLink(atPath: again.path) == "/Users/me/Applications/Notchmeter.app/Contents/MacOS/Notchmeter")
        #expect(throws: (any Error).self) { try CommandLineTool.install(executable: "/x", directory: nil) }
        #expect(CommandLineTool.linkDirectory(home: dir)?.path == dir.appendingPathComponent(".local/bin").path)
    }
}

@Suite struct MCPServerRules {
    init() { Localization.use(language: "en") }

    let now = DateParsing.iso8601("2026-09-01T12:00:00Z")!

    var server: MCPServer {
        MCPServer(report: {
            let window = LimitWindow(id: "five_hour", label: "Session", usedFraction: 0.61, resetsAt: self.now.addingTimeInterval(4 * 3600), periodDuration: Period.fiveHours)
            let reading = UsageReading(tool: .claude, windows: [window], plan: "Max 5x", fetchedAt: self.now, observedAt: nil)
            return UsageReport(tools: [.claude: .ready(reading), .codex: .notInstalled], order: [.claude, .codex], cost: nil, advice: [], now: self.now)
        })
    }

    @Test func handshakeListAndCallRoundTrip() async throws {
        let initialize = try #require(await server.handle(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2024-11-05", "capabilities": [:]]]))
        let result = try #require(initialize["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == MCPServer.protocolVersion)
        #expect((result["serverInfo"] as? [String: Any])?["name"] as? String == "notchmeter")
        #expect(await server.handle(["jsonrpc": "2.0", "method": "notifications/initialized"]) == nil)
        let list = try #require(await server.handle(["jsonrpc": "2.0", "id": 2, "method": "tools/list"]))
        let tools = try #require((list["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        #expect(tools.map { $0["name"] as? String } == ["get_limits"])
        let call = try #require(await server.handle(["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "get_limits", "arguments": ["tool": "claude"]]]))
        let content = try #require(((call["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first)
        let text = try #require(content["text"] as? String)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(object["schema"] as? String == UsageReport.schema)
        #expect(object["exitCode"] as? Int == 10)
        #expect((object["tools"] as? [[String: Any]])?.count == 1)
        #expect(!text.contains("token\":"))
        let unknown = try #require(await server.handle(["jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": ["name": "nope"]]))
        #expect((unknown["error"] as? [String: Any])?["code"] as? Int == -32602)
        let missing = try #require(await server.handle(["jsonrpc": "2.0", "id": 5, "method": "resources/list"]))
        #expect((missing["error"] as? [String: Any])?["code"] as? Int == -32601)
        #expect(MCPServer.snippet(executable: "/Applications/Notchmeter.app/Contents/MacOS/Notchmeter").contains("\"args\": [\"--mcp\"]"))
    }

    @Test func aRawReportRoundTripsThroughDecodeAndLimited() throws {
        let data = server.report
        _ = data
        let json = Data(#"{"schema":"notchmeter.limits.v1","generatedAt":"2026-09-01T12:00:00.000Z","exitCode":11,"tools":[{"tool":"claude"},{"tool":"codex"}],"advice":[{"tool":"codex","text":"x"}],"cost":{"today":1},"sessions":[{"id":"a"}]}"#.utf8)
        let decoded = try #require(UsageReport.decode(json))
        #expect(decoded.exitCode == .limitHit)
        let codex = decoded.limited(to: .codex)
        let object = try #require(try JSONSerialization.jsonObject(with: codex.json) as? [String: Any])
        #expect((object["tools"] as? [[String: Any]])?.count == 1)
        #expect(object["cost"] == nil)
        #expect((object["sessions"] as? [Any])?.isEmpty == true)
        #expect(UsageReport.decode(Data("{\"schema\":\"other\"}".utf8)) == nil)
    }
}
