import AppKit
import Darwin
import os

private let log = Logger(subsystem: "com.amirhackett.notchmeter", category: "instance")

/// One app at a time.
///
/// A menu bar app that starts twice is not twice as useful: both copies put an icon in the bar, both watch the
/// mouse, both draw a panel beside the same notch, and the two panels open and collapse over each other. What that
/// looks like from the outside is a stray black rectangle at the top of the screen that nothing will close, which
/// is a hard thing to recognise as "there are two of these running".
///
/// Second copies are easier to start than they look. `open -n` asks for one outright; a launch whose arguments are
/// dropped on the way through Launch Services becomes one; so does an installer replacing the bundle under a copy
/// that is still up. So the guard cannot rest on Launch Services having registered anybody — the copy that caused
/// this the first time was not registered at all, and `NSRunningApplication` could not see it. A lock file can:
/// `flock` is held by the process, not by the file's contents, and the kernel drops it when the process dies, so a
/// crashed copy leaves nothing to clean up and no stale lock to time out.
///
/// Diagnostic runs are exempt. `--smoke`, `--menu-bar`, `--probe` and the renderers exist to be run beside the
/// installed app and read what it can see; none of them reaches `NSApplication.run`, so none of them can draw a
/// second panel.
enum SingleInstance {
    /// Arguments that mean "sit beside the running app", not "be the app".
    static let sidecarFlags: Set<String> = ["--smoke", "--menu-bar", "--probe", "--mcp", "--hook", "--statusline",
                                            "--render-assets", "--render-gallery"]

    static func isSidecar(arguments: [String]) -> Bool {
        arguments.contains { sidecarFlags.contains($0) } || CommandLineTool.isInvokedAsTool(arguments: arguments)
    }

    /// Held open for the life of the process on purpose: closing the descriptor is what releases the lock.
    private nonisolated(unsafe) static var descriptor: Int32 = -1

    static var lockFile: URL { Paths.applicationSupport.appendingPathComponent("instance.lock") }

    /// True when this process may go on to be the app. False means another copy already is.
    ///
    /// Anything unexpected — the folder cannot be made, the file cannot be opened, the filesystem does not carry
    /// `flock` — answers true. The guard exists to stop a second copy, and refusing to launch the only copy over a
    /// disk problem would be the worse failure by far.
    @discardableResult
    static func claim(arguments: [String] = CommandLine.arguments) -> Bool {
        guard !isSidecar(arguments: arguments), descriptor < 0 else { return true }
        switch lock(lockFile) {
        case .held(let handle):
            descriptor = handle
            return true
        case .takenByAnother:
            return false
        case .unavailable(let reason):
            log.notice("instance lock unusable: \(reason, privacy: .public)")
            return true
        }
    }

    enum Claim {
        case held(Int32)
        /// Another live process holds it. The only answer that stops a launch.
        case takenByAnother
        /// Nothing could be concluded, so nothing is refused.
        case unavailable(String)
    }

    /// The primitive, so the exclusion can be tested on a file of the test's own.
    static func lock(_ url: URL) -> Claim {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let handle = open(url.path, O_CREAT | O_RDWR, 0o644)
        guard handle >= 0 else { return .unavailable("\(url.path): \(String(cString: strerror(errno)))") }
        guard flock(handle, LOCK_EX | LOCK_NB) == 0 else {
            let taken = errno == EWOULDBLOCK
            let reason = String(cString: strerror(errno))
            close(handle)
            return taken ? .takenByAnother : .unavailable(reason)
        }
        return .held(handle)
    }

    /// What a second copy does before it goes: tell the one already running to show itself, so double-clicking the
    /// app in the Finder still opens the panel rather than appearing to do nothing at all.
    static let reopenNotification = Notification.Name("com.amirhackett.notchmeter.reopen")

    static func askRunningCopyToShowItself() {
        DistributedNotificationCenter.default().postNotificationName(reopenNotification, object: nil, userInfo: nil,
                                                                    deliverImmediately: true)
    }
}
