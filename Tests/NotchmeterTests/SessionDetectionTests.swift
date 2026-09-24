import Foundation
import Testing
@testable import Notchmeter

/// The hook-free tier's pure half (SessionDetection): which processes are assistants, what Claude Code's session
/// file and the end of its transcript say, how processes become rows, the busy guess and the cadence.
@Suite struct SessionDetectionMatching {
    let t0 = DateParsing.iso8601("2026-09-24T12:00:00Z")!

    /// Each assistant by the name it ships under, a native Claude Code by the name it was started as (its binary is
    /// a version number), and an interpreter by its script alone.
    @Test func eachAssistantIsKnownByItsOwnNameOrItsScript() {
        #expect(SessionDetection.tool(command: "claude.exe", arguments: ["claude"]) == .claude)
        #expect(SessionDetection.tool(command: "claude", arguments: ["claude", "--resume"]) == .claude)
        #expect(SessionDetection.tool(command: "2.1.281", arguments: ["claude"]) == .claude, "the native installer's binary is its version")
        #expect(SessionDetection.tool(command: "node", arguments: ["node", "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js"]) == .claude)
        #expect(SessionDetection.tool(command: "codex-aarch64-apple-darwin", arguments: ["codex"]) == .codex)
        #expect(SessionDetection.tool(command: "codex", arguments: ["codex"]) == .codex)
        #expect(SessionDetection.tool(command: "node", arguments: ["node", "/usr/local/lib/node_modules/@openai/codex/bin/codex.js"]) == .codex)
        #expect(SessionDetection.tool(command: "node", arguments: ["node", "/opt/homebrew/bin/gemini"]) == .antigravity, "Gemini CLI rides Antigravity's ring")
        #expect(SessionDetection.tool(command: "node", arguments: ["/opt/homebrew/bin/node", "/x/node_modules/@google/gemini-cli/dist/index.js"]) == .antigravity)
        #expect(SessionDetection.tool(command: "copilot", arguments: ["copilot"]) == .copilot)
        #expect(SessionDetection.tool(command: "node", arguments: ["node", "/x/node_modules/@github/copilot/index.js"]) == .copilot)
        #expect(SessionDetection.tool(command: "cursor-agent", arguments: ["cursor-agent"]) == .cursor)
    }

    @Test func nothingElseIsAnAssistant() {
        #expect(SessionDetection.tool(command: "zsh", arguments: ["-zsh"]) == nil)
        #expect(SessionDetection.tool(command: "node", arguments: ["node", "scripts/start.js"]) == nil, "a dev server is not an assistant")
        #expect(SessionDetection.tool(command: "node", arguments: ["/opt/homebrew/bin/node", "/x/scripts/dev-supervisor.mjs"]) == nil)
        #expect(SessionDetection.tool(command: "node", arguments: ["node", "/x/.bin/google-calendar-mcp"]) == nil)
        #expect(SessionDetection.tool(command: "node", arguments: ["node"]) == nil, "an interpreter with no script is a REPL")
        #expect(SessionDetection.tool(command: "claude-mcp", arguments: ["claude-mcp"]) == nil)
        #expect(SessionDetection.tool(command: "python3.12", arguments: ["python3", "/x/bin/kimi"]) == nil, "Kimi is not a supported assistant")
        #expect(SessionDetection.tool(command: "Claude Helper", arguments: ["/Applications/Claude.app/x"]) == nil, "the desktop app is not a terminal session")
    }

    /// The arguments are read only for these; a shell's never are.
    @Test func onlyACandidateHasItsArgumentsRead() {
        for name in ["claude.exe", "claude", "2.1.281", "node", "bun", "python3.12", "codex-aarch64-ap", "gemini", "copilot", "cursor-agent"] {
            #expect(SessionDetection.isCandidate(command: name), "\(name)")
        }
        for name in ["zsh", "bash", "login", "Claude Helper", "vim", "2026", "tmux"] {
            #expect(!SessionDetection.isCandidate(command: name), "\(name)")
        }
    }

