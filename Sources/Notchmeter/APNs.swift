import CryptoKit
import Foundation
import os

private let log = Logger(subsystem: "com.amirhackett.notchmeter", category: "apns")

/// Pushing the notch's state to a phone, without a server in the middle.
///
/// A Live Activity on the phone can only be updated by a push from APNs, so something has to talk to Apple. That
/// something is this Mac: it holds an APNs signing key (a `.p8` from the developer account), signs its own ES256
/// bearer token, and posts straight to `api.push.apple.com`. There is no relay, no account, no third party holding
/// anything — the same shape as every other reading in the app, where the Mac is the only place the data exists.
///
/// The phone registers by posting its Live Activity push token to `POST /v1/device` over the local API, which means
/// it can only do so from a device already holding the remote-access token. What is pushed is the small state below:
/// which assistant wants you, on what project, how full the tightest window is. No transcript, no project path
/// beyond the folder name the notch already shows, and no cost.
enum APNs {
    /// Where the `.p8` lives. The IDs beside it are not secret and sit in defaults; the key itself does not.
    static let keychainService = "Notchmeter APNs key"
    static let host = "https://api.push.apple.com"
    /// Apple refuses a bearer token older than an hour and one reissued more often than every twenty minutes.
    static let tokenLifetime: TimeInterval = 50 * 60

    struct Credentials: Equatable, Sendable {
        /// The 10-character Key ID of the `.p8`, its `kid`.
        let keyID: String
        /// The developer account's Team ID, the token's `iss`.
        let teamID: String
        /// The phone app's bundle identifier; the Live Activity topic is this plus `.push-type.liveactivity`.
        let bundleID: String

        var isComplete: Bool { keyID.count == 10 && !teamID.isEmpty && !bundleID.isEmpty }
        var topic: String { "\(bundleID).push-type.liveactivity" }
    }

    /// What the phone's Live Activity shows. Deliberately small: a Live Activity payload is capped at 4 KB, and
    /// everything here is something the notch already puts on screen.
    struct ActivityState: Codable, Equatable, Sendable {
        /// "waiting", "working" or "idle" — the same three the rings use.
        var state: String
        /// The assistant this is about, by `ToolID` raw value.
        var tool: String?
        /// The project folder's name, never its path.
        var project: String?
        /// How many sessions are running across every assistant.
        var sessions: Int
        /// The tightest window: its label, how much is gone, and whether it is behind pace.
        var windowLabel: String?
        var windowUsed: Double?
        var windowPace: String?
        /// The one line the Advisor would put under the Cost card.
        var advice: String?
        /// When this was true on the Mac, so the phone can say how stale it is.
        var updatedAt: Date
    }

    /// The signing key and the bearer token it makes, cached until Apple would refuse it.
    actor Signer {
        private let key: P256.Signing.PrivateKey
        private let credentials: Credentials
        private var cached: (token: String, issued: Date)?

        /// The `.p8` exactly as the developer account hands it over, PEM including the BEGIN PRIVATE KEY lines.
        init(pem: String, credentials: Credentials) throws {
            self.key = try P256.Signing.PrivateKey(pemRepresentation: pem)
            self.credentials = credentials
        }

        func bearer(now: Date = Date()) throws -> String {
            if let cached, now.timeIntervalSince(cached.issued) < APNs.tokenLifetime { return cached.token }
            let header = ["alg": "ES256", "kid": credentials.keyID]
            let claims: [String: Any] = ["iss": credentials.teamID, "iat": Int(now.timeIntervalSince1970)]
            let signing = try APNs.base64URL(JSONSerialization.data(withJSONObject: header, options: [.sortedKeys]))
                + "." + APNs.base64URL(JSONSerialization.data(withJSONObject: claims, options: [.sortedKeys]))
            // JWS wants the raw r‖s pair, not the DER wrapper.
            let signature = try key.signature(for: Data(signing.utf8)).rawRepresentation
            let token = signing + "." + APNs.base64URL(signature)
            cached = (token, now)
            return token
        }
    }

