import Foundation
import os
import Security
import Sparkle

private let log = Logger(subsystem: "com.amirhackett.notchmeter", category: "updater")

/// Sparkle, started only for a build that could actually take an update. Three facts about the running bundle decide
/// it: Info.plist names an https feed (SUFeedURL); Info.plist carries a real EdDSA public key (SUPublicEDKey decodes
/// to 32 bytes, which the REPLACE_WITH_SPARKLE_PUBLIC_KEY placeholder in scripts/Info.plist does not); and the code
/// signature is a Developer ID one, the identity scripts/release.sh signs with and the only one Sparkle could install
/// a released build over. Naming any certificate is deliberately not enough: scripts/build.sh prefers the self-signed
/// "Notchmeter Local" identity from scripts/signing-identity.sh over ad-hoc signing (since 2026-09-03), and until
/// 0.5.0 that identity opened the gate, so a developer's own build polled the public appcast with a non-numeric
/// CFBundleVersion and could be offered a release it could never install over its local signature. A local build,
/// self-signed or ad hoc, therefore never starts the updater and never sees one of its alerts.
/// Settings › Updates binds the automatic check and download switches and the beta channel to it.
@MainActor
final class Updater {
    enum Gate: Equatable {
        case active
        case noFeed
        case noPublicKey
        case unsignedForDistribution

        var summary: String {
            switch self {
            case .active: "active"
            case .noFeed: "inactive: SUFeedURL is not an https URL"
            case .noPublicKey: "inactive: SUPublicEDKey is not a 32-byte EdDSA key"
            case .unsignedForDistribution: "inactive: not signed with Developer ID"
            }
        }
    }

    nonisolated static func gate(feed: String?, publicKey: String?, signedWithCertificate: Bool) -> Gate {
        guard let feed, let url = URL(string: feed), url.scheme == "https", url.host != nil else { return .noFeed }
        guard let publicKey, let key = Data(base64Encoded: publicKey), key.count == 32 else { return .noPublicKey }
        return signedWithCertificate ? .active : .unsignedForDistribution
    }

    nonisolated static func gate(bundle: Bundle = .main) -> Gate {
        gate(feed: bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
             publicKey: bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
             signedWithCertificate: CodeSignature.runningCodeIsDeveloperIDSigned())
    }

    /// Nil unless the gate is open; nothing of Sparkle's is touched before then. `session` is told when Sparkle
    /// puts a window on screen and when the last of them has gone (UpdateSession).
    static func start(gate: Gate, beta: @escaping () -> Bool, session: @escaping (Bool) -> Void = { _ in }) -> Updater? {
        log.notice("updater \(gate.summary, privacy: .public)")
        return gate == .active ? Updater(beta: beta, session: session) : nil
    }

    private let controller: SPUStandardUpdaterController
    private let channels: ChannelDelegate
    private let session: UpdateSession

    private init(beta: @escaping () -> Bool, session: @escaping (Bool) -> Void) {
        channels = ChannelDelegate(beta: beta)
        self.session = UpdateSession(hold: session)
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: channels, userDriverDelegate: self.session)
    }

    func checkForUpdates() {
        // The "Checking for updates…" window is up before Sparkle asks its user driver delegate anything, so the
        // session opens here rather than waiting to be told about it.
        session.begin()
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

/// What the app does around Sparkle's windows. The panel draws at screen-saver level and covers most of the screen
/// while it is open, so every window Sparkle puts up — the "Checking for updates…" window, the update alert, the
/// "you're up to date" alert — opens underneath it, and a check looks like nothing happened. `hold(true)` closes the
/// panel and keeps it closed for as long as a session is on screen, the rule the Settings window already goes by;
/// Sparkle ends every session, whether an alert was dismissed, a version skipped or an error shown, through
/// `standardUserDriverWillFinishUpdateSession`.
final class UpdateSession: NSObject, SPUStandardUserDriverDelegate {
    private let hold: (Bool) -> Void
    private var holding = false

    init(hold: @escaping (Bool) -> Void) {
        self.hold = hold
    }

    func begin() {
        guard !holding else { return }
        holding = true
        hold(true)
    }

    func end() {
        guard holding else { return }
        holding = false
        hold(false)
    }

    /// Sparkle asks before it pulls a background app in front of whatever the user is doing on a scheduled check.
    /// Answering yes leaves the alert where Sparkle judges it belongs and brings
    /// `standardUserDriverWillHandleShowingUpdate` with it, which is what gets the panel out of its way.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Sparkle's delegate calls all arrive on the main thread; it asserts as much before each one.
    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        MainActor.assumeIsolated { begin() }
    }

    func standardUserDriverWillShowModalAlert() {
        MainActor.assumeIsolated { begin() }
    }

    func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated { end() }
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
    /// True only when the running code carries a Developer ID leaf: the identity scripts/release.sh signs with, and
    /// the only signature Sparkle could install a released build over. The self-signed "Notchmeter Local" identity
    /// scripts/build.sh prefers does name a certificate, but is not one of these, so a local build stays outside the
    /// updater gate; an Apple Development build is excluded for the same reason. The leaf's common name is the
    /// discriminator rather than the Team ID, because a Team ID alone would admit any Apple Development build.
    static func runningCodeIsDeveloperIDSigned() -> Bool {
        isDeveloperID(runningIdentity())
    }

    /// The rule behind `runningCodeIsDeveloperIDSigned`, over the string `runningIdentity` produces, so it can be
    /// tested without a Developer ID-signed host. A `cdhash:` identity (ad hoc) and nil (unreadable code) both fail.
    static func isDeveloperID(_ identity: String?) -> Bool {
        identity?.hasPrefix("certificate:Developer ID Application:") ?? false
    }

    /// What macOS ties a privacy grant to. Code signed with a certificate is pinned to the certificate, so every
    /// rebuild signed with the same one keeps the grants it was given; ad-hoc signed code names no certificate and
    /// is pinned to its code directory hash instead, which every build changes. Nil when the code cannot be read.
    static func runningIdentity() -> String? {
        // The running binary's signature cannot change under it, so this is read once and kept.
        if let cached = cachedIdentity { return cached }
        let identity = readRunningIdentity()
        cachedIdentity = identity
        return identity
    }

    private nonisolated(unsafe) static var cachedIdentity: String?

    private static func readRunningIdentity() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        return identity(staticCode)
    }

    private static func identity(_ staticCode: SecStaticCode) -> String? {
        var information: CFDictionary?
        let status = SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
        guard status == errSecSuccess, let info = information as? [String: Any] else { return nil }
        if let certificates = info[kSecCodeInfoCertificates as String] as? [SecCertificate], let leaf = certificates.first {
            var name: CFString?
            if SecCertificateCopyCommonName(leaf, &name) == errSecSuccess, let name = name as String? {
                return "certificate:\(name)"
            }
        }
        guard let hash = info[kSecCodeInfoUnique as String] as? Data else { return nil }
        return "cdhash:" + hash.map { String(format: "%02x", $0) }.joined()
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
