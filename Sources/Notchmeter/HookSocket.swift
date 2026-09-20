import Darwin
import Foundation
import Security
import os

private let log = Logger(subsystem: "com.amirhackett.notchmeter", category: "hook-socket")

/// The hop between the hook and status-line commands and the running app: a Unix-domain socket the app owns under
/// its Application Support folder, on which it accepts only peers carrying its own code signature.
///
/// Until 0.6.0 the commands posted their payload as a `DistributedNotificationCenter` notification. That centre is
/// a broadcast: any process of the same user could observe the two names and read every payload as it went by
/// (the session id, the project folder, the branch, the pull request's URL), and any process could post one and
/// have the app take it as an assistant's word (the audit's M7; 0.5.0 closed the one place a forged payload did
/// concrete damage, the pull-request link, and left the transport itself open). Both ends of the hop are the same
/// binary — the vendors' files run `Notchmeter --hook`, and the status line runs it too — so the hop is replaced
/// outright, with no fallback to the broadcast: one for an absent socket would reopen it whenever the app is not
/// running, which is the everyday case. The one window that leaves is a copy of 0.5.0 or earlier still running
/// under a bundle that a drag onto Applications replaced beneath it (Homebrew quits the app first and Sparkle
/// relaunches it, so only the manual install gets there): until that copy is relaunched, every hook and
/// status-line render runs the new binary, finds no socket and exits silently, while the Hooks rows, which judge
/// an entry by its path, keep saying installed. Nothing here can close that window, since the old copy carries
/// none of this code; docs/hooks.md says to relaunch.
///
/// What the socket closes, and what it does not, is worth stating exactly, because the check below is easy to
/// read as more than it is. The reading side is closed: there is no broadcast, the file is 0600 in a 0700 folder,
/// and a line goes to the one process holding the socket, so nothing observes another process's payload as it
/// goes by. The writing side is closed for every process that cannot exec a copy of Notchmeter or reach the
/// folder: another user, an App-Sandboxed app, a build whose signature differs from the running one. It is not
/// closed for the same user's other code, and cannot be by this design. The check proves that the connecting
/// process is a copy of Notchmeter, not who ran it, and `Notchmeter --hook` is a public command that forwards
/// whatever is piped to it, so any unsandboxed process of the same user can still have a line accepted at the
/// cost of one spawn (`printf '{…}' | Notchmeter --hook`, the very invocation docs/hooks.md gives for trying a
/// hook by hand). Authenticating the sender would need a secret the assistant's hook could hold and other
/// same-user processes could not, which a shared public binary cannot offer; SECURITY.md keeps a Mac compromised
/// at the user level out of scope for that reason, and the one field a forged line could turn into harm, the
/// pull-request link, is gated in `SessionTracker.prLink` whatever the transport vouches for.
///
/// Nor does a Unix socket stamp identity per byte. The check resolves the peer's code image at the moment it
/// runs, through a pid the kernel recorded at `connect`; a process that connects, writes a line and then execs a
/// Notchmeter binary before the app looks (`--statusline` keeps the exec'd image alive for its read budget)
/// presents a genuine image over bytes no command shaped, including a `host` that no local command emits. The one
/// per-message primitive macOS offers is an XPC audit token (`SecCodeCreateWithXPCMessage`), so moving the hop to
/// XPC is the way to close that, and is the intended follow-up; the socket cannot. What the check proves, then,
/// is that a Notchmeter image held the connection when the app looked, which is what refuses every process that
/// is not one, and the bytes are read on that word.
///
/// The socket lives at `Paths.hookSocket`, in a folder made 0700 and itself made 0600, unlinked on quit and
/// recreated on launch (a stale file left by a crash is replaced, since nothing holds a socket file the way `flock`
/// holds `instance.lock`). The permission bits are the first fence, but only against other users; the second is
/// the check just described. For every connection the app reads the peer's pid off the socket (`LOCAL_PEERPID`,
/// which the kernel records at `connect` and nothing on the peer's side can choose), builds the code object of
/// that process (`SecCodeCopyGuestWithAttributes` by pid), and checks it against the app's own designated
/// requirement (`SecCodeCopySelf` → `SecCodeCopyDesignatedRequirement` → `SecCodeCheckValidity`). A peer that fails
/// is closed with one notice line naming its pid and path, and its line is left unread. A release build's
/// requirement names the bundle identifier and the Developer ID certificate, so any copy of any Notchmeter release
/// passes wherever it sits; an ad-hoc developer build's names its code directory hash, so the same build passes
/// from any path and a different build does not — which is the case Settings › Integrations already flags as a
/// hook pointing at a copy other than the running one. The launch-time repair rewrites it only when the running
/// copy is an installed one, never from `build/` or `.build/` (`HookRepair.mayRepair`), so a developer build run
/// beside an installed release refuses the release's hooks until the file is pointed at the build, by hand or by
/// the row's Repair.
///
/// The peer must still be alive when the app checks it, since a code object is resolved through the pid, and
/// that is why the command does not fire and forget: it writes its one line, half-closes, and waits for the app
/// to close the connection, which the app does once the peer is checked and the line read. The wait is capped at
/// one second (`send`'s `timeout`) and is a few milliseconds in the ordinary case, so the command stays inside the
/// hooks' budget while the app is alive and is back within a second when the app is stopped or starved
/// (docs/hooks.md gives the figures; every vendor's configured timeout sits above the cap). A socket that is
/// absent or refuses means the app is not running, and the command exits 0 silently, as it always has: every
/// vendor's hook is fail-open and the command's silence is what keeps the assistant from seeing a decision.
///
/// Since 0.7.0 one kind of line is answered rather than merely hung up on: a request awaiting a decision
/// (`Hook.Message.awaitsDecision`, a permission request or a question). The listener parks that connection
/// instead of closing it, hands the store a `Reply` alongside the message, and the store's `decide`, and nothing
/// else, writes the app's one reply line to it before hanging up; the command reads the line and prints the
/// vendor's decision. What that adds to the threat model above, and what it does not: a same-user process that
/// can already have a line accepted can now put a request in front of the user that no assistant made, and it
/// still cannot have anything approved, because approval originates in the app's own UI, is addressed to a
/// request id the app is showing, and is written only to the connection that asked. A parked connection is held
/// at most `Listener.holdCap`, and at most `Listener.parkedCap` are parked at once, so a flood of requests cannot
/// pin every worker; everything past either cap is answered nothing, which is the terminal asking as before.
///
/// The command checks nothing about the listener in turn: it writes to whatever holds the path. A same-user
/// process that unlinks the file and binds its own there receives the lines, and the app cannot tell:
/// `Listener.isListening` tests the app's own descriptor and `describe` only finds a socket standing at the path,
/// so `--smoke` says present. That is the same-user attacker again, one who can read the same fields from the
/// assistants' own files under `~/.claude`, and what it costs the user is quiet rings: the local denial of
/// service SECURITY.md leaves out of scope, not a fence this code claims.
///
/// The wire is one JSON object per connection, terminated by a newline, with a single key naming the kind of line
/// (`hook` or `statusline`) and the same flat payload the notification used to carry under it, so `Hook.Message`
/// and `Statusline.Message` encode and decode exactly as before and their tests keep meaning. The oracle's snapshot
/// request and the second copy's reopen ask stay on the notification centre: neither carries a payload, and
/// neither can make the app assert anything.
enum HookSocket {
    /// Which of the two commands wrote the line; the one top-level key of the wire object.
    enum Kind: String, Sendable {
        case hook, statusline
    }