    /// The `.p8` PEM, from the Keychain. Like the remote-access token this is Notchmeter's own secret rather than a
    /// borrowed one: it is a key the user downloaded from their own developer account for their own phone app.
    static func signingKey() -> String? {
        guard let data = try? Keychain.genericPassword(service: keychainService, prompt: false),
              let pem = String(data: data, encoding: .utf8), !pem.isEmpty
        else { return nil }
        return pem
    }

    /// Stores a `.p8`, after checking it parses as the P-256 key APNs signs with — a file that cannot sign is worth
    /// refusing at the moment it is chosen rather than at the first push.
    @discardableResult
    static func setSigningKey(_ pem: String) -> Bool {
        guard (try? P256.Signing.PrivateKey(pemRepresentation: pem)) != nil else { return false }
        do {
            try Keychain.set(Data(pem.utf8), service: keychainService)
            return true
        } catch {
            log.error("could not store the APNs key: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    static func forgetSigningKey() {
        try? Keychain.remove(service: keychainService)
    }

    /// base64url without padding, as every part of a JWT is encoded.
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// The body of a Live Activity push. `event` is "update" or "end"; "start" is the phone's own job, because only
    /// it knows the activity's attributes.
    static func payload(event: String, state: ActivityState, alert: (title: String, body: String)?,
                        staleAfter: TimeInterval? = nil, dismissAfter: Date? = nil, now: Date = Date()) throws -> Data {
        let content = try JSONSerialization.jsonObject(with: JSONEncoder.apns.encode(state))
        var aps: [String: Any] = [
            "timestamp": Int(now.timeIntervalSince1970),
            "event": event,
            "content-state": content,
        ]
        if let staleAfter { aps["stale-date"] = Int(now.addingTimeInterval(staleAfter).timeIntervalSince1970) }
        if let dismissAfter { aps["dismissal-date"] = Int(dismissAfter.timeIntervalSince1970) }
        if let alert {
            // A Live Activity alert wakes the phone's screen; only a blocking wait earns one.
            aps["alert"] = ["title": alert.title, "body": alert.body]
        }
        return try JSONSerialization.data(withJSONObject: ["aps": aps], options: [.sortedKeys])
    }
}

extension APNs.ActivityState {
    /// The state to push, read off the same report the panel draws. `focus` is the session whose event prompted
    /// this, when there was one, so the phone names the assistant that wants you rather than an arbitrary one.
    ///
    /// The tightest window is the fullest one across every tool, which is what the phone has room to show: one ring
    /// answering "how close am I", beside the one line answering "what should I do".
    static func from(report: UsageReport, focus: AgentSession?, now: Date = Date()) -> APNs.ActivityState {
        let running = report.sessions.filter { $0.isWaiting || $0.isWorking }
        let waiting = report.sessions.first(where: \.isWaiting)
        let subject = focus ?? waiting ?? running.first
        let state: String = if waiting != nil {
            "waiting"
        } else if !running.isEmpty {
            "working"
        } else {
            "idle"
        }
        var label: String?, used: Double?, pace: String?
        let windows = report.order.compactMap { report.tools[$0]?.reading }.flatMap(\.windows)
            .filter { !$0.hiddenByDefault && $0.usedFraction != nil }
        if let tightest = windows.max(by: { ($0.usedFraction ?? 0) < ($1.usedFraction ?? 0) }) {
            label = tightest.label
            used = tightest.usedFraction
            pace = Pace.status(for: tightest, now: now).map { String(describing: $0) }
        }
        return APNs.ActivityState(state: state, tool: subject?.tool.rawValue, project: subject?.project,
                                  sessions: running.count, windowLabel: label, windowUsed: used, windowPace: pace,
                                  advice: report.advice.first?.text, updatedAt: now)
    }
}

extension JSONEncoder {
    /// Dates as seconds since the epoch, which is what the phone's decoder expects and what APNs itself uses.
    static let apns: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
}