    /// `KERN_PROCARGS2` is the count, the executable's path, padding, the arguments and then the environment; the
    /// parse stops at the second argument, and at the count whatever the limit, so it never reaches the
    /// environment: the buffer's count of 3 is what keeps `SECRET=hunter2` out, not the limit.
    @Test func theArgumentParseStopsBeforeTheEnvironment() {
        var buffer: [UInt8] = withUnsafeBytes(of: Int32(3)) { Array($0) }
        let padding: [UInt8] = [0, 0, 0]
        let end: [UInt8] = [0]
        buffer.append(contentsOf: Array("/opt/homebrew/bin/node".utf8))
        buffer.append(contentsOf: padding)
        for word in ["node", "/opt/homebrew/bin/gemini", "--yolo", "SECRET=hunter2"] {
            buffer.append(contentsOf: Array(word.utf8))
            buffer.append(contentsOf: end)
        }
        let parsed = SessionDetector.parseArguments(buffer)
        #expect(parsed == ["node", "/opt/homebrew/bin/gemini"])
        #expect(!parsed.joined().contains("SECRET"))
        #expect(SessionDetector.parseArguments(buffer, limit: 1) == ["node"])
        #expect(SessionDetector.parseArguments(buffer, limit: 10) == ["node", "/opt/homebrew/bin/gemini", "--yolo"],
                "a limit past the count still stops at the count, before the environment")
        #expect(SessionDetector.parseArguments([1, 0]).isEmpty, "too short to hold a count")
    }
}

/// The detector's cache of transcript facts under *Show what a session is working on* (SessionDetector.allowTitles):
/// with titles off nothing of a title is parsed or held, whatever the transcript says, and what was held goes the
/// moment the setting turns off; read through a fixture root, so no process of this Mac is scanned.
@Suite struct SessionDetectorTitleCache {
    let t0 = DateParsing.iso8601("2026-09-24T12:00:00Z")!

    /// A configuration root with one transcript in it, shaped as Claude Code lays them out.
    func fixtureRoot(lines: [String]) throws -> (root: URL, cwd: String) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("NotchmeterTests.detector-\(UUID().uuidString)")
        let cwd = "/Users/x/proj"
        let folder = root.appendingPathComponent("projects").appendingPathComponent(SessionDetection.transcriptFolder(cwd: cwd))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(lines.joined(separator: "\n").utf8).write(to: folder.appendingPathComponent("s.jsonl"))
        return (root, cwd)
    }

    let lines = [
        #"{"type":"custom-title","customTitle":"Renamed by me","sessionId":"s"}"#,
        #"{"type":"ai-title","aiTitle":"Claude's own title","sessionId":"s"}"#,
        #"{"type":"assistant","gitBranch":"feat/x","message":{"model":"claude-opus-5-5","content":[]}}"#,
    ]

    @Test func withTitlesOffNoTitleIsParsedOrHeld() async throws {
        let (root, cwd) = try fixtureRoot(lines: lines)
        defer { try? FileManager.default.removeItem(at: root) }
        let detector = SessionDetector(configDirs: [root])
        await detector.allowTitles(false)
        let facts = try #require(await detector.transcript(session: "s", cwd: cwd, root: root, titles: false, now: t0)).facts
        #expect(facts.customTitle == nil && facts.aiTitle == nil)
        #expect(facts.model == "claude-opus-5-5" && facts.branch == "feat/x", "the model and the branch are not a prompt's words")
        #expect(await detector.heldTitles().isEmpty)
    }

    /// Titles on, the transcript's titles are read and held; the setting turning off drops them from the cache at
    /// once, and a later read with it still off holds none; on again, the next read brings them back.
    @Test func turningTitlesOffDropsWhatWasHeldAndOnReadsItAgain() async throws {
        let (root, cwd) = try fixtureRoot(lines: lines)
        defer { try? FileManager.default.removeItem(at: root) }
        let detector = SessionDetector(configDirs: [root])
        let held = try #require(await detector.transcript(session: "s", cwd: cwd, root: root, titles: true, now: t0)).facts
        #expect(held.customTitle == "Renamed by me" && held.aiTitle == "Claude's own title")
        #expect(await detector.heldTitles() == ["s": ["Renamed by me", "Claude's own title"]])
        await detector.allowTitles(false)
        #expect(await detector.heldTitles().isEmpty, "the cache holds nothing of a prompt the moment the setting is off")
        let off = try #require(await detector.transcript(session: "s", cwd: cwd, root: root, titles: false, now: t0.addingTimeInterval(20))).facts
        #expect(off.customTitle == nil && off.aiTitle == nil)
        #expect(off.model == "claude-opus-5-5")
        #expect(await detector.heldTitles().isEmpty)
        await detector.allowTitles(true)
        let on = try #require(await detector.transcript(session: "s", cwd: cwd, root: root, titles: true, now: t0.addingTimeInterval(40))).facts
        #expect(on.customTitle == "Renamed by me", "on again, the unchanged file is read once more for the title")
    }
}