    /// A line the app read from a peer it accepted, decoded onto the type its command built.
    enum Message: Equatable, Sendable {
        case hook(Hook.Message)
        case statusline(Statusline.Message)
    }

    /// A line larger than this is not one of ours: the two payloads run to a few hundred bytes.
    static let maximumLine = 256 * 1024

    /// `sun_path` holds 104 bytes on macOS. A home folder deep enough to push the socket's path past it cannot
    /// have a socket there at all, and both ends report it rather than truncating to a path nobody listens on.
    static func fits(_ path: String) -> Bool {
        path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path)
    }

    // MARK: - The wire

    /// One line: `{"hook":{…}}` or `{"statusline":{…}}` and a newline. The payload is the flat dictionary the
    /// notification carried, unchanged; a nil answers a payload JSON cannot hold, which none of ours is.
    static func encode(_ kind: Kind, _ payload: [String: Any]) -> Data? {
        guard JSONSerialization.isValidJSONObject(payload),
              var data = try? JSONSerialization.data(withJSONObject: [kind.rawValue: payload], options: [.sortedKeys]) else { return nil }
        data.append(0x0A)
        return data
    }

    /// The message on a line, or nil for anything that is not exactly one kind with a payload its type accepts.
    static func decode(_ line: Data) -> Message? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any], object.count == 1,
              let entry = object.first, let kind = Kind(rawValue: entry.key), let payload = entry.value as? [String: Any] else { return nil }
        switch kind {
        case .hook: return Hook.Message(userInfo: payload).map(Message.hook)
        case .statusline: return Statusline.Message(userInfo: payload).map(Message.statusline)
        }
    }

    // MARK: - The command's end

    enum SendResult: Equatable, Sendable {
        /// The line went out and the app closed the connection: it was read, or the peer was refused, which the
        /// command has no need to tell apart because it does the same either way, exit 0 and say nothing. `reply`
        /// is whatever the app wrote back before it hung up: nil for every event but a request awaiting a
        /// decision, and for one of those that the app passed back to the terminal, or held past the timeout.
        case sent(reply: Data?)
        /// No app is listening: no socket file, or one that refused every try. The everyday case when Notchmeter is
        /// not running.
        case noListener
        /// The line could not be built, the path does not fit `sun_path`, or the socket failed under us.
        case failed(String)
    }

    /// Connect errors that mean nobody is there: no socket file (the app unlinks it on quit), a file no process
    /// holds (a crash's leftover, replaced at the next launch), a path that is not a socket at all. Anything else
    /// is a fault worth naming.
    static let noListenerErrors: Set<Int32> = [ENOENT, ECONNREFUSED, ENOTSOCK]

    /// The pauses before a second, third and fourth connect when the first is refused. The kernel answers a
    /// connect that finds the accept queue full with the same ECONNREFUSED a leftover file gives, and nothing the
    /// command can see tells the two apart; but the app's acceptor drains its queue in microseconds, so a few
    /// milliseconds' patience is what tells a busy listener from an absent one. A leftover refuses every try and
    /// costs the command the sum of these, a small fraction of its budget.
    static let connectPauses: [TimeInterval] = [0.005, 0.01, 0.02]

    /// A connected descriptor for the socket at `path`, with `timeout` set as its send and receive budget, or -1
    /// with `errno` as the last connect left it. A refusal is tried again after each of `connectPauses`, never
    /// past the deadline; each try is a fresh socket, since a stream socket whose connect failed is not one to
    /// connect again.
    private static func dial(_ path: String, timeout: TimeInterval) -> Int32 {
        let deadline = Date().addingTimeInterval(timeout)
        var budget = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        var address = sockaddr_un(path: path)
        var attempt = 0
        while true {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { return -1 }
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &budget, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &budget, socklen_t(MemoryLayout<timeval>.size))
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            if connected == 0 { return fd }
            let error = errno
            close(fd)
            errno = error
            guard [ECONNREFUSED, EAGAIN, EINTR].contains(error), attempt < connectPauses.count,
                  Date().addingTimeInterval(connectPauses[attempt]) < deadline else { return -1 }
            Thread.sleep(forTimeInterval: connectPauses[attempt])
            attempt += 1
        }
    }

    /// Connects, writes the one line, half-closes and waits for the app to hang up, keeping whatever it wrote
    /// back first. `timeout` bounds every step (the connect cannot block on a Unix socket, and is tried again
    /// briefly when the app's accept queue was full; the write can only block if the app's buffer is full, and
    /// the wait for the hang-up is what keeps this process alive through the app's check of it), so the command
    /// is back within the budget whatever the app is doing. One second for every event but a request awaiting a
    /// decision, which passes `Hook.decisionWait` and is held by the app until the user answers or its hold
    /// runs out.
    @discardableResult
    static func send(_ kind: Kind, _ payload: [String: Any], to path: String = Paths.hookSocket.path, timeout: TimeInterval = 1) -> SendResult {
        guard let line = encode(kind, payload) else { return .failed("payload is not JSON") }
        guard fits(path) else { return .failed("socket path too long: \(path)") }
        let fd = dial(path, timeout: timeout)
        guard fd >= 0 else {
            // Nobody there is not an error for a fail-open hook; a refusal that outlasted the retries reads the
            // same way, since a leftover file and an app still overrun after them are one errno.
            return noListenerErrors.contains(errno) ? .noListener : .failed("connect: \(String(cString: strerror(errno)))")
        }
        defer { close(fd) }
        var written = 0
        while written < line.count {
            let count = line.withUnsafeBytes { write(fd, $0.baseAddress! + written, line.count - written) }
            guard count > 0 else { return .failed("write: \(String(cString: strerror(errno)))") }
            written += count
        }
        let reply = awaitHangUp(fd)
        return .sent(reply: reply.isEmpty ? nil : reply)
    }

    /// Half-closes and waits for the app to hang up, which it does once the peer is checked and its line read;
    /// the read returns 0 when it closes, or -1 when the budget runs out. The app writes nothing back for any
    /// event but a request awaiting a decision, whose one reply line is returned. The wait matters twice over:
    /// the peer must still be alive when the app resolves its code object, and a peer that closes before it is
    /// even accepted leaves the kernel nothing to name it by (`LOCAL_PEERPID` answers ENOTCONN once the other end
    /// has gone), so the app would log it as a peer whose pid could not be read.
    private static func awaitHangUp(_ fd: Int32) -> Data {
        shutdown(fd, SHUT_WR)
        var reply = Data()
        var scratch = [UInt8](repeating: 0, count: 1024)
        while true {
            let count = read(fd, &scratch, scratch.count)
            guard count > 0 else { return reply }
            if reply.count < maximumLine { reply.append(scratch, count: count) }
        }
    }

    // MARK: - The peer check

    enum Peer {
        enum Verdict: Equatable, Sendable {
            case accepted
            /// The peer's executable, when the system could name it, and the Security status that refused it.
            case rejected(path: String?, status: OSStatus)
        }

        /// Our own designated requirement, read once: the running binary's signature cannot change under it.
        private static let requirement: SecRequirement? = {
            var code: SecCode?
            guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
            var staticCode: SecStaticCode?
            guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
            var requirement: SecRequirement?
            guard SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess else { return nil }
            return requirement
        }()

        /// Whether the process `pid` runs, at this moment, code that satisfies this process's designated requirement;
        /// a pid survives `execve`, so this is the image behind the pid now and not the one that connected (the
        /// file comment's exec caveat). A pid that has exited has no code object and is refused, which is why the
        /// command waits to be hung up on. With no
        /// requirement of our own to check against, nothing is accepted: an unauthenticated hop is the thing
        /// being removed, and a build so broken it cannot read its own signature should lose its hooks, not its
        /// guard.
        static func verify(pid: pid_t) -> Verdict {
            var code: SecCode?
            let attributes = [kSecGuestAttributePid: pid] as CFDictionary
            let found = SecCodeCopyGuestWithAttributes(nil, attributes, [], &code)
            guard found == errSecSuccess, let code else { return .rejected(path: path(of: pid), status: found) }
            guard let requirement else { return .rejected(path: path(of: code) ?? path(of: pid), status: errSecCSNoSuchCode) }
            let status = SecCodeCheckValidity(code, [], requirement)
            return status == errSecSuccess ? .accepted : .rejected(path: path(of: code) ?? path(of: pid), status: status)
        }

        private static func path(of code: SecCode) -> String? {
            var staticCode: SecStaticCode?
            guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
            var url: CFURL?
            guard SecCodeCopyPath(staticCode, [], &url) == errSecSuccess else { return nil }
            return (url as URL?)?.path
        }

        private static func path(of pid: pid_t) -> String? {
            var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
            return String(cString: buffer)
        }
    }

    // MARK: - The app's end

    /// What `--smoke` reports about the transport, in one of three states. `present (listening)`: a connect finds
    /// the running app holding the socket, which beside the installed app says the hooks have somewhere to go.
    /// `stale (nobody listening; a relaunch replaces it)`: a socket stands at the path but refuses, which is what a
    /// crash or a `kill` leaves behind, since only a quit unlinks the file; every hook is getting the same refusal,
    /// and nothing in the assistants' files will change that. `absent`: no file, so the app is not running. A
    /// stat alone cannot tell the first two apart, which is why the probe connects; it then half-closes without
    /// writing a byte and waits to be hung up on, as the command does, which the app takes as nothing to read and
    /// does not log. A refusal for any other reason keeps `present` and names the errno, so a permission problem
    /// stays visible.
    static func describe(path: String = Paths.hookSocket.path) -> String {
        var info = stat()
        guard stat(path, &info) == 0 else { return "socket \(path) absent" }
        guard (info.st_mode & S_IFMT) == S_IFSOCK else { return "socket \(path) not a socket" }
        guard fits(path) else { return "socket \(path) present (path too long for sun_path)" }
        let fd = dial(path, timeout: Listener.readBudget)
        guard fd >= 0 else {
            return errno == ECONNREFUSED ? "socket \(path) stale (nobody listening; a relaunch replaces it)"
                                         : "socket \(path) present (connect: \(String(cString: strerror(errno))))"
        }
        _ = awaitHangUp(fd)
        close(fd)
        return "socket \(path) present (listening)"
    }

    /// The app's end of one connection: the one object that can write the app's answer to the peer and hang up.
    /// `answer` is idempotent, so the store's decision, the hold running out and the serving thread's own release
    /// can each call it and the first one wins; a reply is written only from the app's own `decide`, never from
    /// anything the wire said (HookSocket's file comment on the threat model, docs/hooks.md).
    final class Reply: @unchecked Sendable {
        private let state: OSAllocatedUnfairLock<Int32>
        private let answered = DispatchSemaphore(value: 0)

        init(fd: Int32) {
            state = OSAllocatedUnfairLock(initialState: fd)
        }

        /// Writes `line` (if any) and closes the connection; nothing happens on a second call.
        func answer(_ line: Data?) {
            let fd = state.withLock { current in
                defer { current = -1 }
                return current
            }
            guard fd >= 0 else { return }
            if let line, !line.isEmpty {
                var written = 0
                while written < line.count {
                    let count = line.withUnsafeBytes { write(fd, $0.baseAddress! + written, line.count - written) }
                    guard count > 0 else { break }
                    written += count
                }
            }
            close(fd)
            answered.signal()
        }

        var isAnswered: Bool { state.withLock { $0 < 0 } }

        /// Blocks until `answer` has run, or `timeout` has passed; false on the timeout.
        fileprivate func wait(_ timeout: TimeInterval) -> Bool {
            answered.wait(timeout: .now() + timeout) == .success
        }
    }

    /// The listening end, owned by the store for the life of the app. Connections are accepted on a queue of its
    /// own and each one is checked and read on a concurrent queue, so a peer that connects and then says nothing
    /// holds its own worker for a second and nobody else's; the decoded message is handed to `deliver` on the
    /// caller's terms (the store hops to the main actor) together with the `Reply` that answers it. For every
    /// event but a request awaiting a decision the connection is closed the moment `deliver` returns, as it always
    /// was; for one of those the worker parks on the Reply until the store answers it or `holdCap` passes, and at
    /// most `parkedCap` are parked at once, so a flood of requests cannot pin every worker. `peerCheck` is the
    /// code-signature check by default and a closure in the tests, which is how a round trip can be pinned on a
    /// temporary path without a signed peer.
    final class Listener: @unchecked Sendable {
        typealias PeerCheck = @Sendable (pid_t) -> Peer.Verdict
        typealias Deliver = @Sendable (Message, Reply) -> Void

        let path: URL
        private let peerCheck: PeerCheck
        private let deliver: Deliver
        private let holdCap: TimeInterval
        private let acceptQueue = DispatchQueue(label: "com.amirhackett.notchmeter.hook-socket.accept")
        private let workQueue = DispatchQueue(label: "com.amirhackett.notchmeter.hook-socket.peers", attributes: .concurrent)
        private let state = OSAllocatedUnfairLock<(fd: Int32, source: DispatchSourceRead?)>(uncheckedState: (-1, nil))
        private let parked = OSAllocatedUnfairLock(initialState: 0)

        /// How long a peer that connected may take to finish its line before it is dropped unread.
        static let readBudget: TimeInterval = 1
        /// How long a connection awaiting a decision is held open at most, whatever the store does: the socket's
        /// ceiling, matched by `Hook.decisionWait` on the command's side. The store's own hold is shorter.
        static let holdCap: TimeInterval = 600
        /// How many connections may be parked on a decision at once; one past that is answered nothing at once.
        static let parkedCap = 16

        // The default is spelled as a closure rather than `Peer.verify(pid:)` itself: `PeerCheck` is `@Sendable`, and
        // handing a plain static function where one is expected is a conversion the compiler warns about, and CI
        // treats a warning under Sources/ as a failed build (ci.yml).
        init(path: URL = Paths.hookSocket, peerCheck: @escaping PeerCheck = { @Sendable pid in Peer.verify(pid: pid) },
             holdCap: TimeInterval = Listener.holdCap, deliver: @escaping Deliver) {
            self.path = path
            self.peerCheck = peerCheck
            self.holdCap = holdCap
            self.deliver = deliver
        }

        /// How many connections are parked on a decision right now.
        var parkedCount: Int { parked.withLock { $0 } }

        var isListening: Bool { state.withLock { $0.fd >= 0 } }

        /// Makes the folder 0700, replaces whatever stands at the path, binds, makes the socket 0600 and starts
        /// accepting. False, with the reason logged, when any step fails; the app then runs without its hooks, as
        /// it does when none is installed, rather than not at all.
        @discardableResult
        func start() -> Bool {
            guard !isListening else { return true }
            let file = path.path
            guard HookSocket.fits(file) else {
                log.error("hook socket path does not fit sun_path: \(file, privacy: .public)")
                return false
            }
            let folder = path.deletingLastPathComponent()
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            } catch {
                log.error("hook socket folder: \(error.localizedDescription, privacy: .public)")
                return false
            }
            unlink(file)
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else {
                log.error("hook socket: \(String(cString: strerror(errno)), privacy: .public)")
                return false
            }
            var address = sockaddr_un(path: file)
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            // The kernel's whole backlog (128 on macOS): a connect that finds it full is refused with the errno of a
            // dead socket, so this is how many hooks may land between two turns of the accept loop before one has
            // to try again.
            guard bound == 0, chmod(file, 0o600) == 0, listen(fd, SOMAXCONN) == 0 else {
                log.error("hook socket bind at \(file, privacy: .public): \(String(cString: strerror(errno)), privacy: .public)")
                close(fd)
                unlink(file)
                return false
            }
            // Non-blocking for the accept loop's sake, so it can drain the queue to EAGAIN. Every peer it accepts
            // inherits the flag and is put back to blocking in serve().
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
            source.setEventHandler { [weak self] in self?.acceptPending(on: fd) }
            source.setCancelHandler { close(fd) }
            state.withLock { $0 = (fd, source) }
            source.resume()
            log.notice("hook socket listening at \(file, privacy: .public)")
            return true
        }

        /// Stops accepting and removes the socket file, so a command that runs after quit finds nothing rather
        /// than a file that refuses it. The descriptor closes with the source's cancellation.
        func stop() {
            let (fd, source) = state.withLock { current in
                defer { current = (-1, nil) }
                return current
            }
            guard fd >= 0 else { return }
            source?.cancel()
            unlink(path.path)
        }

        deinit { stop() }

        private func acceptPending(on fd: Int32) {
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { return }
                workQueue.async { [weak self] in self?.serve(client) }
            }
        }

        /// The order is the point: the peer's identity is settled before a byte of its line is read, so a peer that
        /// fails the check is never parsed, whatever it sent. Passing proves only that a Notchmeter image held the
        /// connection at that moment (the file comment's exec caveat); the line is then read on that word. The
        /// connection is closed here on every early exit and, once a line is delivered, by its `Reply`.
        private func serve(_ client: Int32) {
            var handedOver = false
            defer { if !handedOver { close(client) } }
            // On macOS accept() copies the listener's O_NONBLOCK onto the peer (BSD semantics; Linux does not), and
            // a non-blocking read ignores SO_RCVTIMEO: it answers EAGAIN the moment the peer's bytes have not landed,
            // which the loop below would take for the end of the line. Blocking again is what makes readBudget the
            // bound the class comment promises, rather than a race the peer's write usually, and not always, wins.
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
            // A reply written to a peer that has already gone (its vendor cancelled the command) must fail with
            // EPIPE, not kill the app.
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            var budget = timeval(tv_sec: Int(Self.readBudget), tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &budget, socklen_t(MemoryLayout<timeval>.size))
            var pid: pid_t = 0
            var length = socklen_t(MemoryLayout<pid_t>.size)
            guard getsockopt(client, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0, pid > 0 else {
                log.notice("hook socket: refused a peer whose pid could not be read")
                return
            }
            if case .rejected(let path, let status) = peerCheck(pid) {
                log.notice("hook socket: refused pid \(pid) at \(path ?? "an unknown path", privacy: .public) (status \(status))")
                return
            }
            var line = Data()
            var chunk = [UInt8](repeating: 0, count: 4096)
            var hungUp = false
            while line.count < HookSocket.maximumLine {
                let count = read(client, &chunk, chunk.count)
                guard count > 0 else {
                    hungUp = count == 0
                    break
                }
                line.append(chunk, count: count)
                if chunk[..<count].contains(0x0A) { break }
            }
            guard let newline = line.firstIndex(of: 0x0A) else {
                // A peer that hangs up without a byte is `--smoke` asking whether anyone listens, not a line lost,
                // and it leaves nothing in the log a user reads while hunting a refused hook. Bytes with no newline,
                // or a peer that went quiet past the budget, do.
                if !(hungUp && line.isEmpty) {
                    log.notice("hook socket: pid \(pid) sent no complete line")
                }
                return
            }
            guard var message = HookSocket.decode(line[..<newline]) else {
                log.notice("hook socket: pid \(pid) sent a line that is neither a hook nor a status line")
                return
            }
            handedOver = true
            let reply = Reply(fd: client)
            guard case .hook(var hook) = message, hook.awaitsDecision else {
                deliver(message, reply)
                reply.answer(nil)
                return
            }
            // A request past the cap on parked connections is delivered as the display-only wait it would have
            // been in 0.6.0 and answered nothing at once, so its command returns and the terminal asks.
            let admitted = parked.withLock { count in
                guard count < Self.parkedCap else { return false }
                count += 1
                return true
            }
            guard admitted else {
                hook.request = nil
                message = .hook(hook)
                deliver(message, reply)
                reply.answer(nil)
                return
            }
            defer { parked.withLock { $0 -= 1 } }
            deliver(message, reply)
            if !reply.wait(holdCap) {
                log.notice("hook socket: pid \(pid) held past the cap, answered nothing")
            }
            reply.answer(nil)
        }
    }
}

private extension sockaddr_un {
    /// An address for `path`, which the caller has checked fits `sun_path`.
    init(path: String) {
        self.init()
        sun_family = sa_family_t(AF_UNIX)
        sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let capacity = MemoryLayout.size(ofValue: sun_path)
        withUnsafeMutablePointer(to: &sun_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: capacity) { buffer in
                _ = path.withCString { strlcpy(buffer, $0, capacity) }
            }
        }
    }
}
