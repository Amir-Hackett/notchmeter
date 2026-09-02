import Foundation
import os
import Security
import Sparkle

private let log = Logger(subsystem: "com.amirhackett.notchmeter", category: "updater")

/// Sparkle, started only for a build that could actually take an update. Three facts about the running bundle decide
/// it: Info.plist names an https feed (SUFeedURL); Info.plist carries a real EdDSA public key (SUPublicEDKey decodes
/// to 32 bytes, which the REPLACE_WITH_SPARKLE_PUBLIC_KEY placeholder in scripts/Info.plist does not); and the code
/// signature names a certificate. The ad-hoc signature scripts/build.sh applies names none, and Sparkle could not
/// install over it anyway, so a local build never starts the updater and never sees one of its alerts.
/// Settings › Updates binds the automatic check and download switches and the beta channel to it.
@MainActor
final class Updater {
    enum Gate: Equatable {
        case active
        case noFeed
        case noPublicKey
        case adHocSignature

        var summary: String {
            switch self {
            case .active: "active"
            case .noFeed: "inactive: SUFeedURL is not an https URL"
            case .noPublicKey: "inactive: SUPublicEDKey is not a 32-byte EdDSA key"
            case .adHocSignature: "inactive: the code signature names no certificate"
            }
        }
    }

    nonisolated static func gate(feed: String?, publicKey: String?, signedWithCertificate: Bool) -> Gate {
        guard let feed, let url = URL(string: feed), url.scheme == "https", url.host != nil else { return .noFeed }
        guard let publicKey, let key = Data(base64Encoded: publicKey), key.count == 32 else { return .noPublicKey }
        return signedWithCertificate ? .active : .adHocSignature
    }

    nonisolated static func gate(bundle: Bundle = .main) -> Gate {
        gate(feed: bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
             publicKey: bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
             signedWithCertificate: CodeSignature.runningCodeNamesCertificate())
    }

    /// Nil unless the gate is open; nothing of Sparkle's is touched before then.
    static func start(gate: Gate, beta: @escaping () -> Bool) -> Updater? {
        log.notice("updater \(gate.summary, privacy: .public)")
        return gate == .active ? Updater(beta: beta) : nil
    }

    private let controller: SPUStandardUpdaterController
    private let channels: ChannelDelegate

    private init(beta: @escaping () -> Bool) {
        channels = ChannelDelegate(beta: beta)
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: channels, userDriverDelegate: nil)
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    var automaticallyChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    var automaticallyDownloads: Bool {
        get { controller.updater.automaticallyDownloadsUpdates }
        set { controller.updater.automaticallyDownloadsUpdates = newValue }
    }

    var lastCheck: Date? {
        controller.updater.lastUpdateCheckDate
    }
}

/// The beta channel: with the toggle on, items marked `<sparkle:channel>beta</sparkle:channel>` in the appcast are
/// offered too; off, only unmarked (release) items are.
final class ChannelDelegate: NSObject, SPUUpdaterDelegate {
    private let beta: () -> Bool

    init(beta: @escaping () -> Bool) {
        self.beta = beta
    }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        beta() ? ["beta"] : []
    }
}

/// What the running code's signature says about where it came from.
enum CodeSignature {
    /// True when the signature carries a certificate chain (Developer ID, Apple Development, …); false for the ad-hoc
    /// signature that `codesign --sign -` and the linker apply, and for unsigned code.
    static func runningCodeNamesCertificate() -> Bool {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return false }
        return namesCertificate(staticCode)
    }

    static func namesCertificate(at url: URL) -> Bool {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess, let staticCode else { return false }
        return namesCertificate(staticCode)
    }

    private static func namesCertificate(_ staticCode: SecStaticCode) -> Bool {
        var information: CFDictionary?
        let status = SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
        guard status == errSecSuccess, let info = information as? [String: Any] else { return false }
        let flags = SecCodeSignatureFlags(rawValue: info[kSecCodeInfoFlags as String] as? UInt32 ?? 0)
        let certificates = info[kSecCodeInfoCertificates as String] as? [Any] ?? []
        return !flags.contains(.adhoc) && !certificates.isEmpty
    }
}