@Suite struct SessionDetectionFiles {
    let t0 = DateParsing.iso8601("2026-09-24T12:00:00Z")!

    /// The shape Claude Code 2.1.281 writes, read for the whitelisted keys only.
    @Test func aSessionFileGivesTheIdTheFolderAndTheStatus() throws {
        let json = """
        {"pid":89345,"sessionId":"a121ea99-9ec2-4582-8ff4-5f7a4549c591","cwd":"/Users/x/notchmeter","startedAt":1790233016268,
         "procStart":"Thu Sep 24 06:56:55 2026","version":"2.1.281","kind":"interactive","entrypoint":"cli",
         "messagingSocketPath":"/tmp/cc-socks-501/89345.sock","name":"notchmeter-16","nameSource":"derived",
         "status":"busy","updatedAt":1790280792549,"statusUpdatedAt":1790280792549}
        """
        let file = try #require(SessionDetection.claudeFile(from: Data(json.utf8)))
        #expect(file.pid == 89345)
        #expect(file.sessionID == "a121ea99-9ec2-4582-8ff4-5f7a4549c591")
        #expect(file.cwd == "/Users/x/notchmeter")
        #expect(file.started == Date(timeIntervalSince1970: 1_790_233_016.268))
        #expect(file.busy == true)
        #expect(file.statusSince == Date(timeIntervalSince1970: 1_790_280_792.549))
        #expect(file.isInteractive)
        #expect(file.name == nil, "a derived name is Claude Code's default, not one anybody chose")
    }

    @Test func aChosenNameIsKeptAndAnUnknownStatusIsNoStatus() throws {
        let named = #"{"pid":7,"sessionId":"s","name":"Refactor the  card\nsecond line","nameSource":"user","status":"idle"}"#
        let file = try #require(SessionDetection.claudeFile(from: Data(named.utf8)))
        #expect(file.name == "Refactor the card", "cleaned as a prompt's first line is")
        #expect(file.busy == false)
        #expect(try #require(SessionDetection.claudeFile(from: Data(named.utf8), titles: false)).name == nil, "titles off, the name is not read")
        let odd = #"{"pid":7,"sessionId":"s","status":"thinking-hard"}"#
        #expect(try #require(SessionDetection.claudeFile(from: Data(odd.utf8))).busy == nil, "a status nobody documents is not guessed at")
        let print = #"{"pid":7,"sessionId":"s","kind":"print"}"#
        #expect(try #require(SessionDetection.claudeFile(from: Data(print.utf8))).isInteractive == false)
    }

    @Test func aFileWithoutAnIdOrTooBigOrNotJSONIsNothing() {
        #expect(SessionDetection.claudeFile(from: Data(#"{"pid":7}"#.utf8)) == nil)
        #expect(SessionDetection.claudeFile(from: Data(#"{"pid":7,"sessionId":""}"#.utf8)) == nil)
        #expect(SessionDetection.claudeFile(from: Data(#"{"sessionId":"s"}"#.utf8)) == nil)
        #expect(SessionDetection.claudeFile(from: Data("not json".utf8)) == nil)
        let padding = String(repeating: " ", count: SessionDetection.claudeFileLimit)
        #expect(SessionDetection.claudeFile(from: Data((#"{"pid":7,"sessionId":"s"}"# + padding).utf8)) == nil)
    }

