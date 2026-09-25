import Darwin
import Foundation

/// The live half of SessionDetection: one scan of this user's processes and of Claude Code's session files, off
/// the main thread, turned into the rows the tracker takes (`SessionTracker.detected`). An actor, because it keeps
/// what one scan needs from the last: each process's CPU time (the busy guess is a difference), when it was last
/// seen busy, the transcript facts already read, and the terminal already resolved for a process (the walk asks
/// LaunchServices about each ancestor), so a scan of an unchanged Mac is a process listing and a few `stat`s. The
/// project and the branch are read afresh on every scan: a folder becomes a checkout or a worktree while its
/// assistant runs (`git init`, `git worktree add`), and a name kept for the actor's lifetime said the old thing
/// until the app was relaunched, while a hook row for the same folder said the new one.
///
/// Every read is of this user's own processes and files, and none of it is written anywhere: the process table
/// through libproc (no permission is needed for one's own processes, and another user's are never asked about),
/// Claude Code's `sessions/<pid>.json` files by name (the `.key` files beside them are secrets and are never
/// opened), and at most `SessionDetection.transcriptTail` bytes of a transcript's end, no more often than
/// `SessionDetection.transcriptRereadAfter` and only once it has changed. A process's arguments are read only for
/// a candidate (`SessionDetection.isCandidate`), and only the first two; its environment, which the same sysctl
/// returns after them, is never parsed. A session's title (a `/rename`, a `--name`, Claude Code's own) is read
/// only while `scan(titles:)` allows it, and the moment it stops being allowed every title already read is dropped
/// from the cache here (`allowTitles`): with *Show what a session is working on* off, or the screen shared, nothing
/// of a prompt is held anywhere in the app (docs/privacy.md), this actor's memory included.
actor SessionDetector {
    /// What one scan found: the rows, and whether any assistant process is running at all, which sets the cadence.
    struct Scan: Sendable {
        let sessions: [DetectedSession]
        let running: Bool
    }

    /// A process across scans: its pid and its start, so a reused pid is a new process.
    private struct Identity: Hashable {
        let pid: Int32
        let started: TimeInterval
    }

    /// One transcript across scans. Not private only because `transcript(session:cwd:root:titles:now:)` hands it
    /// to a test; nothing outside this actor keeps one.
    struct Transcript {
        let url: URL
        /// The newest modification time seen, which the busy guess reads.
        var modified: Date?
        /// The time and size the facts were read at: a change since is what makes a read due.
        var readModified: Date?
        var readSize = -1
        var facts = SessionDetection.TranscriptFacts()
        var readAt = Date.distantPast

        /// Whether a title is held.
        var hasTitle: Bool { facts.customTitle != nil || facts.aiTitle != nil }

        /// The same facts with both titles gone.
        mutating func dropTitles() {
            facts.customTitle = nil
            facts.aiTitle = nil
        }

        /// Makes the next read due whether or not the file changed (still no sooner than
        /// `SessionDetection.transcriptRereadAfter`): what titles allowed again needs, since the titles were
        /// dropped from the facts and the file may not change for a while.
        mutating func forgetRead() {
            readModified = nil
            readSize = -1
        }
    }

    private let configDirs: [URL]
    private let uid: uid_t
    private let own: Int32
    private var cpu: [Identity: (cpu: TimeInterval, at: Date)] = [:]
    private var lastBusy: [Identity: Date] = [:]
    private var terminals: [Identity: TerminalRef?] = [:]
    /// Transcripts by Claude Code session id; a miss is remembered with the time it was looked for.
    private var transcripts: [String: Transcript] = [:]
    private var misses: [String: Date] = [:]
    /// What the last scan was allowed (`allowTitles`), so the change of it is acted on once.
    private var titlesAllowed = true
    private let timebase: Double

    /// `configDirs` are Claude Code's configuration folders as ClaudeCostScanner finds them (`$CLAUDE_CONFIG_DIR`,
    /// `~/.config/claude`, `~/.claude`); each one's `sessions` and `projects` are read.
    init(configDirs: [URL] = SessionDetector.claudeConfigDirs(), uid: uid_t = getuid(), own: Int32 = getpid()) {
        self.configDirs = configDirs
        self.uid = uid
        self.own = own
        var base = mach_timebase_info_data_t()
        mach_timebase_info(&base)
        timebase = base.denom == 0 ? 1 : Double(base.numer) / Double(base.denom)
    }

    static func claudeConfigDirs(environment: [String: String] = ProcessInfo.processInfo.environment) -> [URL] {
        var dirs: [URL] = []
        if let custom = environment["CLAUDE_CONFIG_DIR"], !custom.isEmpty { dirs.append(URL(fileURLWithPath: custom)) }
        dirs.append(Paths.home.appendingPathComponent(".config/claude"))
        dirs.append(Paths.home.appendingPathComponent(".claude"))
        return dirs
    }

    /// One scan. `titles` is whether a session's name may be read at all (Preferences.sessionTitles, and not while
    /// the screen is shared): with it off no title is taken from a transcript or a session file, and none is kept
    /// from before. The project resolver is the scan's own, as the cost scanner's is (ProjectName.Resolver: one per
    /// scan); the walk is a few `stat`s per folder, and a name that could go stale is not worth them.
    func scan(titles: Bool, now: Date = Date()) -> Scan {
        allowTitles(titles)
        let projects = ProjectName.Resolver()
        let matched = assistants()
        let files = matched.contains { $0.tool == .claude } ? claudeFiles(titles: titles) : []
        let planned = SessionDetection.plan(matched, claudeFiles: files.map(\.file))
        var sessions: [DetectedSession] = []
        var seen: Set<Identity> = []
        for entry in planned {
            let identity = Identity(pid: entry.process.pid, started: entry.process.started.timeIntervalSince1970)
            seen.insert(identity)
            let busyByCPU = SessionDetection.cpuBusy(from: cpu[identity], to: entry.process.cpu, at: now)
            if let spent = entry.process.cpu { cpu[identity] = (spent, now) }
            if busyByCPU == true { lastBusy[identity] = now }
            var facts: SessionDetection.TranscriptFacts?
            var modified: Date?
            if let file = entry.claude, let root = files.first(where: { $0.file.sessionID == file.sessionID })?.root {
                let transcript = transcript(session: file.sessionID, cwd: entry.cwd, root: root, titles: titles, now: now)
                facts = transcript?.facts
                modified = transcript?.modified
            }
            let cwd = entry.cwd
            let branch = cwd.flatMap(Hook.gitBranch(cwd:))
            let project = cwd.flatMap(projects.name(ofPath:))
            sessions.append(SessionDetection.session(entry, transcript: facts, transcriptModified: modified, cpuBusy: busyByCPU,
                                                     lastBusy: lastBusy[identity], project: project, branch: branch,
                                                     terminal: terminal(for: entry, identity: identity), titles: titles, now: now))
        }
        // What the processes that went took with them.
        cpu = cpu.filter { seen.contains($0.key) }
        lastBusy = lastBusy.filter { seen.contains($0.key) }
        terminals = terminals.filter { seen.contains($0.key) }
        let live = Set(planned.compactMap(\.claude?.sessionID))
        transcripts = transcripts.filter { live.contains($0.key) }
        misses = misses.filter { now.timeIntervalSince($0.value) < 60 }
        return Scan(sessions: sessions, running: !matched.isEmpty)
    }

    /// Whether titles may be read from here on. Turned off, every title already read goes from the cache at once,
    /// not at each transcript's next read, which for an idle session may be hours away; turned on again, every
    /// transcript is read again at its next chance (`Transcript.forgetRead`), since the facts held for it have no
    /// title and the file may not change for a while. `scan(titles:)` calls this first; a test calls it directly.
    func allowTitles(_ allowed: Bool) {
        guard allowed != titlesAllowed else { return }
        titlesAllowed = allowed
        transcripts = transcripts.mapValues { transcript in
            var transcript = transcript
            if allowed { transcript.forgetRead() } else { transcript.dropTitles() }
            return transcript
        }
    }

    /// The titles the cache holds, by session, for the test that pins `allowTitles` and the read under it: the
    /// answer with titles off is an empty table, whatever the transcripts say.
    func heldTitles() -> [String: [String]] {
        transcripts.filter(\.value.hasTitle).mapValues { [$0.facts.customTitle, $0.facts.aiTitle].compactMap { $0 } }
    }

    // MARK: - The process table

    /// This user's processes that have a controlling terminal and are an assistant, with which one, other than this
    /// app, each described only as far as the match needs: the name and tty for every process, the arguments for a
    /// candidate, and the working directory and CPU time for a candidate its arguments make an assistant of.
    private func assistants() -> [(process: SessionDetection.Process, tool: ToolID)] {
        var count = proc_listpids(UInt32(PROC_UID_ONLY), uid, nil, 0)
        guard count > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(count) / MemoryLayout<Int32>.size + 64)
        count = pids.withUnsafeMutableBytes { proc_listpids(UInt32(PROC_UID_ONLY), uid, $0.baseAddress, Int32($0.count)) }
        guard count > 0 else { return [] }
        let found = pids.prefix(Int(count) / MemoryLayout<Int32>.size)
        var result: [(process: SessionDetection.Process, tool: ToolID)] = []
        for pid in found where pid > 1 && pid != own {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_uid == uid,
                  info.e_tdev != UInt32.max, info.e_tdev != 0 else { continue }
            let name = Self.string(info.pbi_name)
            let command = name.isEmpty ? Self.string(info.pbi_comm) : name
            guard SessionDetection.isCandidate(command: command) else { continue }
            let arguments = Self.arguments(of: pid)
            guard let tool = SessionDetection.tool(command: command, arguments: arguments),
                  let device = devname(dev_t(bitPattern: info.e_tdev), S_IFCHR) else { continue }
            let started = Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000)
            let process = SessionDetection.Process(pid: pid, parent: Int32(info.pbi_ppid), command: command, arguments: arguments, started: started,
                                                   tty: "/dev/" + String(cString: device), cwd: Self.cwd(of: pid), cpu: cpuTime(of: pid))
            result.append((process, tool))
        }
        return result
    }

    private static func string<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    /// The first two arguments from `KERN_PROCARGS2`: the argument count, the executable's path, padding, then the
    /// arguments one after another. The parse stops after the second; the environment that follows them in the
    /// same buffer is never read.
    static func arguments(of pid: Int32, limit: Int = 2) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }
        return parseArguments(Array(buffer.prefix(size)), limit: limit)
    }

    /// The pure half of `arguments(of:)`, so the layout is pinned by a test against a buffer of its own making.
    static func parseArguments(_ buffer: [UInt8], limit: Int = 2) -> [String] {
        guard buffer.count > MemoryLayout<Int32>.size else { return [] }
        let count = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        while index < buffer.count, buffer[index] != 0 { index += 1 }
        while index < buffer.count, buffer[index] == 0 { index += 1 }
        var result: [String] = []
        while result.count < min(Int(count), limit), index < buffer.count {
            let start = index
            while index < buffer.count, buffer[index] != 0 { index += 1 }
            result.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return result
    }

    private static func cwd(of pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = string(info.pvi_cdir.vip_path)
        return path.isEmpty ? nil : path
    }

    /// User and system time together, in seconds. The kernel counts in Mach time units, which are nanoseconds on
    /// Intel and 125/3 of one on Apple silicon.
    private func cpuTime(of pid: Int32) -> TimeInterval? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return nil }
        return Double(info.pti_total_user + info.pti_total_system) * timebase / 1_000_000_000
    }

    /// Where the process's terminal is, from its own tty and the first app above it (TerminalIdentity), resolved
    /// once per process: the walk asks LaunchServices about each ancestor. An editor's integrated terminal carries
    /// the folder too, which is how a jump brings the right window of it forward (TerminalJump.opensFolders).
    private func terminal(for entry: SessionDetection.Planned, identity: Identity) -> TerminalRef? {
        if let known = terminals[identity] { return known }
        let chain = TerminalIdentity.ancestry(of: entry.process.pid, parent: Self.parent, bundleID: TerminalIdentity.liveBundleID)
        var terminal = TerminalIdentity.resolve(environment: [:], ancestry: chain, tool: entry.tool)
        if TerminalJump.opensFolders(terminal?.bundleID) { terminal?.workspace = entry.cwd }
        terminals[identity] = terminal
        return terminal
    }

    /// The parent and controlling tty of any process, through `sysctl(KERN_PROC_PID)`. The hook's own walk uses
    /// `proc_pidinfo` (TerminalIdentity.liveParent), which refuses another user's process; that never mattered to
    /// the hook, whose environment names its terminal app, but here the environment is exactly what is not read,
    /// and between a terminal and the shell it opens sits `/usr/bin/login`, which runs as root. Measured on
    /// 2026-09-24: `claude → -zsh → login (root) → iTermServer → iTerm2`, where `proc_pidinfo` stopped the walk at
    /// the shell and the row had no app to jump to. This asks for the parent pid and the tty, nothing more.
    static func parent(_ pid: pid_t) -> (parent: pid_t, tty: String?)? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size >= MemoryLayout<kinfo_proc>.stride else { return nil }
        let device = info.kp_eproc.e_tdev
        var tty: String?
        if device != -1, let name = devname(device, S_IFCHR) { tty = "/dev/" + String(cString: name) }
        return (info.kp_eproc.e_ppid, tty)
    }

    // MARK: - Claude Code's files

    /// Every `sessions/<pid>.json` under the configuration folders, with the folder it was found in. Only names
    /// that are a pid and `.json`: the `<pid>.<hash>.key` beside each is a secret and is never opened. The file's
    /// `name` is read only while `titles` allows it.
    private func claudeFiles(titles: Bool) -> [(file: SessionDetection.ClaudeFile, root: URL)] {
        var result: [(SessionDetection.ClaudeFile, URL)] = []
        for root in configDirs {
            let folder = root.appendingPathComponent("sessions")
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { continue }
            for name in names where name.hasSuffix(".json") && name.dropLast(5).allSatisfy(\.isNumber) && name.count > 5 {
                let url = folder.appendingPathComponent(name)
                guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]), (values.fileSize ?? 0) <= SessionDetection.claudeFileLimit,
                      let data = try? Data(contentsOf: url), let file = SessionDetection.claudeFile(from: data, titles: titles) else { continue }
                result.append((file, root))
            }
        }
        return result
    }

    /// The session's transcript facts, read again only when the file changed and not more often than
    /// `transcriptRereadAfter`. The file is `projects/<folder>/<session>.jsonl` under the root its session file
    /// came from, where the folder is the working directory's (`SessionDetection.transcriptFolder`); Claude Code
    /// shortens a very long folder name, so a miss looks through the folders once, and a second miss is not
    /// looked for again for a minute. With `titles` off the title lines are not parsed and the facts kept hold no
    /// title (`allowTitles` has already dropped any read before). Not private, so a test can read a fixture root
    /// through it without a scan of this Mac's processes.
    func transcript(session: String, cwd: String?, root: URL, titles: Bool, now: Date) -> Transcript? {
        let fm = FileManager.default
        var known = transcripts[session]
        if known == nil {
            if let missed = misses[session], now.timeIntervalSince(missed) < 60 { return nil }
            let projects = root.appendingPathComponent("projects")
            var url = cwd.map { projects.appendingPathComponent(SessionDetection.transcriptFolder(cwd: $0)).appendingPathComponent("\(session).jsonl") }
            if url.map({ fm.fileExists(atPath: $0.path) }) != true {
                url = (try? fm.contentsOfDirectory(atPath: projects.path))?.lazy
                    .map { projects.appendingPathComponent($0).appendingPathComponent("\(session).jsonl") }
                    .first { fm.fileExists(atPath: $0.path) }
            }
            guard let url else {
                misses[session] = now
                return nil
            }
            known = Transcript(url: url)
        }
        guard var transcript = known else { return nil }
        let values = try? transcript.url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        guard let size = values?.fileSize else {
            transcripts[session] = nil
            return nil
        }
        let modified = values?.contentModificationDate
        transcript.modified = modified
        if modified != transcript.readModified || size != transcript.readSize,
           now.timeIntervalSince(transcript.readAt) >= SessionDetection.transcriptRereadAfter,
           let tail = Self.tail(of: transcript.url, size: size) {
            let facts = SessionDetection.transcriptFacts(tail: tail, titles: titles)
            // A tail with no title in it keeps the one read before: an older part of the file still has it. With
            // titles off there is none to keep, and none is taken.
            transcript.facts = SessionDetection.TranscriptFacts(customTitle: titles ? facts.customTitle ?? transcript.facts.customTitle : nil,
                                                                aiTitle: titles ? facts.aiTitle ?? transcript.facts.aiTitle : nil,
                                                                model: facts.model ?? transcript.facts.model,
                                                                branch: facts.branch ?? transcript.facts.branch)
            transcript.readModified = modified
            transcript.readSize = size
            transcript.readAt = now
        }
        transcripts[session] = transcript
        return transcript
    }

    private static func tail(of url: URL, size: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let offset = max(0, size - SessionDetection.transcriptTail)
        guard (try? handle.seek(toOffset: UInt64(offset))) != nil else { return nil }
        return try? handle.read(upToCount: SessionDetection.transcriptTail)
    }
}
