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
