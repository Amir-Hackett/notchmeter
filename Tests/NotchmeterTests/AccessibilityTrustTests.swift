import Foundation
import Testing
@testable import Notchmeter

/// macOS ties an Accessibility grant to the copy that was granted it and leaves the entry — switch on — when that
/// copy is replaced, and it can stop honouring the entry for the very copy it was granted to. Telling either apart
/// from a permission that was never given is what makes the difference between sending the user to a pane that
/// already looks right and offering to clear the entry; telling the two apart from each other is what lets the
/// alert say something true about why.
@Suite struct AccessibilityTrust {
    let signed = "certificate:Developer ID Application: Amir Hackett"
    let local = "certificate:Notchmeter Local"

    @Test func trustedIsTrustedWhateverWasRecorded() {
        #expect(MenuBarExtent.trust(isTrusted: true, grantedTo: nil, identity: signed) == .granted)
        #expect(MenuBarExtent.trust(isTrusted: true, grantedTo: signed, identity: signed) == .granted)
        #expect(MenuBarExtent.trust(isTrusted: true, grantedTo: local, identity: signed) == .granted)
    }

    @Test func nothingRecordedIsAPermissionNeverGiven() {
        #expect(MenuBarExtent.trust(isTrusted: false, grantedTo: nil, identity: signed) == .notGranted)
        #expect(MenuBarExtent.trust(isTrusted: false, grantedTo: nil, identity: nil) == .notGranted)
    }

    /// Until 0.5.0 this asserted the opposite — that a recorded grant refused under the *same* signature was a
    /// permission given up, and so a case for the ordinary prompt. The premise was that only a changed signature
    /// can leave an entry behind. A screen recording on 2026-09-19 disproved it: a Developer ID build, certificate
    /// unchanged, `accessibilityGrantedTo` equal to the running identity, the switch in Privacy & Security on, and
    /// `AXIsProcessTrusted()` false — prompted on every launch into a pane it could not change, while the repair
    /// alert sat behind a comparison that could never come out unequal. The recorded grant is the proof that
    /// matters: it is written only while the grant holds, so a copy that holds one and is refused has an entry
    /// that stopped applying, whoever it is signed as. The identity now says only whether the copy was replaced,
    /// and here it was not.
    @Test func theSameSignatureRefusedIsAnEntryThatStoppedApplying() {
        #expect(MenuBarExtent.trust(isTrusted: false, grantedTo: signed, identity: signed) == .stale(grantedTo: signed, replaced: false))
        // Ad-hoc signed code is pinned to a hash every build changes, so two builds are two copies to macOS; the
        // hash the grant was seen under is what the entry is reported as, for the tests and the oracle to read.
        #expect(MenuBarExtent.trust(isTrusted: false, grantedTo: "cdhash:aa", identity: "cdhash:aa") == .stale(grantedTo: "cdhash:aa", replaced: false))
    }

    /// The classic trap: a rebuild, or a build swapped for a release, and the entry left behind for a copy that is
    /// gone. The alert may say a newer copy replaced the one it was granted to, because here it did.
    @Test func anotherSignatureIsAnEntryLeftBehindByAReplacedCopy() {
        #expect(MenuBarExtent.trust(isTrusted: false, grantedTo: signed, identity: local) == .stale(grantedTo: signed, replaced: true))
        #expect(MenuBarExtent.trust(isTrusted: false, grantedTo: "cdhash:aa", identity: "cdhash:bb") == .stale(grantedTo: "cdhash:aa", replaced: true))
    }

    /// Nothing to compare against: the entry is stale all the same, since the recorded grant is the proof, but an
    /// unreadable signature must not be read as a replaced copy, or the alert would assert a cause it cannot know.
    /// The same-copy wording claims nothing about a replacement, so it is the one to fall back to.
    @Test func anUnreadableSignatureClaimsNoReplacement() {
        #expect(MenuBarExtent.trust(isTrusted: false, grantedTo: signed, identity: nil) == .stale(grantedTo: signed, replaced: false))
    }

