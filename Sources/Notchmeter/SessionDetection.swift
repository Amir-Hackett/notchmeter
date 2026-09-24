import Foundation

/// One running assistant session found without its hook (SessionDetection), as the tracker takes it: which
/// assistant, where it runs, and a guess at whether it is working. Nothing here claims a wait: no process signal
/// proves that an assistant is holding a prompt open, so a detected session is only ever working or idle.
struct DetectedSession: Equatable, Sendable {
    /// The tracker's key (`SessionTracker.key`). Claude Code's own session id when its session file names one, so
    /// the hook's first event for the same session lands on the same row and takes it over; otherwise
    /// `detected-<pid>-<start>` under the tool's name, which no hook ever reports.
    let key: String
    let tool: ToolID
    /// Whether `key` is the assistant's own session id. A process-keyed row cannot be matched to a hook's session by
    /// id, so the tracker matches it by project instead (`SessionTracker.detected`).
    let exact: Bool
    var project: String?
    var branch: String?
    /// The model's short name ("Opus 5.5"), from the newest reply in Claude Code's transcript.
    var model: String?
    /// The session's own name: one set with `/rename` or `--name`, else Claude Code's own title for it. Nil unless
    /// titles are allowed (Preferences.sessionTitles, and never while the screen is shared): it is the user's words,
    /// or Claude's summary of them.
    var name: String?
    let started: Date
    /// The newest sign of life: Claude Code's own status change, the transcript's last write, or the last scan that
    /// saw the process busy; the process's start when there is nothing newer.
    var lastActivity: Date
    /// The guess (`SessionDetection.busy`).
    var busy: Bool
    /// When the busy spell began, where something recorded it (Claude Code's `statusUpdatedAt`); nil otherwise, and
    /// the tracker then counts from the first scan that saw it busy.
    var busySince: Date?
    /// The terminal the process runs in, from its own controlling tty and the app above it (TerminalIdentity).
    var terminal: TerminalRef?

    init(key: String, tool: ToolID, exact: Bool, project: String? = nil, branch: String? = nil, model: String? = nil, name: String? = nil,
         started: Date, lastActivity: Date, busy: Bool, busySince: Date? = nil, terminal: TerminalRef? = nil) {
        self.key = key
        self.tool = tool
        self.exact = exact
        self.project = project
        self.branch = branch
        self.model = model
        self.name = name
        self.started = started
        self.lastActivity = lastActivity
        self.busy = busy
        self.busySince = busySince
        self.terminal = terminal
    }
}

/// The hook-free tier (0.9.0): sessions found from the assistants' own processes, so the Sessions card has rows
/// on the first launch, before any hook is installed. The pure half is here and pinned by SessionDetectionTests;
/// SessionDetector.swift reads the process table and the files.
///
/// **What it reads.** The process table for this user's processes that have a terminal (`proc_listpids`,
/// `proc_pidinfo`): each one's name, parent, start, controlling tty, working directory and CPU time, and for a
/// candidate only (`isCandidate`) its first two arguments, never its environment. A process is an assistant by
/// its executable's name or, for a `node`, `bun`, `deno` or `python` process, by its script's (`tool`). The walk up
/// to the terminal app above it asks `sysctl` for each parent (SessionDetector.parent). For Claude Code
/// also its session file, `~/.claude/sessions/<pid>.json`, whose existence Anthropic documents ("one small file per
/// running session") and whose fields it does not, so every key is optional and read from a whitelist
/// (`claudeFile`); the `.key` file beside it is a secret and is never opened. And the tail of that session's
/// transcript for its title, model and branch (`transcriptFacts`). Everything is read, nothing is written.
///
/// **What it can and cannot know.** A detected session is working or idle and nothing else. Claude Code's session
/// file says which, within a scan; for the other assistants it is the process's own CPU time (more than
/// `busyCPU` of a core since the last scan), which a terminal UI spends while it streams and draws its spinner and
/// not while it sits at a prompt. So a turn's end is seen a scan or two late and a wait for the user's answer is
/// not seen at all: the row says *working* through a permission prompt. The hook is the fix for both, which is
/// what the card's upgrade line says (docs/accuracy.md, *Sessions found without the hook*).
enum SessionDetection {
    /// A transcript written this recently is a working session, where nothing better says so.
    static let transcriptBusyWindow: TimeInterval = 30
    /// A share of one core, averaged since the last scan. A busy Claude Code measured 10 to 16 % while it ran a
    /// tool and drew its spinner (2026-09-24); an idle Node process 0.0 %.
    static let busyCPU = 0.02
    /// Every three seconds while an assistant is running, every fifteen while none is, doubled on battery or in Low
    /// Power Mode; never while nobody can see the screen (`interval`).
    static let activeInterval: TimeInterval = 3
    static let discoveryInterval: TimeInterval = 15
    /// How much of a transcript's end is read for its title, model and branch, and how often at most.
    static let transcriptTail = 256 * 1024
    static let transcriptRereadAfter: TimeInterval = 10
    /// A Claude Code session file larger than this is not one.
    static let claudeFileLimit = 64 * 1024
    /// The marker in a process-keyed row's key (`processKey`).
    static let processKeyMarker = "detected-"

