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
/// have the app take it as an assistant's word, so a forged "waiting for you" or a forged status line cost nothing
/// (the audit's M7; 0.5.0 closed the one place a forged payload did concrete damage, the pull-request link, and
/// left the transport itself open). Both ends of the hop are the same binary — the vendors' files run
/// `Notchmeter --hook`, and the status line runs it too — so there was never a compatibility window to keep the
/// broadcast for: the hop is replaced outright.
///
/// The socket lives at `Paths.hookSocket`, in a folder made 0700 and itself made 0600, unlinked on quit and
/// recreated on launch (a stale file left by a crash is replaced, since nothing holds a socket file the way `flock`
/// holds `instance.lock`). The permission bits are the first fence, but only against other users; the second is
/// the one that matters. For every connection the app reads the peer's pid off the socket (`LOCAL_PEERPID`, which
/// the kernel records at `connect` and nothing on the peer's side can choose), builds the code object of that
/// process (`SecCodeCopyGuestWithAttributes` by pid), and checks it against the app's own designated requirement
/// (`SecCodeCopySelf` → `SecCodeCopyDesignatedRequirement` → `SecCodeCheckValidity`). A peer that fails is closed
/// with one notice line naming its pid and path, and not a byte of what it sent is parsed. A release build's
/// requirement names the bundle identifier and the Developer ID certificate, so any copy of any Notchmeter release
/// passes wherever it sits; an ad-hoc developer build's names its code directory hash, so the same build passes
/// from any path and a different build does not — which is the case Settings › Integrations already flags as a
/// hook pointing at a copy other than the running one, and the launch-time repair rewrites.
///
/// The peer must still be alive when the app checks it, since a code object is resolved through the pid, and
/// that is why the command does not fire and forget: it writes its one line, half-closes, and waits for the app
/// to close the connection, which the app does once the peer is checked and the line read. The wait is bounded,
/// and the whole command still runs inside the hooks' budget (docs/hooks.md). A socket that is absent or refuses
/// means the app is not running, and the command exits 0 silently, as it always has: every vendor's hook is
/// fail-open and the command's silence is what keeps the assistant from seeing a decision.
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
        /// command has no need to tell apart because it does the same either way, exit 0 and say nothing.
        case sent
        /// No app is listening: no socket file, or one nobody holds. The everyday case when Notchmeter is not running.
        case noListener
        /// The line could not be built, the path does not fit `sun_path`, or the socket failed under us.
        case failed(String)
    }

    /// Connects, writes the one line, half-closes and waits for the app to hang up. `timeout` bounds every step
    /// (the connect cannot block on a Unix socket, the write can only if the app's buffer is full, and the wait
    /// for the hang-up is what keeps this process alive through the app's check of it), so the command is back
    /// within the budget whatever the app is doing.
    @discardableResult
    static func send(_ kind: Kind, _ payload: [String: Any], to path: String = Paths.hookSocket.path, timeout: TimeInterval = 1) -> SendResult {
        guard let line = encode(kind, payload) else { return .failed("payload is not JSON") }
        guard fits(path) else { return .failed("socket path too long: \(path)") }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .failed("socket: \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var budget = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &budget, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &budget, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_un(path: path)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else {
            // ENOENT: no socket file; ECONNREFUSED: a file nobody listens on (a crash's leftover, replaced at the
            // next launch). Both mean the app is not there, which is not an error for a fail-open hook.
            return [ENOENT, ECONNREFUSED, ENOTSOCK].contains(errno) ? .noListener : .failed("connect: \(String(cString: strerror(errno)))")
        }
        var written = 0
        while written < line.count {
            let count = line.withUnsafeBytes { write(fd, $0.baseAddress! + written, line.count - written) }
            guard count > 0 else { return .failed("write: \(String(cString: strerror(errno)))") }
            written += count
        }
        shutdown(fd, SHUT_WR)
        // The app writes nothing back; the read returns 0 when it closes, or -1 when the budget runs out.
        var scratch = [UInt8](repeating: 0, count: 64)
        while read(fd, &scratch, scratch.count) > 0 {}
        return .sent
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

        /// Whether the process `pid` runs code that satisfies this process's designated requirement. A pid that has
        /// exited has no code object and is refused, which is why the command waits to be hung up on. With no
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

    /// What `--smoke` reports about the transport: whether a socket stands at the path, which beside the installed
    /// app says the running copy is listening, and beside nothing says the hooks have nowhere to go.
    static func describe(path: String = Paths.hookSocket.path) -> String {
        var info = stat()
        let kind = stat(path, &info) == 0 ? ((info.st_mode & S_IFMT) == S_IFSOCK ? "present" : "not a socket") : "absent"
        return "socket \(path) \(kind)"
    }

    /// The listening end, owned by the store for the life of the app. Connections are accepted on a queue of its
    /// own and each one is checked and read on a concurrent queue, so a peer that connects and then says nothing
    /// holds its own worker for a second and nobody else's; the decoded message is handed to `deliver` on the
    /// caller's terms (the store hops to the main actor). `peerCheck` is the code-signature check by default and a
    /// closure in the tests, which is how a round trip can be pinned on a temporary path without a signed peer.
    final class Listener: @unchecked Sendable {
        typealias PeerCheck = @Sendable (pid_t) -> Peer.Verdict
        typealias Deliver = @Sendable (Message) -> Void

        let path: URL
        private let peerCheck: PeerCheck
        private let deliver: Deliver
        private let acceptQueue = DispatchQueue(label: "com.amirhackett.notchmeter.hook-socket.accept")
        private let workQueue = DispatchQueue(label: "com.amirhackett.notchmeter.hook-socket.peers", attributes: .concurrent)
        private let state = OSAllocatedUnfairLock<(fd: Int32, source: DispatchSourceRead?)>(uncheckedState: (-1, nil))

        /// How long a peer that connected may take to finish its line before it is dropped unread.
        static let readBudget: TimeInterval = 1

        init(path: URL = Paths.hookSocket, peerCheck: @escaping PeerCheck = Peer.verify(pid:), deliver: @escaping Deliver) {
            self.path = path
            self.peerCheck = peerCheck
            self.deliver = deliver
        }

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
            guard bound == 0, chmod(file, 0o600) == 0, listen(fd, 16) == 0 else {
                log.error("hook socket bind at \(file, privacy: .public): \(String(cString: strerror(errno)), privacy: .public)")
                close(fd)
                unlink(file)
                return false
            }
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
        /// fails the check is never parsed, whatever it sent.
        private func serve(_ client: Int32) {
            defer { close(client) }
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
            while line.count < HookSocket.maximumLine {
                let count = read(client, &chunk, chunk.count)
                guard count > 0 else { break }
                line.append(chunk, count: count)
                if chunk[..<count].contains(0x0A) { break }
            }
            guard let newline = line.firstIndex(of: 0x0A) else {
                log.notice("hook socket: pid \(pid) sent no complete line")
                return
            }
            guard let message = HookSocket.decode(line[..<newline]) else {
                log.notice("hook socket: pid \(pid) sent a line that is neither a hook nor a status line")
                return
            }
            deliver(message)
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
