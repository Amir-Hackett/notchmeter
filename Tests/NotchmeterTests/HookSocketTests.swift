import Darwin
import Foundation
import Testing
import os
@testable import Notchmeter

/// The hop between the `--hook` and `--statusline` commands and the running app, pinned on a socket of the suite's
/// own with the peer check injected, so the tests say nothing about whichever copy of the app is running while
/// they do. The code-signature check itself is exercised once, against this process and against a child that is
/// plainly not it.
@Suite struct HookSocketTransport {
    /// A short path: `sun_path` holds 104 bytes and the temporary folder already spends half of them.
    static func scratch(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("nm-\(name)").appendingPathComponent("hook.sock")
    }

    /// What one listener saw: the pids it was asked about and the messages it delivered, read under a lock because
    /// both arrive on the listener's queues.
    final class Seen: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock<(pids: [pid_t], messages: [HookSocket.Message])>(initialState: ([], []))
        let delivered = DispatchSemaphore(value: 0)

        func saw(_ pid: pid_t) { lock.withLock { $0.pids.append(pid) } }
        func deliver(_ message: HookSocket.Message) {
            lock.withLock { $0.messages.append(message) }
            delivered.signal()
        }
        var pids: [pid_t] { lock.withLock { $0.pids } }
        var messages: [HookSocket.Message] { lock.withLock { $0.messages } }
    }

    static func listener(at url: URL, verdict: HookSocket.Peer.Verdict, seen: Seen) -> HookSocket.Listener {
        HookSocket.Listener(path: url, peerCheck: { pid in
            seen.saw(pid)
            return verdict
        }, deliver: { seen.deliver($0) })
    }

    @Test func aHookLineRoundTripsAndThePeerIsTheProcessThatWroteIt() throws {
        let url = Self.scratch("hook")
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let seen = Seen()
        let listener = Self.listener(at: url, verdict: .accepted, seen: seen)
        #expect(listener.start())
        defer { listener.stop() }
        #expect(listener.isListening)
        #expect(HookSocket.describe(path: url.path) == "socket \(url.path) present (listening)")

        let message = Hook.Message(event: "PermissionRequest", needsInput: true, sessionID: "abc", project: "notchmeter", branch: "main",
                                   permissionMode: "plan", agentID: "a1", tool: .codex)
        #expect(HookSocket.send(.hook, message.userInfo, to: url.path) == .sent)
        #expect(seen.delivered.wait(timeout: .now() + 2) == .success, "the line must reach the listener")
        #expect(seen.messages == [.hook(message)])
        // LOCAL_PEERPID is the kernel's word on who connected, and the command is this process here. The smoke
        // probe above connected too and passed the check before hanging up with nothing to read.
        let ourPid = getpid()
        #expect(seen.pids == [ourPid, ourPid])

        // The socket is the app's alone: 0600 in a 0700 folder.
        let socketMode = try #require(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
        let folderMode = try #require(FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)[.posixPermissions] as? Int)
        let ownerOnly = 0o600
        let ownerOnlyFolder = 0o700
        #expect(socketMode == ownerOnly)
        #expect(folderMode == ownerOnlyFolder)
    }

    @Test func aStatusLineRoundTripsWithItsWindows() throws {
        let url = Self.scratch("status")
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let seen = Seen()
        let listener = Self.listener(at: url, verdict: .accepted, seen: seen)
        #expect(listener.start())
        defer { listener.stop() }

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let payload = """
        {"session_id":"s1","cwd":"/Users/me/notchmeter","model":{"display_name":"Opus"},"effort":{"level":"high"},
         "context_window":{"used_percentage":62},"cost":{"total_cost_usd":1.25},
         "rate_limits":{"five_hour":{"used_percentage":45,"resets_at":\(Int(now.timeIntervalSince1970) + 7200)},
                        "spend_limit":{"used_percentage":130}},
         "worktree":{"branch":"feat/socket"},"pr":{"url":"https://github.com/a/b/pull/12"}}
        """
        let message = try #require(Statusline.message(from: Data(payload.utf8), now: now))
        #expect(HookSocket.send(.statusline, message.userInfo, to: url.path) == .sent)
        #expect(seen.delivered.wait(timeout: .now() + 2) == .success)
        #expect(seen.messages == [.statusline(message)])
    }

    @Test func aPeerTheCheckRefusesIsNeverDeliveredAndTheCommandStillReturns() throws {
        let url = Self.scratch("refused")
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let seen = Seen()
        let listener = Self.listener(at: url, verdict: .rejected(path: "/bin/impostor", status: errSecCSReqFailed), seen: seen)
        #expect(listener.start())
        defer { listener.stop() }

        let started = Date()
        let result = HookSocket.send(.hook, Hook.Message(event: "Stop", needsInput: false).userInfo, to: url.path)
        // The app hangs up on a refused peer as it does on an accepted one, so the command is back at once and has
        // nothing to tell the assistant either way.
        #expect(result == .sent)
        #expect(Date().timeIntervalSince(started) < 1)
        #expect(seen.delivered.wait(timeout: .now() + 0.3) == .timedOut, "a refused peer's line is never parsed, let alone delivered")
        let ourPid = getpid()
        #expect(seen.pids == [ourPid], "the check was asked about the peer before anything else happened")
        #expect(seen.messages.isEmpty)
    }

    @Test func theWaitForTheHangUpIsCappedAtOneSecond() throws {
        // The command waits to be hung up on so the app can resolve its code object through a live pid, and
        // docs/hooks.md promises that an app which is stopped or starved holds a hook for at most a second, not
        // the few milliseconds of the ordinary case. A peer check that sleeps two seconds is such an app held
        // still: the cap is `send`'s timeout on the socket, and the command still answers `.sent`, since it has
        // nothing to tell the assistant either way and the app may yet read the line once it wakes.
        let url = Self.scratch("cap")
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let seen = Seen()
        let listener = HookSocket.Listener(path: url, peerCheck: { _ in
            Thread.sleep(forTimeInterval: 2)
            return .accepted
        }, deliver: { seen.deliver($0) })
        #expect(listener.start())
        defer { listener.stop() }

        let started = Date()
        let result = HookSocket.send(.hook, Hook.Message(event: "Stop", needsInput: false, sessionID: "cap").userInfo, to: url.path)
        let elapsed = Date().timeIntervalSince(started)
        #expect(result == .sent)
        #expect(elapsed >= 0.9, "the command must wait for the app's hang-up, not give up early: \(elapsed) s")
        #expect(elapsed < 1.5, "the wait is capped at one second, the figure the docs give: \(elapsed) s")
        // The line was in the kernel's buffer all along, so the app reads it once its check returns.
        #expect(seen.delivered.wait(timeout: .now() + 3) == .success, "a slow check delays the line and does not lose it")
    }

    @Test func noListenerMeansASilentAnswerWithinTheBudget() throws {
        // No file at all: the everyday case of Notchmeter not running.
        let missing = Self.scratch("missing")
        try? FileManager.default.removeItem(at: missing.deletingLastPathComponent())
        var started = Date()
        #expect(HookSocket.send(.hook, Hook.Message(event: "Stop", needsInput: false).userInfo, to: missing.path) == .noListener)
        // The bound is against a hang towards the one-second budget, not a stopwatch: this path is one ENOENT and
        // takes a millisecond here, but a busy CI runner measured the stale case below at 202 ms against a 200 ms
        // line, so both bounds sit at half the budget, where a real stall still fails and scheduling noise does not.
        let promptly = 0.5
        #expect(Date().timeIntervalSince(started) < promptly)
        #expect(HookSocket.describe(path: missing.path) == "socket \(missing.path) absent")

        // A file nobody holds: what a crash leaves behind until the next launch replaces it. It refuses with the
        // errno a full accept queue gives, so the command tries again a few times before believing it; the pauses
        // add up to a few tens of milliseconds here, two hundred on a loaded runner, nowhere near the budget.
        let stale = Self.scratch("stale")
        try? FileManager.default.removeItem(at: stale.deletingLastPathComponent())
        defer { try? FileManager.default.removeItem(at: stale.deletingLastPathComponent()) }
        try Self.leaveStaleSocket(at: stale)
        started = Date()
        #expect(HookSocket.send(.hook, Hook.Message(event: "Stop", needsInput: false).userInfo, to: stale.path) == .noListener)
        let elapsed = Date().timeIntervalSince(started)
        #expect(elapsed < promptly, "a leftover socket must be given up on well inside the budget: \(elapsed) s")
        // The smoke report tells that file from a held socket, which a stat alone cannot: it connects.
        #expect(HookSocket.describe(path: stale.path) == "socket \(stale.path) stale (nobody listening; a relaunch replaces it)")
    }

    @Test func aPeerSlowToWriteIsStillReadInsideTheBudget() throws {
        // The command writes the moment it connects, so the app's read usually finds the bytes there. A process
        // preempted between its connect and its write is the case the one-second read budget exists for: the
        // app must wait for the line, not take the empty socket for the end of it. The accepted descriptor
        // inherits the listener's O_NONBLOCK on macOS, which made the budget a dead letter until 0.6.0 cleared it.
        let url = Self.scratch("slow")
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let seen = Seen()
        let listener = Self.listener(at: url, verdict: .accepted, seen: seen)
        #expect(listener.start())
        defer { listener.stop() }

        let message = Hook.Message(event: "PermissionRequest", needsInput: true, sessionID: "slow")
        let line = try #require(HookSocket.encode(.hook, message.userInfo))
        #expect(Self.sendRaw(line, to: url, after: 0.05), "the app must still be there to take the line 50 ms in")
        #expect(seen.delivered.wait(timeout: .now() + 2) == .success, "a 50 ms pause inside a 1 s budget must not lose the line")
        #expect(seen.messages == [.hook(message)])
    }

    @Test func fiveHundredBackToBackSendsAllArrive() throws {
        // What a swarm of subagents does to the socket: one command after another, each connecting, writing and
        // waiting to be hung up on. Every one must be delivered; the race that dropped one in a few thousand was
        // the app's first read landing before the peer's write.
        let url = Self.scratch("burst")
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let seen = Seen()
        let listener = Self.listener(at: url, verdict: .accepted, seen: seen)
        #expect(listener.start())
        defer { listener.stop() }

        let total = 500
        let payload = Hook.Message(event: "SubagentStop", needsInput: false, sessionID: "swarm").userInfo
        var sent = 0
        for _ in 0..<total where HookSocket.send(.hook, payload, to: url.path) == .sent { sent += 1 }
        #expect(sent == total, "every command must see the app hang up on it")
        let delivered = Self.count(seen.delivered, upTo: total)
        #expect(delivered == total, "delivered \(delivered) of \(total)")
    }

    @Test func aConnectRefusedByAFullBacklogIsRetriedWithinTheBudget() throws {
        // The kernel refuses a connect that finds the accept queue full with ECONNREFUSED, the errno of a socket
        // nobody holds. The app's acceptor drains its queue in microseconds, so the command tries again after a
        // pause rather than reading a busy app as an absent one and dropping the line. A raw listener with a
        // backlog of one, filled and then drained after a moment, is that situation held still.
        let url = Self.scratch("backlog")
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(listenFD >= 0)
        defer { close(listenFD) }
        var address = Self.address(of: url)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        try #require(bound == 0)
        try #require(listen(listenFD, 1) == 0)

        // Fill the backlog: connect until the kernel says no. Each filler half-closes at once so the drain below
        // reads its end of file rather than waiting on it.
        var fillers: [Int32] = []
        defer { fillers.forEach { close($0) } }
        var refused = false
        for _ in 0..<8 where !refused {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            try #require(fd >= 0)
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            if connected == 0 {
                shutdown(fd, SHUT_WR)
                fillers.append(fd)
            } else {
                refused = errno == ECONNREFUSED
                close(fd)
            }
        }
        try #require(refused, "the kernel must refuse the connect that finds the backlog full, or this proves nothing")

        // The acceptor: after 10 ms it takes every connection, reads it to its end and hangs up, as the app does.
        let stop = OSAllocatedUnfairLock(initialState: false)
        let drained = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            usleep(10_000)
            var waiting = pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0)
            var scratch = [UInt8](repeating: 0, count: 256)
            while !stop.withLock({ $0 }) {
                guard poll(&waiting, 1, 20) > 0 else { continue }
                let client = accept(listenFD, nil, nil)
                guard client >= 0 else { continue }
                while read(client, &scratch, scratch.count) > 0 {}
                close(client)
            }
            drained.signal()
        }
        defer {
            stop.withLock { $0 = true }
            drained.wait()
        }

        let started = Date()
        let result = HookSocket.send(.hook, Hook.Message(event: "Stop", needsInput: false).userInfo, to: url.path)
        #expect(result == .sent, "a refusal from a full backlog is a reason to try again, not a missing app")
        #expect(Date().timeIntervalSince(started) < 1)
    }

    @Test func aHundredPeersConnectingAtOnceAreAllTaken() throws {
        // The listener asks the kernel for its whole backlog, 128 on macOS. A hundred connects landing in the same
        // instant, before the accept loop has had a turn, all sit in the queue; with the sixteen the first cut
        // asked for, the seventeenth was refused and its command read that as no app.
        let url = Self.scratch("crowd")
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let seen = Seen()
        let listener = Self.listener(at: url, verdict: .accepted, seen: seen)
        #expect(listener.start())
        defer { listener.stop() }

        let total = 100
        let line = try #require(HookSocket.encode(.hook, Hook.Message(event: "Stop", needsInput: false, sessionID: "crowd").userInfo))
        let go = DispatchSemaphore(value: 0)
        let refusals = OSAllocatedUnfairLock(initialState: 0)
        let finished = DispatchGroup()
        for _ in 0..<total {
            finished.enter()
            Thread.detachNewThread {
                defer { finished.leave() }
                go.wait()
                if !Self.sendRaw(line, to: url, after: 0) { refusals.withLock { $0 += 1 } }
            }
        }
        for _ in 0..<total { go.signal() }
        #expect(finished.wait(timeout: .now() + 5) == .success)
        #expect(refusals.withLock { $0 } == 0, "no connect in the crowd may be refused")
        let delivered = Self.count(seen.delivered, upTo: total)
        #expect(delivered == total, "delivered \(delivered) of \(total)")
    }

    /// How many of `total` deliveries the semaphore reports, giving up at the first that is two seconds late
    /// rather than waiting that long for each one missing.
    static func count(_ delivered: DispatchSemaphore, upTo total: Int) -> Int {
        var seen = 0
        while seen < total, delivered.wait(timeout: .now() + 2) == .success { seen += 1 }
        return seen
    }

    @Test func aStaleSocketFileIsReplacedAtStartAndRemovedAtStop() throws {
        let url = Self.scratch("replace")
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try Self.leaveStaleSocket(at: url)
        let seen = Seen()
        let listener = Self.listener(at: url, verdict: .accepted, seen: seen)
        #expect(listener.start(), "a leftover socket file must not stop the app from listening")
        let message = Hook.Message(event: "Stop", needsInput: false, sessionID: "s")
        #expect(HookSocket.send(.hook, message.userInfo, to: url.path) == .sent)
        #expect(seen.delivered.wait(timeout: .now() + 2) == .success)
        #expect(seen.messages == [.hook(message)])

        listener.stop()
        #expect(!listener.isListening)
        #expect(!FileManager.default.fileExists(atPath: url.path), "quit removes the socket so a later hook finds nothing rather than a refusal")
        #expect(HookSocket.send(.hook, message.userInfo, to: url.path) == .noListener)
    }

    @Test func theWireCarriesThePayloadUnchangedUnderOneKindKey() throws {
        let message = Hook.Message(event: "SubagentStop", needsInput: false, sessionID: "s", project: "p", branch: "b", agentID: "a", tool: .cursor)
        let line = try #require(HookSocket.encode(.hook, message.userInfo))
        #expect(line.last == 0x0A, "one line, newline-terminated")
        let object = try #require(try JSONSerialization.jsonObject(with: line) as? [String: Any])
        #expect(Set(object.keys) == ["hook"])
        let inner = try #require(object["hook"] as? [String: Any])
        #expect(Set(inner.keys) == Set(message.userInfo.keys), "the payload's fields are the notification's, byte for byte")
        #expect(HookSocket.decode(line.dropLast()) == .hook(message))

        let status = Statusline.Message(sessionID: "s", model: "Opus", contextUsed: 0.5, receivedAt: Date(timeIntervalSince1970: 1_800_000_000))
        let statusLine = try #require(HookSocket.encode(.statusline, status.userInfo))
        #expect(HookSocket.decode(statusLine) == .statusline(status))

        // Anything that is not exactly one kind with a payload its type accepts is nothing.
        #expect(HookSocket.decode(Data(#"{"hook":{"needsInput":true}}"#.utf8)) == nil, "a hook without an event is not a hook")
        #expect(HookSocket.decode(Data(#"{"statusline":{"model":"Opus"}}"#.utf8)) == nil, "a status line without receivedAt is not one")
        #expect(HookSocket.decode(Data(#"{"bogus":{"hook_event_name":"Stop"}}"#.utf8)) == nil)
        #expect(HookSocket.decode(Data(#"{"hook":{"hook_event_name":"Stop"},"statusline":{"receivedAt":1}}"#.utf8)) == nil, "two kinds on one line is nobody's line")
        #expect(HookSocket.decode(Data("not json".utf8)) == nil)
        #expect(HookSocket.decode(Data(#"["hook"]"#.utf8)) == nil)
    }

    @Test func thePathMustFitSunPath() {
        #expect(HookSocket.fits(Paths.hookSocket.path), "the default path has to fit on an ordinary home folder")
        let long = "/tmp/" + String(repeating: "x", count: 120) + "/hook.sock"
        #expect(!HookSocket.fits(long))
        #expect(HookSocket.send(.hook, Hook.Message(event: "Stop", needsInput: false).userInfo, to: long) == .failed("socket path too long: \(long)"))
        let listener = HookSocket.Listener(path: URL(fileURLWithPath: long), peerCheck: { _ in .accepted }, deliver: { _ in })
        #expect(!listener.start())
    }

    @Test func theSignatureCheckAcceptsThisProcessAndRefusesAnotherBinary() throws {
        // This process satisfies its own designated requirement, which is the whole of what the app asks of a peer
        // running the same binary from any path.
        let ourPid = getpid()
        #expect(HookSocket.Peer.verify(pid: ourPid) == .accepted)

        // A child running a different binary does not, and the verdict names it so the notice line can.
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["5"]
        try child.run()
        defer {
            child.terminate()
            child.waitUntilExit()
        }
        let verdict = HookSocket.Peer.verify(pid: child.processIdentifier)
        guard case .rejected(let path, let status) = verdict else {
            Issue.record("a process running /bin/sleep must not pass as Notchmeter")
            return
        }
        #expect(path == "/bin/sleep")
        #expect(status != errSecSuccess)

        // A pid that has gone has no code object to check, which is why the command waits to be hung up on.
        child.terminate()
        child.waitUntilExit()
        if case .accepted = HookSocket.Peer.verify(pid: child.processIdentifier) {
            Issue.record("an exited process must not be accepted")
        }
    }

    /// An address for `url`, whose path the suite keeps short enough for `sun_path`.
    static func address(of url: URL) -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        withUnsafeMutablePointer(to: &address.sun_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: capacity) { buffer in
                _ = url.path.withCString { strlcpy(buffer, $0, capacity) }
            }
        }
        return address
    }

    /// The command's side of the hop, done by hand and without its hurry: connects, waits `delay`, then writes
    /// `line`, half-closes and waits for the hang-up. False when the connect was refused or the line did not all
    /// go out. SO_NOSIGPIPE as the command sets it, so a listener that hung up early fails the test rather than
    /// killing the process.
    static func sendRaw(_ line: Data, to url: URL, after delay: TimeInterval) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = address(of: url)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { return false }
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        let written = line.withUnsafeBytes { write(fd, $0.baseAddress!, line.count) }
        shutdown(fd, SHUT_WR)
        var scratch = [UInt8](repeating: 0, count: 64)
        while read(fd, &scratch, scratch.count) > 0 {}
        return written == line.count
    }

    /// Binds a socket at `url` and closes it without unlinking, which is the file a crash leaves behind.
    static func leaveStaleSocket(at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(fd >= 0)
        var address = Self.address(of: url)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        try #require(bound == 0)
        close(fd)
        try #require(FileManager.default.fileExists(atPath: url.path))
    }
}