    /// The identity is what TCC pins to: the certificate where there is one, the code directory hash where there
    /// is not. The test bundle is signed ad hoc by the linker, so the running code reports a hash.
    @Test func theRunningIdentityIsReadFromTheSignature() throws {
        let identity = try #require(CodeSignature.runningIdentity())
        #expect(identity.hasPrefix("cdhash:") || identity.hasPrefix("certificate:"))
        #expect(identity.count > "cdhash:".count)
    }
}

/// The launch that finds Auto chosen and the permission refused offers something once per signed copy, not once
/// per process: the system prompt for a permission never given, the repair alert for an entry that stopped
/// applying. The guard was a static until 0.5.0, so every launch was a first launch and the system prompt came up
/// each time the app started for anyone who had picked Auto and dismissed it; the first cut of 0.5.0 remembered
/// the prompt and forgot the alert, so the same user was shown the alert each time instead.
@MainActor @Suite struct AccessibilityLaunchPrompt {
    static let signed = "certificate:Developer ID Application: Amir Hackett"
    static let local = "certificate:Notchmeter Local"
    let signed = AccessibilityLaunchPrompt.signed
    let local = AccessibilityLaunchPrompt.local

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

    /// The user's own case: Auto chosen, the offer made under this very signature, and the launch after finds the
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

    // MARK: The launch itself, rehearsed on a watcher

    /// A watcher the way the app builds one at launch, on a throwaway defaults suite that is emptied before and
    /// after, with the grant and the signature scripted: the test process is neither trusted nor signed as a
    /// Developer ID build, and a rehearsal must not depend on which it is. Nothing here reaches `.notGranted`
    /// under Auto, which is the one path that would put the real system prompt up.
    func rehearse(_ name: String, side: CompactSide = .auto, grantedTo: String?, askedFor: String? = nil,
                  trusted: Bool = false, identity: String? = AccessibilityLaunchPrompt.signed,
                  _ body: (_ prefs: Preferences, _ launch: (_ trusted: Bool) -> AutoSideWatcher) throws -> Void) rethrows {
        let suite = "NotchmeterTests.AccessibilityLaunch.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = Preferences(defaults: defaults)
        prefs.compactSide = side
        prefs.accessibilityGrantedTo = grantedTo
        prefs.accessibilityAskedFor = askedFor
        let launch = { (trusted: Bool) in
            AutoSideWatcher(prefs: prefs,
                            metrics: { CompactMetrics(notch: CGRect(x: 658, y: 950, width: 195, height: 32), tools: 3, width: { _ in 60 }) },
                            measure: { _ in nil },
                            measureStatusItems: { MenuBarExtent.StatusItemsReading(startX: nil, showsOwnIcon: false) },
                            frontmost: { nil },
                            settleDelays: [],
                            isTrusted: { trusted },
                            identity: { identity })
        }
        try body(prefs, launch)
    }

    /// The 2026-09-19 recording, end to end: Auto chosen, the grant recorded under this very signature, and macOS
    /// refusing it. The first launch reports the stale entry for the alert; the alert, as it goes up, writes the
    /// marker (`rememberAsked` stands in for it here), since the alert is this copy's ask; the next launch finds the
    /// marker and offers nothing, which is what "Not Now" has to mean. The first cut of 0.5.0 wrote the marker for
    /// the system prompt alone, so this returned `.stale` on every launch and the alert came back each time; the
    /// second wrote it at the decision, a second before the alert, so a launch quit in that second lost its offer.
    @Test func theUsersOwnCaseIsOfferedTheAlertOnceAndThenLeftAlone() {
        rehearse("same-copy", grantedTo: signed) { prefs, launch in
            let first = launch(false)
            #expect(first.askAgainIfAutoIsStranded() == .stale(grantedTo: signed, replaced: false))
            #expect(prefs.accessibilityAskedFor == nil, "reporting the entry is not yet asking: the alert has not gone up")
            first.rememberAsked()
            #expect(prefs.accessibilityAskedFor == signed, "the alert is this copy's ask, and is remembered as one")
            #expect(launch(false).askAgainIfAutoIsStranded() == nil, "the next launch offers nothing")
            #expect(prefs.accessibilityGrantedTo == signed, "the entry itself is left alone until Clear and Restart")
        }
    }

