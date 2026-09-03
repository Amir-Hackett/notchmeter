import AppKit
import Observation

/// Whether something is capturing the screen (Zoom, Meet, QuickTime, Screen Sharing). The window server's
/// `SLSIsScreenWatcherPresent` answers it directly and is resolved with dlsym; when that symbol is gone the public
/// `CGSessionCopyCurrentDictionary` key `CGSSessionScreenIsShared` stands in (it covers screen sharing, not local
/// recording). Polled every five seconds only while the privacy setting is on.
enum ScreenCapture {
    private typealias WatcherPresent = @convention(c) () -> UInt8

    private static let watcherPresent: WatcherPresent? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let symbol = dlsym(handle, "SLSIsScreenWatcherPresent")
        else { return nil }
        return unsafeBitCast(symbol, to: WatcherPresent.self)
    }()

    static var probeName: String { watcherPresent == nil ? "CGSSessionScreenIsShared" : "SLSIsScreenWatcherPresent" }

    static func isCaptured() -> Bool {
        if let watcherPresent { return watcherPresent() != 0 }
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (session["CGSSessionScreenIsShared"] as? Bool) ?? ((session["CGSSessionScreenIsShared"] as? NSNumber)?.boolValue ?? false)
    }
}

/// Whether this login session is the one in front of the screen. `NSWorkspace` announces every later fast-user
/// switch, but it announces nothing about the session the app was launched into, and both accounts' login items
/// fire on the way up: without asking, an app started behind another user's session reads its own state as the
/// active one until the first switch happens. The window server's `kCGSSessionOnConsoleKey` answers it directly.
/// A missing dictionary means no window server to be behind, so the answer is yes.
enum LoginSession {
    static func isOnConsole(_ session: [String: Any]? = CGSessionCopyCurrentDictionary() as? [String: Any]) -> Bool {
        guard let session, let value = session["kCGSSessionOnConsoleKey"] else { return true }
        return (value as? Bool) ?? ((value as? NSNumber)?.boolValue ?? true)
    }
}

@MainActor
@Observable
final class ScreenCaptureMonitor {
    private(set) var captured = false
    @ObservationIgnored private var poll: Task<Void, Never>?
    static let interval: TimeInterval = 5

    func start() {
        guard poll == nil else { return }
        captured = ScreenCapture.isCaptured()
        poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.interval))
                guard !Task.isCancelled, let self else { return }
                let now = ScreenCapture.isCaptured()
                if now != self.captured {
                    self.captured = now
                    Oracle.shared.emit("privacy", ["captured": now])
                }
            }
        }
    }

    func stop() {
        poll?.cancel()
        poll = nil
        captured = false
    }
}