    /// A file a crash left behind names a pid the kernel may have given to a newer Claude Code since.
    @Test func aFileOlderThanItsProcessIsNotAboutIt() {
        let process = SessionDetection.Process(pid: 7, command: "claude", arguments: ["claude"], started: t0)
        #expect(SessionDetection.belongs(.init(pid: 7, sessionID: "s", started: t0.addingTimeInterval(1.3)), to: process))
        #expect(SessionDetection.belongs(.init(pid: 7, sessionID: "s", started: nil), to: process))
        #expect(!SessionDetection.belongs(.init(pid: 7, sessionID: "s", started: t0.addingTimeInterval(-3600)), to: process))
        #expect(!SessionDetection.belongs(.init(pid: 8, sessionID: "s", started: t0), to: process))
    }

    /// Newest line first: a `/rename` title, Claude Code's own, the newest reply's model (a synthetic one skipped),
    /// the newest branch; a fragment at the start of the tail and a line with no key worth parsing are passed over.
    @Test func theTranscriptsTailGivesTitlesModelAndBranch() {
        let lines = [
            #"ssage":{"model":"claude-sonnet-4-5"}}"#,
            #"{"type":"ai-title","aiTitle":"Old title","sessionId":"s"}"#,
            #"{"type":"custom-title","customTitle":"Chosen\nby me","sessionId":"s"}"#,
            #"{"type":"assistant","gitBranch":"feat/a","message":{"model":"claude-opus-5-5","content":[]}}"#,
            #"{"type":"ai-title","aiTitle":"Notch app session expiration","sessionId":"s"}"#,
            #"{"type":"assistant","gitBranch":"feat/zero-config","message":{"model":"<synthetic>","content":[]}}"#,
            #"{"type":"user","message":{"content":"a long tool result with no key worth reading"}}"#,
        ]
        let facts = SessionDetection.transcriptFacts(tail: Data(lines.joined(separator: "\n").utf8))
        #expect(facts.customTitle == "Chosen")
        #expect(facts.aiTitle == "Notch app session expiration", "the newest of Claude Code's titles")
        #expect(facts.model == "claude-opus-5-5", "a synthetic model is not a model")
        #expect(facts.branch == "feat/zero-config", "the newest line's branch")
        #expect(SessionDetection.transcriptFacts(tail: Data()) == SessionDetection.TranscriptFacts())
        // Titles off: the title lines are not parsed at all, and the rest is read as before.
        let untitled = SessionDetection.transcriptFacts(tail: Data(lines.joined(separator: "\n").utf8), titles: false)
        #expect(untitled == SessionDetection.TranscriptFacts(model: "claude-opus-5-5", branch: "feat/zero-config"))
    }

    @Test func aModelIdReadsAsItsFamilyAndVersion() {
        #expect(SessionDetection.modelName("claude-opus-5-5") == "Opus 5.5")
        #expect(SessionDetection.modelName("claude-sonnet-4-5-20250929") == "Sonnet 4.5", "a date stamp is dropped")
        #expect(SessionDetection.modelName("claude-fable-5") == "Fable 5")
        #expect(SessionDetection.modelName("claude-haiku") == "Haiku")
        #expect(SessionDetection.modelName("us.anthropic.claude-opus-4-7@20260101") == "Opus 4.7")
        #expect(SessionDetection.modelName("gpt-5.3-codex") == "gpt-5.3-codex", "another vendor's id stays as it is")
        #expect(SessionDetection.modelName("<synthetic>") == nil)
        #expect(SessionDetection.modelName(" ") == nil)
    }

    @Test func theTranscriptFolderIsThePathWithDashes() {
        #expect(SessionDetection.transcriptFolder(cwd: "/Users/x/Developer/notchmeter") == "-Users-x-Developer-notchmeter")
        #expect(SessionDetection.transcriptFolder(cwd: "/Users/x/.claude/worktrees/wf_09d") == "-Users-x--claude-worktrees-wf-09d")
    }
}