    /// A rebuild replaced the copy the grant was given to: the same one offer, reported as a replaced copy so the
    /// alert can say so, and then silence under that signature.
    @Test func aReplacedCopyIsOfferedTheAlertOnceToo() {
        rehearse("replaced", grantedTo: local) { prefs, launch in
            let first = launch(false)
            #expect(first.askAgainIfAutoIsStranded() == .stale(grantedTo: local, replaced: true))
            first.rememberAsked()
            #expect(prefs.accessibilityAskedFor == signed)
            #expect(launch(false).askAgainIfAutoIsStranded() == nil)
        }
    }

    /// 0.5.0 stopped comparing identities to decide staleness, so a recorded grant that is refused is `.stale`
    /// whatever side is chosen today. The launch must not carry that to the alert under a fixed side: Auto is not
    /// in use, the alert's copy is about Auto, and 0.4.7 showed nothing here. Nothing is asked, so nothing is
    /// marked as asked either, and the entry still reads as stale for Settings' Repair button behind the Auto pick.
    @Test func aFixedSideWithARecordedGrantOffersNothingAtLaunch() {
        for side in CompactSide.allCases where side != .auto {
            rehearse("fixed-\(side.rawValue)", side: side, grantedTo: "cdhash:aa", identity: "cdhash:bb") { prefs, launch in
                let watcher = launch(false)
                #expect(watcher.askAgainIfAutoIsStranded() == nil)
                #expect(prefs.accessibilityAskedFor == nil)
                #expect(watcher.trust == .stale(grantedTo: "cdhash:aa", replaced: true))
            }
        }
    }

    /// A grant seen holding closes this copy's turn at the prompt: the offer was answered. Without this a copy
    /// prompted, then granted, then refused would find the marker still set and be offered nothing at all.
    @Test func aGrantThatHoldsClearsTheMarker() {
        rehearse("holding", grantedTo: nil, askedFor: signed) { prefs, launch in
            #expect(launch(true).askAgainIfAutoIsStranded() == nil, "a grant that holds has nothing to ask")
            #expect(prefs.accessibilityGrantedTo == signed, "the grant is recorded under the running signature")
            #expect(prefs.accessibilityAskedFor == nil, "and the marker is cleared")
        }
        // The same on a refresh, which is where a grant given while the app runs is first seen.
        rehearse("holding-refresh", grantedTo: nil, askedFor: signed) { prefs, launch in
            launch(true).refresh()
            #expect(prefs.accessibilityGrantedTo == signed)
            #expect(prefs.accessibilityAskedFor == nil)
        }
    }

    /// The whole life of one signed copy: prompted at launch, granted in the pane, and refused later — the entry
    /// stopping to apply, or the switch turned off. The later refusal is a new situation and earns one fresh
    /// offer, then silence.
    @Test func aRefusalAfterAGrantThatHeldEarnsOneFreshOffer() {
        rehearse("prompted-granted-refused", grantedTo: nil, askedFor: signed) { prefs, launch in
            launch(true).refresh()
            #expect(prefs.accessibilityAskedFor == nil)
            let offered = launch(false)
            #expect(offered.askAgainIfAutoIsStranded() == .stale(grantedTo: signed, replaced: false))
            offered.rememberAsked()
            #expect(prefs.accessibilityAskedFor == signed)
            #expect(launch(false).askAgainIfAutoIsStranded() == nil)
        }
    }

    /// Picking Auto is the invitation, so it offers the alert whatever the marker says: Settings' Repair button and
    /// the pick are how the user asks for it again after Not Now.
    @Test func pickingAutoOffersTheAlertOnDemand() {
        rehearse("picked", side: .leading, grantedTo: signed, askedFor: signed) { prefs, launch in
            #expect(launch(false).sideChosen(.auto) == .stale(grantedTo: signed, replaced: false))
            #expect(prefs.compactSide == .auto)
        }
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