    // MARK: - Processes

    /// One process as the scan saw it.
    struct Process: Equatable, Sendable {
        let pid: Int32
        let parent: Int32
        /// The kernel's name for it (`pbi_name`, else `pbi_comm`): the executable's file name, at most 32 characters.
        let command: String
        /// Its first arguments, at most two: the name it was started as, and for an interpreter the script.
        let arguments: [String]
        let started: Date
        /// `/dev/ttys004`; nil for a process with no terminal, which the scan never keeps.
        let tty: String?
        let cwd: String?
        /// Seconds of CPU so far, user and system together.
        let cpu: TimeInterval?

        init(pid: Int32, parent: Int32 = 1, command: String, arguments: [String] = [], started: Date, tty: String? = "/dev/ttys001", cwd: String? = nil,
             cpu: TimeInterval? = nil) {
            self.pid = pid
            self.parent = parent
            self.command = command
            self.arguments = arguments
            self.started = started
            self.tty = tty
            self.cwd = cwd
            self.cpu = cpu
        }
    }

    /// The interpreters an assistant written in JavaScript or Python runs under, where the script says which it is.
    static func isInterpreter(_ name: String) -> Bool {
        let name = name.lowercased()
        return ["node", "bun", "deno"].contains(name) || name.hasPrefix("python")
    }