@Suite struct SessionDetectionPlanning {
    let t0 = DateParsing.iso8601("2026-09-24T12:00:00Z")!
    /// When every fixture process started: an hour before the scan.
    var start: Date { t0.addingTimeInterval(-3600) }

    func process(_ pid: Int32, parent: Int32 = 1, _ command: String, _ arguments: [String] = [], cwd: String = "/Users/x/notchmeter") -> SessionDetection.Process {
        SessionDetection.Process(pid: pid, parent: parent, command: command, arguments: arguments, started: start, cwd: cwd)
    }

    /// Claude Code's session file decides for Claude Code: an interactive one names the row by the session's own
    /// id, so the hook's events for it land on the same row; another kind is no row; a Claude process without a
    /// file is a row of its own unless another Claude process started it.
    @Test func claudeCodesSessionFileNamesItsRow() {
        let matched: [(process: SessionDetection.Process, tool: ToolID)] = [
            (process(10, "claude.exe", ["claude"]), .claude),
            (process(11, "claude.exe", ["claude", "-p"]), .claude),
            (process(12, "claude.exe", ["claude"]), .claude),
            (process(13, parent: 12, "claude.exe", ["claude"]), .claude),
        ]
        let files = [SessionDetection.ClaudeFile(pid: 10, sessionID: "abc", cwd: "/Users/x/scout", started: t0),
                     SessionDetection.ClaudeFile(pid: 11, sessionID: "print", started: t0, kind: "print")]
        let planned = SessionDetection.plan(matched, claudeFiles: files)
        #expect(planned.map(\.key) == ["abc", "detected-12-\(Int(start.timeIntervalSince1970))"])
        #expect(planned.map(\.exact) == [true, false])
        #expect(planned.first?.cwd == "/Users/x/scout", "the session file's folder outranks the process's")
    }

    /// An npm wrapper that starts the real binary, and a CLI that starts itself again, are one session each: the
    /// innermost process, which is the one spending the CPU.
    @Test func aChainOfOneAssistantsProcessesIsOneRowAtItsInnermost() {
        let matched: [(process: SessionDetection.Process, tool: ToolID)] = [
            (process(20, "node", ["node", "/x/@openai/codex/bin/codex.js"]), .codex),
            (process(21, parent: 20, "codex", ["codex"]), .codex),
            (process(30, "node", ["node", "/opt/homebrew/bin/gemini"]), .antigravity),
            (process(31, parent: 30, "node", ["node", "/opt/homebrew/bin/gemini"]), .antigravity),
            (process(40, "copilot", ["copilot"], cwd: "/Users/x/scout"), .copilot),
        ]
        let planned = SessionDetection.plan(matched, claudeFiles: [])
        #expect(planned.map(\.process.pid).sorted() == [21, 31, 40])
        #expect(planned.allSatisfy { !$0.exact && SessionDetection.isProcessKey($0.key) })
        #expect(planned.first { $0.tool == .codex }?.key == "codex:detected-21-\(Int(start.timeIntervalSince1970))", "under the tool's name, as every non-Claude key is")
    }

    /// Claude Code's own status first, then a transcript written in the last half minute, then the CPU; nothing
    /// measured yet is idle.
    @Test func theBusyGuessTakesTheStrongestEvidence() {
        #expect(!SessionDetection.busy(claude: false, transcriptModified: t0, cpuBusy: true, now: t0), "the session's own status wins")
        #expect(SessionDetection.busy(claude: true, transcriptModified: nil, cpuBusy: false, now: t0))
        #expect(SessionDetection.busy(claude: nil, transcriptModified: t0.addingTimeInterval(-10), cpuBusy: false, now: t0))
        #expect(!SessionDetection.busy(claude: nil, transcriptModified: t0.addingTimeInterval(-40), cpuBusy: false, now: t0))
        #expect(SessionDetection.busy(claude: nil, transcriptModified: t0.addingTimeInterval(-40), cpuBusy: true, now: t0))
        #expect(!SessionDetection.busy(claude: nil, transcriptModified: nil, cpuBusy: nil, now: t0), "a first scan has measured nothing")
    }

