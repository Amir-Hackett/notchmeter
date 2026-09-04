import Foundation
import IOKit.pwr_mgt
import os

private let log = Logger(subsystem: "com.amirhackett.notchmeter", category: "awake")

/// Whether a power assertion should be held right now: only while the setting is on, at least one assistant
/// session (Claude Code's or Cursor's, per its hook) is working, and the Mac is on mains power unless the battery
/// override is on. Pure, so it is pinned.
enum AwakeRule {
    static func shouldHold(working: Int, enabled: Bool, onBattery: Bool, allowOnBattery: Bool) -> Bool {
        guard enabled, working > 0 else { return false }
        return !onBattery || allowOnBattery
    }

    /// "Keeping awake · 2 sessions", for the footer.
    static func footer(working: Int) -> String {
        working == 1 ? L("Keeping awake · 1 session") : L("Keeping awake · %ld sessions", working)
    }
}

/// Holds `kIOPMAssertionTypePreventUserIdleSystemSleep` while the rule says so, so an assistant's session
/// kicked off from a phone or over SSH keeps running with the lid closed on power, and releases it the moment the
/// last turn ends. No entitlement is needed; the assertion is visible in `pmset -g assertions`.
@MainActor
final class AwakeKeeper {
    private var assertion: IOPMAssertionID = 0
    private(set) var holding = false

    func apply(hold: Bool) {
        guard hold != holding else { return }
        if hold {
            var id: IOPMAssertionID = 0
            let status = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                     "\(AppInfo.name): an assistant session is working" as CFString, &id)
            guard status == kIOReturnSuccess else {
                log.error("assertion refused: \(status, privacy: .public)")
                return
            }
            assertion = id
            holding = true
            log.notice("holding the Mac awake")
        } else {
            IOPMAssertionRelease(assertion)
            assertion = 0
            holding = false
            log.notice("released the awake assertion")
        }
        Oracle.shared.emit("awake", ["holding": holding])
    }
}