    /// Whether a process is worth reading the arguments of: an assistant's own name, an interpreter, or a bare
    /// version number, which is what Claude Code's native installer names the binary it runs
    /// (`~/.local/share/claude/versions/2.1.281`). Everything else, a shell above all, is passed over on its name.
    static func isCandidate(command: String) -> Bool {
        let name = normalized(command)
        if toolForName(name) != nil || isInterpreter(name) { return true }
        return name.range(of: #"^\d+(\.\d+)+$"#, options: .regularExpression) != nil
    }

    /// Which assistant a process is. An interpreter is named by its script (`toolForScript`), never by itself; any
    /// other process by its own name, else the name it was started under, which is how a native Claude Code whose
    /// binary is a version number is still `claude`.
    static func tool(command: String, arguments: [String]) -> ToolID? {
        let own = normalized(command)
        let first = arguments.first.map { normalized(($0 as NSString).lastPathComponent) }
        if isInterpreter(own) || first.map(isInterpreter) == true {
            guard arguments.count > 1 else { return nil }
            return toolForScript(arguments[1])
        }
        return toolForName(own) ?? first.flatMap(toolForName)
    }

    /// The executable names each assistant ships under. Gemini CLI rides Antigravity's ring (docs/hooks.md), so its
    /// sessions are Antigravity's too. Codex's Homebrew cask runs its release binary under its own long name.
    static func toolForName(_ name: String) -> ToolID? {
        switch name {
        case "claude": .claude
        case "codex": .codex
        case "gemini": .antigravity
        case "copilot": .copilot
        case "cursor-agent": .cursor
        default: name.hasPrefix("codex-aarch64") || name.hasPrefix("codex-x86_64") ? .codex : nil
        }
    }

    /// An interpreter's script: by the npm package it sits in, else by its own file name less the extension.
    static func toolForScript(_ path: String) -> ToolID? {
        let packages: [(String, ToolID)] = [("/@anthropic-ai/claude-code/", .claude), ("/@openai/codex/", .codex),
                                             ("/@google/gemini-cli/", .antigravity), ("/@github/copilot/", .copilot)]
        if let hit = packages.first(where: { path.contains($0.0) }) { return hit.1 }
        var name = ((path as NSString).lastPathComponent).lowercased()
        for suffix in [".js", ".mjs", ".cjs", ".ts"] where name.hasSuffix(suffix) {
            name.removeLast(suffix.count)
        }
        return toolForName(name)
    }

    private static func normalized(_ name: String) -> String {
        var name = name.lowercased()
        if name.hasSuffix(".exe") { name.removeLast(4) }
        return name
    }

    // MARK: - Claude Code's session file

    /// `~/.claude/sessions/<pid>.json`, read for these keys only; the rest of it (a socket path, protocol flags) is
    /// never kept.
    struct ClaudeFile: Equatable, Sendable {
        let pid: Int32
        let sessionID: String
        let cwd: String?
        let started: Date?
        /// `interactive` for a session in a terminal; anything else (a print run, an SDK host) is not a row.
        let kind: String?
        /// `status`: true for `busy`, false for `idle`, nil for anything else or nothing.
        let busy: Bool?
        /// `statusUpdatedAt`: when the status last changed.
        let statusSince: Date?
        /// `name`, only when `nameSource` says someone chose it: the `derived` default ("notchmeter-16") is not a
        /// name anybody gave the session, and the status line's `session_name` leaves it out for the same reason.
        let name: String?

        init(pid: Int32, sessionID: String, cwd: String? = nil, started: Date? = nil, kind: String? = "interactive", busy: Bool? = nil,
             statusSince: Date? = nil, name: String? = nil) {
            self.pid = pid
            self.sessionID = sessionID
            self.cwd = cwd
            self.started = started
            self.kind = kind
            self.busy = busy
            self.statusSince = statusSince
            self.name = name
        }

        /// Whether this file stands for a session in a terminal.
        var isInteractive: Bool { kind == nil || kind == "interactive" }
    }

    /// Names a session file can carry that nobody chose.
    static let generatedNameSources: Set<String> = ["derived", "default", "auto", "generated"]

    static func claudeFile(from data: Data) -> ClaudeFile? {
        guard data.count <= claudeFileLimit, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = JSON.number(object["pid"]).map({ Int32(clamping: Int($0)) }), pid > 0,
              let session = (object["sessionId"] as? String).flatMap({ $0.isEmpty ? nil : $0 }) else { return nil }
        func date(_ key: String) -> Date? {
            JSON.number(object[key]).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0 / 1000) : nil }
        }
        let status = object["status"] as? String
        let source = object["nameSource"] as? String
        let name = source.flatMap { generatedNameSources.contains($0) ? nil : Hook.title(fromPrompt: object["name"]) }
        return ClaudeFile(pid: pid, sessionID: session, cwd: (object["cwd"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                          started: date("startedAt"), kind: object["kind"] as? String,
                          busy: status == "busy" ? true : status == "idle" ? false : nil, statusSince: date("statusUpdatedAt"), name: name)
    }

    /// Whether a session file is about the process now at its pid: written after that process started (a file a
    /// crash left behind names a pid the kernel may since have given to another Claude Code).
    static func belongs(_ file: ClaudeFile, to process: Process) -> Bool {
        guard file.pid == process.pid else { return false }
        guard let started = file.started else { return true }
        return started.timeIntervalSince(process.started) > -5
    }

    // MARK: - The transcript's tail

    /// What the end of a Claude Code transcript says about its session.
    struct TranscriptFacts: Equatable, Sendable {
        /// `/rename`'s title (a `custom-title` line), cleaned as a prompt's first line is (Hook.title(fromPrompt:)).
        var customTitle: String?
        /// Claude Code's own title for the session (an `ai-title` line), cleaned the same way.
        var aiTitle: String?
        /// The newest reply's model id ("claude-opus-5-5"); never a synthetic one ("<synthetic>").
        var model: String?
        /// The newest line's `gitBranch`.
        var branch: String?

        init(customTitle: String? = nil, aiTitle: String? = nil, model: String? = nil, branch: String? = nil) {
            self.customTitle = customTitle
            self.aiTitle = aiTitle
            self.model = model
            self.branch = branch
        }
    }

    /// Reads the tail newest line first and stops once it has everything. The first line of a tail read from the
    /// middle of a file is a fragment; it fails to parse and is skipped like any other line that does. A line is
    /// parsed only when its bytes carry a key worth parsing it for, so a megabyte of tool output costs a search for
    /// a few bytes and not a JSON parse.
    static func transcriptFacts(tail: Data) -> TranscriptFacts {
        var facts = TranscriptFacts()
        let markers = [Data(#""type":"custom-title""#.utf8), Data(#""type":"ai-title""#.utf8), Data(#""type":"assistant""#.utf8), Data(#""gitBranch":""#.utf8)]
        var end = tail.endIndex
        while end > tail.startIndex, facts.customTitle == nil || facts.aiTitle == nil || facts.model == nil || facts.branch == nil {
            let start = tail[..<end].lastIndex(of: 0x0A).map { tail.index(after: $0) } ?? tail.startIndex
            let line = tail[start..<end]
            end = start > tail.startIndex ? tail.index(before: start) : tail.startIndex
            guard !line.isEmpty, markers.contains(where: { line.range(of: $0) != nil }),
                  let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            switch object["type"] as? String {
            case "custom-title":
                if facts.customTitle == nil { facts.customTitle = Hook.title(fromPrompt: object["customTitle"] ?? object["title"]) }
            case "ai-title":
                if facts.aiTitle == nil { facts.aiTitle = Hook.title(fromPrompt: object["aiTitle"] ?? object["title"]) }
            case "assistant":
                if facts.model == nil, let model = (object["message"] as? [String: Any])?["model"] as? String, !model.isEmpty, !model.hasPrefix("<") {
                    facts.model = model
                }
            default:
                break
            }
            if facts.branch == nil, let branch = object["gitBranch"] as? String, !branch.isEmpty, branch != "HEAD" { facts.branch = branch }
        }
        return facts
    }

    /// "Opus 5.5" from "claude-opus-5-5", "Sonnet 4.5" from "claude-sonnet-4-5-20250929", "Fable 5" from
    /// "claude-fable-5": the family capitalised and its version dotted, a date stamp dropped. Any other id is kept
    /// as it is ("gpt-5.3-codex"); nil for nothing.
    static func modelName(_ id: String) -> String? {
        let trimmed = id.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("<") else { return nil }
        let parts = ModelPricing.normalize(trimmed).split(separator: "-").map(String.init)
        guard parts.first == "claude", parts.count >= 2, parts[1].allSatisfy(\.isLetter) else { return trimmed }
        let version = parts.dropFirst(2).prefix { $0.count <= 2 && $0.allSatisfy(\.isNumber) }
        let family = parts[1].prefix(1).uppercased() + parts[1].dropFirst()
        return version.isEmpty ? family : "\(family) \(version.joined(separator: "."))"
    }

    /// The folder Claude Code keeps a working directory's transcripts in, under `projects`: the path with every
    /// character that is not a letter or a digit replaced by a dash (`/Users/a/.b` → `-Users-a--b`).
    static func transcriptFolder(cwd: String) -> String {
        String(cwd.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? Character($0) : "-" })
    }

    // MARK: - From processes to rows

    /// One process the scan will make a row of, before its files are read.
    struct Planned: Equatable, Sendable {
        let key: String
        let exact: Bool
        let tool: ToolID
        let process: Process
        /// Claude Code's session file for it, when it has one.
        let claude: ClaudeFile?

        /// The working directory the row is about: the session file's, else the process's own.
        var cwd: String? { claude?.cwd ?? process.cwd }
    }

    /// `detected-<pid>-<start>`, under the tool's name (`SessionTracker.key`): the start keeps a reused pid from
    /// inheriting a row.
    static func processKey(tool: ToolID, process: Process) -> String {
        SessionTracker.key(tool: tool, session: "\(processKeyMarker)\(process.pid)-\(Int(process.started.timeIntervalSince1970))", host: nil)
    }

    /// Whether a tracker key is a process-keyed row's.
    static func isProcessKey(_ key: String) -> Bool {
        key.contains(processKeyMarker)
    }

    /// The rows the matched processes make. Claude Code's session file decides for Claude Code: a process with an
    /// interactive file is one session under the file's own id, a file of another kind is not a row, and a Claude
    /// process with no file is a row of its own unless it runs under another Claude process (a child it started).
    /// Every other assistant is one row per chain of its own processes, taken at the innermost: an npm wrapper
    /// starts the real binary under it (Codex), or a CLI starts itself again with more memory (Gemini CLI), and the
    /// child is the one spending the CPU the guess reads.
    static func plan(_ matched: [(process: Process, tool: ToolID)], claudeFiles: [ClaudeFile]) -> [Planned] {
        let files = Dictionary(claudeFiles.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var parentsOf: [ToolID: Set<Int32>] = [:]
        var pidsOf: [ToolID: Set<Int32>] = [:]
        for entry in matched {
            parentsOf[entry.tool, default: []].insert(entry.process.parent)
            pidsOf[entry.tool, default: []].insert(entry.process.pid)
        }
        var planned: [Planned] = []
        for (process, tool) in matched {
            if tool == .claude {
                if let file = files[process.pid], belongs(file, to: process) {
                    guard file.isInteractive else { continue }
                    planned.append(Planned(key: SessionTracker.key(tool: .claude, session: file.sessionID, host: nil), exact: true, tool: tool,
                                           process: process, claude: file))
                    continue
                }
                if pidsOf[.claude]?.contains(process.parent) == true { continue }
            } else if parentsOf[tool]?.contains(process.pid) == true {
                continue
            }
            planned.append(Planned(key: processKey(tool: tool, process: process), exact: false, tool: tool, process: process, claude: nil))
        }
        return planned.sorted { $0.key < $1.key }
    }

    /// The guess, strongest evidence first: Claude Code's own status when its file has one; else a transcript
    /// written in the last `transcriptBusyWindow`; else the process's CPU since the last scan, which a first scan
    /// has not measured yet and reads as idle.
    static func busy(claude: Bool?, transcriptModified: Date?, cpuBusy: Bool?, now: Date) -> Bool {
        if let claude { return claude }
        if let transcriptModified, now.timeIntervalSince(transcriptModified) < transcriptBusyWindow { return true }
        return cpuBusy ?? false
    }

    /// Whether the CPU a process spent between two samples is a busy one's.
    static func cpuBusy(from earlier: (cpu: TimeInterval, at: Date)?, to cpu: TimeInterval?, at now: Date) -> Bool? {
        guard let earlier, let cpu else { return nil }
        let wall = now.timeIntervalSince(earlier.at)
        guard wall >= 1 else { return nil }
        return (cpu - earlier.cpu) / wall >= busyCPU
    }

    /// One planned process as the tracker takes it. `transcript` and `transcriptModified` are Claude Code's; the
    /// name rides only when `titles` allows it (Preferences.sessionTitles, and not while the screen is shared), and
    /// a name somebody chose outranks Claude Code's own title: `/rename`'s first, then `--name`'s from the session
    /// file, which is the same choice made at launch. The branch is the checkout's own (`branch`, read from
    /// `.git` as the hook reads it), else the transcript's.
    static func session(_ planned: Planned, transcript: TranscriptFacts?, transcriptModified: Date?, cpuBusy: Bool?, lastBusy: Date?,
                        project: String?, branch: String?, terminal: TerminalRef?, titles: Bool, now: Date) -> DetectedSession {
        let file = planned.claude
        let busy = busy(claude: file?.busy, transcriptModified: transcriptModified, cpuBusy: cpuBusy, now: now)
        let started = file?.started ?? planned.process.started
        let evidence = [file?.statusSince, transcriptModified, lastBusy].compactMap { $0 }.max()
        let lastActivity = busy ? now : max(evidence ?? started, started)
        let name = titles ? transcript?.customTitle ?? file?.name ?? transcript?.aiTitle : nil
        return DetectedSession(key: planned.key, tool: planned.tool, exact: planned.exact, project: project,
                               branch: branch ?? transcript?.branch, model: transcript?.model.flatMap(modelName), name: name,
                               started: started, lastActivity: lastActivity, busy: busy,
                               busySince: busy && file?.busy == true ? file?.statusSince : nil, terminal: terminal)
    }

    // MARK: - Cadence

    /// Seconds to the next scan, or nil while nobody can see the screen (asleep, locked, the displays asleep, or
    /// another user's session in front), when there is nothing to draw a row for.
    static func interval(running: Bool, paused: Bool, onBattery: Bool, lowPower: Bool) -> TimeInterval? {
        guard !paused else { return nil }
        let base = running ? activeInterval : discoveryInterval
        return onBattery || lowPower ? base * 2 : base
    }
}
