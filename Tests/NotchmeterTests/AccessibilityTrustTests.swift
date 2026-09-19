import Foundation
import Testing
@testable import Notchmeter

/// macOS ties an Accessibility grant to the copy that was granted it and leaves the entry — switch on — when that
/// copy is replaced. Telling that apart from a permission that was never given is what makes the difference between
/// sending the user to a pane that already looks right and offering to clear the entry.
@Suite struct AccessibilityTrust {
    let signed = "certificate:Developer ID Application: Amir Hackett"

    @Test func trustedIsTrustedWhateverWasRecorded() {
        #expect(MenuBarExtent.trust(isTrusted: true, grantedTo: nil) == .granted)
        #expect(MenuBarExtent.trust(isTrusted: true, grantedTo: signed) == .granted)
    }

    @Test func nothingRecordedIsAPermissionNeverGiven() {
        #expect(MenuBarExtent.trust(isTrusted: false, grantedTo: nil) == .notGranted)
    }

    /// Until 0.5.0 this asserted the opposite — that a recorded grant refused under the *same* signature was a
    /// permission given up, and so a case for the ordinary prompt. The premise was that only a changed signature
    /// can leave an entry behind. A screen recording on 2026-09-19 disproved it: a Developer ID build, certificate
    /// unchanged, `accessibilityGrantedTo` equal to the running identity, the switch in Privacy & Security on, and
    /// `AXIsProcessTrusted()` false — prompted on every launch into a pane it could not change, while the repair
    /// alert sat behind a comparison that could never come out unequal. The recorded grant is the proof that
    /// matters: it is written only while the grant holds, so a copy that holds one and is refused has an entry
    /// that stopped applying, whoever it is signed as.
    @Test func theSameSignatureRefusedIsAnEntryThatStoppedApplying() {
        #expect(MenuBarExtent.trust(isTrusted: false, grantedTo: signed) == .stale(grantedTo: signed))
        // Ad-hoc signed code is pinned to a hash every build changes, so two builds are two copies to macOS; the
        // hash the grant was seen under is what the entry is reported as, so the alert can name it.
        #expect(MenuBarExtent.trust(isTrusted: false, grantedTo: "cdhash:aa") == .stale(grantedTo: "cdhash:aa"))
    }

    /// The identity is what TCC pins to: the certificate where there is one, the code directory hash where there
    /// is not. The test bundle is signed ad hoc by the linker, so the running code reports a hash.
    @Test func theRunningIdentityIsReadFromTheSignature() throws {
        let identity = try #require(CodeSignature.runningIdentity())
        #expect(identity.hasPrefix("cdhash:") || identity.hasPrefix("certificate:"))
        #expect(identity.count > "cdhash:".count)
    }
}

/// The launch that finds Auto chosen and the permission refused asks once per signed copy, not once per process.
/// The guard was a static until 0.5.0, so every launch was a first launch and the system prompt came up each time
/// the app started for anyone who had picked Auto and dismissed it.
@Suite struct AccessibilityLaunchPrompt {
    let signed = "certificate:Developer ID Application: Amir Hackett"
    let local = "certificate:Notchmeter Local"

    @Test func aFixedSideNeverAsks() {
        for side in CompactSide.allCases where side != .auto {
            #expect(!MenuBarExtent.asksAtLaunch(side: side, isTrusted: false, askedFor: nil, identity: signed))
            #expect(!MenuBarExtent.asksAtLaunch(side: side, isTrusted: false, askedFor: local, identity: signed))
        }
    }

    @Test func aGrantThatHoldsNeverAsks() {
        #expect(!MenuBarExtent.asksAtLaunch(side: .auto, isTrusted: true, askedFor: nil, identity: signed))
        #expect(!MenuBarExtent.asksAtLaunch(side: .auto, isTrusted: true, askedFor: local, identity: signed))
    }

    @Test func aCopyThatHasNeverAskedAsks() {
        #expect(MenuBarExtent.asksAtLaunch(side: .auto, isTrusted: false, askedFor: nil, identity: signed))
    }

    /// The user's own case: Auto chosen, the prompt shown under this very signature, and the launch after finds the
    /// permission still refused. Asking again is what every launch used to do.
    @Test func aCopyThatHasAskedAsksNoMore() {
        #expect(!MenuBarExtent.asksAtLaunch(side: .auto, isTrusted: false, askedFor: signed, identity: signed))
    }

    /// A rebuild is a new copy to macOS, with an entry of its own to earn, so it gets one prompt of its own.
    @Test func aNewSignatureAsksOnceMore() {
        #expect(MenuBarExtent.asksAtLaunch(side: .auto, isTrusted: false, askedFor: local, identity: signed))
        #expect(MenuBarExtent.asksAtLaunch(side: .auto, isTrusted: false, askedFor: "cdhash:aa", identity: "cdhash:bb"))
    }

    /// Nothing to compare against: a signature that cannot be read is not the copy that asked, whatever asked.
    @Test func anUnreadableSignatureIsComparedWithNothing() {
        #expect(MenuBarExtent.asksAtLaunch(side: .auto, isTrusted: false, askedFor: signed, identity: nil))
        #expect(MenuBarExtent.asksAtLaunch(side: .auto, isTrusted: false, askedFor: nil, identity: nil))
    }
}

/// The marker has to outlive the process, which is the whole point of it. Each test's defaults suite is emptied
/// before and after, so nothing is left under ~/Library/Preferences.
@MainActor @Suite struct AccessibilityAskedMarker {
    func withSuite(_ name: String, _ body: (UserDefaults) throws -> Void) rethrows {
        let suite = "NotchmeterTests.AccessibilityAsked.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    @Test func theSignatureAskedUnderOutlivesTheProcess() {
        withSuite("persists") { defaults in
            let signed = "certificate:Developer ID Application: Amir Hackett"
            let prefs = Preferences(defaults: defaults)
            #expect(prefs.accessibilityAskedFor == nil)
            prefs.accessibilityAskedFor = signed
            #expect(defaults.string(forKey: "accessibilityAskedFor") == signed)
            let relaunched = Preferences(defaults: defaults)
            #expect(relaunched.accessibilityAskedFor == signed)
            relaunched.accessibilityAskedFor = nil
            #expect(defaults.string(forKey: "accessibilityAskedFor") == nil)
            #expect(Preferences(defaults: defaults).accessibilityAskedFor == nil)
        }
    }
}
