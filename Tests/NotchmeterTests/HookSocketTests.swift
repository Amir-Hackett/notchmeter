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
        #expect(HookSocket.describe(path: url.path) == "socket \(url.path) present")

        let message = Hook.Message(event: "PermissionRequest", needsInput: true, sessionID: "abc", project: "notchmeter", branch: "main",
                                   permissionMode: "plan", agentID: "a1", tool: .codex)
        #expect(HookSocket.send(.hook, message.userInfo, to: url.path) == .sent)
        #expect(seen.delivered.wait(timeout: .now() + 2) == .success, "the line must reach the listener")
        #expect(seen.messages == [.hook(message)])
        // LOCAL_PEERPID is the kernel's word on who connected, and the command is this process here.
        let ourPid = getpid()
        #expect(seen.pids == [ourPid])

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

    @Test func noListenerMeansASilentAnswerWithinTheBudget() throws {
        // No file at all: the everyday case of Notchmeter not running.
        let missing = Self.scratch("missing")
        try? FileManager.default.removeItem(at: missing.deletingLastPathComponent())
        var started = Date()
        #expect(HookSocket.send(.hook, Hook.Message(event: "Stop", needsInput: false).userInfo, to: missing.path) == .noListener)
        #expect(Date().timeIntervalSince(started) < 0.1)
        #expect(HookSocket.describe(path: missing.path) == "socket \(missing.path) absent")

        // A file nobody holds: what a crash leaves behind until the next launch replaces it.
        let stale = Self.scratch("stale")
        try? FileManager.default.removeItem(at: stale.deletingLastPathComponent())
        defer { try? FileManager.default.removeItem(at: stale.deletingLastPathComponent()) }
        try Self.leaveStaleSocket(at: stale)
        started = Date()
        #expect(HookSocket.send(.hook, Hook.Message(event: "Stop", needsInput: false).userInfo, to: stale.path) == .noListener)
        #expect(Date().timeIntervalSince(started) < 0.1)
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

    /// Binds a socket at `url` and closes it without unlinking, which is the file a crash leaves behind.
    static func leaveStaleSocket(at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(fd >= 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        withUnsafeMutablePointer(to: &address.sun_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: capacity) { buffer in
                _ = url.path.withCString { strlcpy(buffer, $0, capacity) }
            }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        try #require(bound == 0)
        close(fd)
        try #require(FileManager.default.fileExists(atPath: url.path))
    }
}
