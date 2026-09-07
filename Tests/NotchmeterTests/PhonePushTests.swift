import CryptoKit
import Foundation
import Testing
@testable import Notchmeter

/// Pushing to a phone: the ES256 token Apple wants, the Live Activity payload, the rule that decides when a push is
/// worth spending, and the state read off a report.
@Suite(.serialized) struct PhonePushing {
    init() { Localization.use(language: "en") }

    static let credentials = APNs.Credentials(keyID: "ABCDE12345", teamID: "N38C775YA8", bundleID: "com.example.phone")

    @Test func theTopicIsTheBundleIDPlusApplesSuffix() {
        #expect(Self.credentials.topic == "com.example.phone.push-type.liveactivity")
        #expect(Self.credentials.isComplete)
        #expect(!APNs.Credentials(keyID: "short", teamID: "T", bundleID: "b").isComplete)
        #expect(!APNs.Credentials(keyID: "ABCDE12345", teamID: "", bundleID: "b").isComplete)
    }

    @Test func base64URLDropsPaddingAndTheTwoUnsafeCharacters() {
        #expect(APNs.base64URL(Data([0xFB, 0xFF, 0xFE])) == "-__-")
        #expect(!APNs.base64URL(Data([1])).contains("="))
    }

    @Test func theBearerIsAnES256JWTAndIsReusedUntilItGoesStale() async throws {
        let key = P256.Signing.PrivateKey()
        let signer = try APNs.Signer(pem: key.pemRepresentation, credentials: Self.credentials)
        let start = Date()
        let token = try await signer.bearer(now: start)

        let parts = token.split(separator: ".")
        #expect(parts.count == 3)
        func decode(_ part: Substring) throws -> [String: Any] {
            var text = String(part).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            while text.count % 4 != 0 { text += "=" }
            return try #require(try JSONSerialization.jsonObject(with: #require(Data(base64Encoded: text))) as? [String: Any])
        }
        let header = try decode(parts[0]), claims = try decode(parts[1])
        #expect(header["alg"] as? String == "ES256")
        #expect(header["kid"] as? String == "ABCDE12345")
        #expect(claims["iss"] as? String == "N38C775YA8")
        #expect(claims["iat"] as? Int == Int(start.timeIntervalSince1970))

        // Apple rejects a signature that is not the raw r‖s pair, so it must be 64 bytes, not DER.
        var raw = String(parts[2]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while raw.count % 4 != 0 { raw += "=" }
        #expect(try #require(Data(base64Encoded: raw)).count == 64)

        // Reused inside the lifetime, reissued past it — Apple refuses a token over an hour old.
        #expect(try await signer.bearer(now: start.addingTimeInterval(APNs.tokenLifetime - 1)) == token)
        #expect(try await signer.bearer(now: start.addingTimeInterval(APNs.tokenLifetime + 1)) != token)
    }

    @Test func aKeyThatIsNotAP256KeyIsRefusedWhenItIsChosen() {
        #expect(throws: (any Error).self) { try APNs.Signer(pem: "not a key", credentials: Self.credentials) }
    }

    static func state(_ name: String, tool: String? = "claude", project: String? = "notchmeter", sessions: Int = 1) -> APNs.ActivityState {
        APNs.ActivityState(state: name, tool: tool, project: project, sessions: sessions, windowLabel: "Session",
                           windowUsed: 0.4, windowPace: "onTrack", advice: nil, updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test func thePayloadCarriesTheLiveActivityShape() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let data = try APNs.payload(event: "update", state: Self.state("waiting"), alert: ("Claude Code", "notchmeter"),
                                    staleAfter: 1800, now: now)
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let aps = try #require(root["aps"] as? [String: Any])
        #expect(aps["event"] as? String == "update")
        #expect(aps["timestamp"] as? Int == 1_700_000_000)
        #expect(aps["stale-date"] as? Int == 1_700_000_000 + 1800)
        let alert = try #require(aps["alert"] as? [String: Any])
        #expect(alert["title"] as? String == "Claude Code")
        let content = try #require(aps["content-state"] as? [String: Any])
        #expect(content["state"] as? String == "waiting")
        #expect(content["project"] as? String == "notchmeter")
        #expect(content["sessions"] as? Int == 1)
        // Dates go as seconds, which is what APNs and the phone's decoder both read.
        #expect(content["updatedAt"] as? Double == 1_700_000_000)
        // A Live Activity payload is capped at 4 KB.
        #expect(data.count < 4096)

        let quiet = try APNs.payload(event: "update", state: Self.state("working"), alert: nil, now: now)
        let quietAPS = try #require(try #require(try JSONSerialization.jsonObject(with: quiet) as? [String: Any])["aps"] as? [String: Any])
        #expect(quietAPS["alert"] == nil)
    }

    @Test func aPushIsSpentOnlyOnSomethingWorthSaying() {
        let now = Date()
        let working = Self.state("working")
        // Nothing sent yet: the phone has no picture, so anything is worth sending.
        #expect(PhonePusher.shouldSend(working, last: nil, lastSentAt: nil, urgent: false, now: now))
        // The same picture again, inside the floor: not worth it. A burst of hook events lands here.
        #expect(!PhonePusher.shouldSend(working, last: working, lastSentAt: now, urgent: false, now: now))
        // A change of state always goes, however recent the last push.
        #expect(PhonePusher.shouldSend(Self.state("waiting"), last: working, lastSentAt: now, urgent: false, now: now))
        // So does a different assistant, or the same one in another project.
        #expect(PhonePusher.shouldSend(Self.state("working", tool: "codex"), last: working, lastSentAt: now, urgent: false, now: now))
        #expect(PhonePusher.shouldSend(Self.state("working", project: "other"), last: working, lastSentAt: now, urgent: false, now: now))
        // A blocking wait ignores the floor entirely — it is the reason the phone is on the table.
        #expect(PhonePusher.shouldSend(working, last: working, lastSentAt: now, urgent: true, now: now))
        // A smaller change waits out the floor, then goes.
        let more = Self.state("working", sessions: 2)
        #expect(!PhonePusher.shouldSend(more, last: working, lastSentAt: now, urgent: false, now: now))
        #expect(PhonePusher.shouldSend(more, last: working, lastSentAt: now, urgent: false, now: now.addingTimeInterval(PhonePusher.floor + 1)))
        // And an unchanged picture past the floor still is not worth a push.
        #expect(!PhonePusher.shouldSend(working, last: working, lastSentAt: now, urgent: false, now: now.addingTimeInterval(3600)))
    }

    @MainActor @Test func theRegistryReplacesADeviceRatherThanDuplicatingIt() throws {
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("phones-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let registry = PhoneRegistry(file: file)
        registry.register(id: "aa11", name: "iPhone")
        registry.register(id: "bb22", name: "iPad")
        registry.register(id: "aa11", name: "Amir's iPhone")
        #expect(registry.devices.count == 2)
        #expect(registry.devices.first { $0.id == "aa11" }?.name == "Amir's iPhone")
        registry.register(id: "", name: "nothing")
        #expect(registry.devices.count == 2)

        registry.note(id: "aa11", pushedAt: nil, error: "TooManyRequests")
        #expect(registry.devices.first { $0.id == "aa11" }?.lastError == "TooManyRequests")

        // It survives a relaunch, and a removal sticks.
        #expect(PhoneRegistry(file: file).devices.count == 2)
        registry.remove(id: "bb22")
        #expect(PhoneRegistry(file: file).devices.map(\.id) == ["aa11"])
        registry.removeAll()
        #expect(PhoneRegistry(file: file).devices.isEmpty)
    }

    @Test func registrationNeedsAPushTokenAndNamesTheDeviceWhenItDoesNot() throws {
        let full = try #require(LocalAPI.registration(from: Data(#"{"pushToken":"ab12","name":"Amir's iPhone"}"#.utf8)))
        #expect(full.token == "ab12")
        #expect(full.name == "Amir's iPhone")
        #expect(!full.remove)
        let bare = try #require(LocalAPI.registration(from: Data(#"{"pushToken":"ab12"}"#.utf8)))
        #expect(bare.name == "iPhone")
        // The phone dropping an activity it ended still names the token, because that is the device's identity.
        #expect(try #require(LocalAPI.registration(from: Data(#"{"pushToken":"ab12","remove":true}"#.utf8))).remove)
        #expect(LocalAPI.registration(from: Data(#"{"name":"x"}"#.utf8)) == nil)
        #expect(LocalAPI.registration(from: Data("not json".utf8)) == nil)
        // A token that is empty or only spaces identifies nothing, so it is refused rather than guessed at.
        #expect(LocalAPI.registration(from: Data(#"{"pushToken":""}"#.utf8)) == nil)
        #expect(LocalAPI.registration(from: Data(#"{"pushToken":"   "}"#.utf8)) == nil)
    }

    @MainActor @Test func aRegistrationOverTheAPIReachesTheRegistry() {
        final class Box: @unchecked Sendable { var calls: [(String, String, Bool)] = [] }
        let box = Box()
        let api = LocalAPI(port: 6737, device: { box.calls.append(($0, $1, $2)) }, report: { UsageReport(tools: [:], cost: nil, advice: []) })
        func post(_ json: String) -> String {
            String(decoding: api.respond(to: LocalAPI.Request(method: "POST", path: "/v1/device",
                                                              headers: ["host": "127.0.0.1:6737"], body: Data(json.utf8))), as: UTF8.self)
        }
        #expect(post(#"{"pushToken":"ff00","name":"iPhone"}"#).hasPrefix("HTTP/1.1 202 Accepted"))
        #expect(post(#"{"pushToken":"ff00","remove":true}"#).hasPrefix("HTTP/1.1 202 Accepted"))
        #expect(box.calls.map(\.0) == ["ff00", "ff00"])
        #expect(box.calls.map(\.2) == [false, true])
        #expect(post("{}").hasPrefix("HTTP/1.1 400"))
    }

    @Test func theStateIsReadOffTheReportThePanelDraws() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let session = AgentSession(id: "s1", tool: .claude, project: "notchmeter", state: .waiting(since: now.addingTimeInterval(-30)),
                                   started: now.addingTimeInterval(-600), lastEvent: now, turnStarted: now.addingTimeInterval(-120))
        let quiet = AgentSession(id: "s2", tool: .codex, project: "other", state: .working(since: now.addingTimeInterval(-60)),
                                 started: now.addingTimeInterval(-600), lastEvent: now, turnStarted: now.addingTimeInterval(-60))
        let windows = [
            LimitWindow(id: "session", label: .key("Session"), usedFraction: 0.2, resetsAt: now.addingTimeInterval(3600), periodDuration: 5 * 3600),
            LimitWindow(id: "weekly", label: .key("Weekly"), usedFraction: 0.86, resetsAt: now.addingTimeInterval(86400), periodDuration: 7 * 86400),
            // Hidden windows are not on the card, so they are not what the phone reports either.
            LimitWindow(id: "secret", label: .key("Weekly"), usedFraction: 0.99, resetsAt: now.addingTimeInterval(86400), hiddenByDefault: true),
        ]
        let reading = UsageReading(tool: .claude, windows: windows, plan: "Max 5x", fetchedAt: now, observedAt: nil)
        let advice = Advice(id: "a1", tool: .claude, priority: .attention, symbol: "!", text: "Answer Claude Code in notchmeter.")
        let report = UsageReport(tools: [.claude: .ready(reading)], order: [.claude], cost: nil, advice: [advice],
                                 sessions: [session, quiet], now: now)

        let state = APNs.ActivityState.from(report: report, focus: session, now: now)
        #expect(state.state == "waiting")
        #expect(state.tool == "claude")
        #expect(state.project == "notchmeter")
        #expect(state.sessions == 2)
        #expect(state.windowUsed == 0.86)
        #expect(state.advice == "Answer Claude Code in notchmeter.")
        #expect(state.updatedAt == now)

        // With nobody waiting it says working, and with nobody at all, idle.
        let busy = UsageReport(tools: [.claude: .ready(reading)], order: [.claude], cost: nil, advice: [], sessions: [quiet], now: now)
        #expect(APNs.ActivityState.from(report: busy, focus: nil, now: now).state == "working")
        #expect(APNs.ActivityState.from(report: busy, focus: nil, now: now).tool == "codex")
        let empty = UsageReport(tools: [:], cost: nil, advice: [], sessions: [], now: now)
        let idle = APNs.ActivityState.from(report: empty, focus: nil, now: now)
        #expect(idle.state == "idle")
        #expect(idle.sessions == 0)
        #expect(idle.windowLabel == nil)
    }

    @Test func aDeadDeviceTokenIsTreatedAsGoneSoItStopsBeingRetried() {
        #expect(PhonePusher.Outcome.gone == .gone)
        #expect(PhonePusher.Outcome.failed("x") != .failed("y"))
    }
}
