import Foundation
import Testing
@testable import Notchmeter

/// The guard that keeps a second copy from drawing a second panel over the same notch. The interesting part is not
/// the flag list but the exclusion itself, which is tested on a lock file of the suite's own so it says nothing
/// about whichever copy of the app happens to be running while the tests do.
@Suite struct SingleInstanceGuard {
    static func scratch(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("NotchmeterTests.instance.\(name)")
            .appendingPathComponent("instance.lock")
    }

    @Test func aSecondClaimOnTheSameFileIsRefused() throws {
        let url = Self.scratch("exclusion")
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        guard case .held(let first) = SingleInstance.lock(url) else {
            Issue.record("the first claim on a fresh file must be granted")
            return
        }
        // A separate open of the same path, which is what a second process has: flock belongs to the open file
        // description, not to the process, so this is the same contest a second copy of the app would lose.
        if case .takenByAnother = SingleInstance.lock(url) {} else {
            Issue.record("a second claim while the first is held must be refused")
        }

        // Closing is what releases it — the kernel does the same when a crashed copy's descriptors go, so a lock
        // is never left behind to be timed out or cleaned up by hand.
        close(first)
        guard case .held(let third) = SingleInstance.lock(url) else {
            Issue.record("the lock must be free once the holder lets go")
            return
        }
        close(third)
    }

    @Test func aLockOnAPathThatCannotBeOpenedRefusesNothing() {
        // Better a second copy than no copy: the guard exists to stop a duplicate, and a disk problem must not
        // stop the only app the user has from launching.
        let url = URL(fileURLWithPath: "/dev/null/nowhere/instance.lock")
        if case .unavailable = SingleInstance.lock(url) {} else {
            Issue.record("an unopenable lock file must be inconclusive, not a refusal")
        }
    }

    @Test func diagnosticRunsAreNotSecondCopies() {
        // Each of these returns before NSApplication.run, so none can draw a panel, and each is meant to be run
        // beside the installed app to read what it can see.
        for flag in ["--smoke", "--menu-bar", "--probe", "--mcp", "--hook", "--statusline", "--render-assets", "--render-gallery"] {
            #expect(SingleInstance.isSidecar(arguments: ["Notchmeter", flag]), "\(flag) must be exempt")
            #expect(SingleInstance.claim(arguments: ["Notchmeter", flag]), "\(flag) must never be refused a launch")
        }
        #expect(!SingleInstance.isSidecar(arguments: ["Notchmeter"]))
        #expect(!SingleInstance.isSidecar(arguments: ["Notchmeter", "--lang", "zh-Hans"]))
    }
}
