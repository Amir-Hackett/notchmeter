import Foundation
import Testing
@testable import Notchmeter

/// macOS ties an Accessibility grant to the copy that was granted it and leaves the entry — switch on — when that
/// copy is replaced. Telling that apart from a permission that was never given is what makes the difference between
/// sending the user to a pane that already looks right and offering to clear the entry.
@Suite struct AccessibilityTrust {
    let signed = "certificate:Developer ID Application: Amir Hackett"
    let local = "certificate:Notchmeter Local"

    @Test func trustedIsTrustedWhateverWasRecorded() {
        #expect(MenuBarExtent.trust(isTrusted: true, grantedTo: nil, identity: signed) == .granted)
        #expect(MenuBarExtent.trust(isTrusted: true, grantedTo: local, identity: signed) == .granted)
    }

    @Test func nothingRecordedIsAPermissionNeverGiven() {
        #expect(MenuBarExtent.trust(isTrusted: false, grantedTo: nil, identity: signed) == .notGranted)
    }

    @Test func theSameSignatureRefusedIsAPermissionGivenUp() {
        #expect(MenuBarExtent.trust(isTrusted: false, grantedTo: signed, identity: signed) == .notGranted)
    }

    @Test func anotherSignatureIsAnEntryLeftBehind() {
        #expect(MenuBarExtent.trust(isTrusted: false, grantedTo: signed, identity: local) == .stale(grantedTo: signed))
        // Ad-hoc signed code is pinned to a hash every build changes, so two builds are two copies to macOS.
        #expect(MenuBarExtent.trust(isTrusted: false, grantedTo: "cdhash:aa", identity: "cdhash:bb") == .stale(grantedTo: "cdhash:aa"))
    }

    /// Nothing to compare against: an unreadable signature must not be read as a replaced copy, or the app would
    /// offer to clear an entry that is doing its job.
    @Test func anUnreadableSignatureClaimsNothing() {
        #expect(MenuBarExtent.trust(isTrusted: false, grantedTo: signed, identity: nil) == .notGranted)
    }

    /// The identity is what TCC pins to: the certificate where there is one, the code directory hash where there
    /// is not. The test bundle is signed ad hoc by the linker, so the running code reports a hash.
    @Test func theRunningIdentityIsReadFromTheSignature() throws {
        let identity = try #require(CodeSignature.runningIdentity())
        #expect(identity.hasPrefix("cdhash:") || identity.hasPrefix("certificate:"))
        #expect(identity.count > "cdhash:".count)
    }
}