    @Test func busyCPUIsAShareOfOneCoreSinceTheLastScan() {
        let earlier = (cpu: 10.0, at: t0)
        #expect(SessionDetection.cpuBusy(from: earlier, to: 10.1, at: t0.addingTimeInterval(3)) == true, "3.3 % of a core")
        #expect(SessionDetection.cpuBusy(from: earlier, to: 10.01, at: t0.addingTimeInterval(3)) == false, "0.3 %")
        #expect(SessionDetection.cpuBusy(from: earlier, to: 11, at: t0.addingTimeInterval(0.5)) == nil, "too short an interval to say")
        #expect(SessionDetection.cpuBusy(from: nil, to: 11, at: t0) == nil)
        #expect(SessionDetection.cpuBusy(from: earlier, to: nil, at: t0.addingTimeInterval(3)) == nil)
    }

    @Test func aRowTakesItsNameOnlyWhenTitlesAreAllowedAndAChosenNameFirst() {
        let planned = SessionDetection.Planned(key: "abc", exact: true, tool: .claude, process: process(10, "claude", ["claude"]),
                                               claude: .init(pid: 10, sessionID: "abc", started: t0, busy: true,
                                                             statusSince: t0.addingTimeInterval(-50), name: "from --name"))
        func row(_ facts: SessionDetection.TranscriptFacts, titles: Bool) -> DetectedSession {
            SessionDetection.session(planned, transcript: facts, transcriptModified: t0.addingTimeInterval(-5), cpuBusy: nil, lastBusy: nil,
                                     project: "notchmeter", branch: nil, terminal: nil, titles: titles, now: t0)
        }
        let facts = SessionDetection.TranscriptFacts(customTitle: "renamed", aiTitle: "Claude's", model: "claude-opus-5-5", branch: "feat/x")
        #expect(row(facts, titles: true).name == "renamed")
        #expect(row(.init(aiTitle: "Claude's"), titles: true).name == "from --name")
        #expect(row(facts, titles: false).name == nil, "titles off holds nothing of the prompt, Claude's title included")
        let busy = row(facts, titles: true)
        #expect(busy.busy)
        #expect(busy.busySince == t0.addingTimeInterval(-50), "the file says when the spell began")
        #expect(busy.lastActivity == t0)
        #expect(busy.model == "Opus 5.5")
        #expect(busy.branch == "feat/x", "the transcript's branch stands in for the checkout's")
    }

    @Test func anIdleRowIsDatedByItsNewestSignOfLife() {
        let planned = SessionDetection.Planned(key: "codex:detected-20-1", exact: false, tool: .codex, process: process(20, "codex", ["codex"]), claude: nil)
        let idle = SessionDetection.session(planned, transcript: nil, transcriptModified: nil, cpuBusy: false, lastBusy: t0.addingTimeInterval(-120),
                                            project: "notchmeter", branch: "main", terminal: nil, titles: true, now: t0)
        #expect(!idle.busy)
        #expect(idle.lastActivity == t0.addingTimeInterval(-120))
        #expect(idle.busySince == nil)
        #expect(idle.name == nil && idle.model == nil, "nothing is read of another assistant's files")
        let never = SessionDetection.session(planned, transcript: nil, transcriptModified: nil, cpuBusy: nil, lastBusy: nil,
                                             project: "notchmeter", branch: nil, terminal: nil, titles: true, now: t0)
        #expect(never.lastActivity == start, "a process never seen busy dates from its own start")
    }

    @Test func theScanRunsFastOnlyWhileAnAssistantRunsAndNeverUnseen() {
        #expect(SessionDetection.interval(running: true, paused: false, onBattery: false, lowPower: false) == 3)
        #expect(SessionDetection.interval(running: false, paused: false, onBattery: false, lowPower: false) == 15)
        #expect(SessionDetection.interval(running: true, paused: false, onBattery: true, lowPower: false) == 6)
        #expect(SessionDetection.interval(running: false, paused: false, onBattery: false, lowPower: true) == 30)
        #expect(SessionDetection.interval(running: true, paused: true, onBattery: false, lowPower: false) == nil)
    }
}
