import Foundation
import Testing
@testable import Notchmeter

/// The updater starts only for a build that could take an update: an https feed, a real 32-byte EdDSA public key in
/// place of the placeholder scripts/Info.plist ships, and a code signature that names a certificate.
@Suite struct UpdaterGate {
    let feed = "https://github.com/Amir-Hackett/notchmeter/releases/latest/download/appcast.xml"
    let key = Data((0..<32).map { UInt8($0) }).base64EncodedString()

    @Test func signedBuildWithARealKeyIsActive() {
        #expect(Updater.gate(feed: feed, publicKey: key, signedWithCertificate: true) == .active)
    }

    @Test func placeholderOrMalformedKeyStaysInactive() {
        #expect(Updater.gate(feed: feed, publicKey: "REPLACE_WITH_SPARKLE_PUBLIC_KEY", signedWithCertificate: true) == .noPublicKey)
        #expect(Updater.gate(feed: feed, publicKey: nil, signedWithCertificate: true) == .noPublicKey)
        #expect(Updater.gate(feed: feed, publicKey: "", signedWithCertificate: true) == .noPublicKey)
        let short = Data(repeating: 1, count: 31).base64EncodedString()
        #expect(Updater.gate(feed: feed, publicKey: short, signedWithCertificate: true) == .noPublicKey)
    }

    @Test func feedMustBeHTTPS() {
        #expect(Updater.gate(feed: nil, publicKey: key, signedWithCertificate: true) == .noFeed)
        #expect(Updater.gate(feed: "", publicKey: key, signedWithCertificate: true) == .noFeed)
        #expect(Updater.gate(feed: "http://example.com/appcast.xml", publicKey: key, signedWithCertificate: true) == .noFeed)
    }

    @Test func adHocSignatureStaysInactive() {
        #expect(Updater.gate(feed: feed, publicKey: key, signedWithCertificate: false) == .adHocSignature)
    }

    /// The shipped plist must name the real feed and either the exact placeholder (updater off) or a usable key.
    @Test func shippedPlistIsEitherPlaceholderOrReady() throws {
        let plist = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/Info.plist")
        let values = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any])
        let publicKey = values["SUPublicEDKey"] as? String
        let gate = Updater.gate(feed: values["SUFeedURL"] as? String, publicKey: publicKey, signedWithCertificate: true)
        #expect(gate == .active || (gate == .noPublicKey && publicKey == "REPLACE_WITH_SPARKLE_PUBLIC_KEY"))
        #expect(values["SUEnableAutomaticChecks"] as? Bool == true)
        #expect(values["SUScheduledCheckInterval"] as? Int == 86400)
    }

    /// Apple's own binaries name a chain; the test bundle, which the linker signs ad hoc, names none; nothing else counts.
    @Test func certificateCheckReadsTheSignature() {
        #expect(CodeSignature.namesCertificate(at: URL(fileURLWithPath: "/bin/ls")))
        #expect(CodeSignature.namesCertificate(at: Bundle(for: TestBundleMarker.self).bundleURL) == false)
        #expect(CodeSignature.namesCertificate(at: URL(fileURLWithPath: "/nonexistent")) == false)
    }
}

private final class TestBundleMarker {}
