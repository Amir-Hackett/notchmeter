import Foundation
import os

private let log = Logger(subsystem: "com.amirhackett.notchmeter", category: "phone")

/// A phone that has asked to be told when this Mac needs you.
///
/// It registers itself by posting to `POST /v1/device` over the local API, so it must already hold the remote-access
/// token; nothing can register by guessing. What is kept is the Live Activity's push token and a name to show in
/// Settings, in a file beside the drain log — never in the report the API serves, so a device that reads `/v1/limits`
/// cannot enumerate the others.
struct PhoneDevice: Codable, Equatable, Identifiable, Sendable {
    /// The Live Activity's push token, hex, as ActivityKit hands it to the phone. Also the identity: re-registering
    /// the same activity replaces the row rather than adding one.
    let id: String
    var name: String
    var registeredAt: Date
    var lastPushedAt: Date?
    /// Why the last push failed, for the Settings row; nil while it is working.
    var lastError: String?
}

/// The registered phones, persisted as one small JSON file.
@MainActor
final class PhoneRegistry {
    private(set) var devices: [PhoneDevice] = []
    private let file: URL

    init(file: URL = Paths.applicationSupport.appendingPathComponent("phones-v1.json")) {
        self.file = file
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: file) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        devices = (try? decoder.decode([PhoneDevice].self, from: data)) ?? []
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        guard let data = try? encoder.encode(devices) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    /// Adds a phone, or refreshes the one already holding that push token.
    func register(id: String, name: String, now: Date = Date()) {
        guard !id.isEmpty else { return }
        if let index = devices.firstIndex(where: { $0.id == id }) {
            devices[index].name = name
            devices[index].lastError = nil
        } else {
            devices.append(PhoneDevice(id: id, name: name, registeredAt: now, lastPushedAt: nil, lastError: nil))
            log.notice("registered a phone")
        }
        save()
    }

    func remove(id: String) {
        devices.removeAll { $0.id == id }
        save()
    }

    func removeAll() {
        devices = []
        save()
    }

    func note(id: String, pushedAt: Date?, error: String?) {
        guard let index = devices.firstIndex(where: { $0.id == id }) else { return }
        if let pushedAt { devices[index].lastPushedAt = pushedAt }
        devices[index].lastError = error
        save()
    }
}

/// Sends the notch's state to every registered phone, and decides when it is worth sending at all.
@MainActor
final class PhonePusher {
    private let registry: PhoneRegistry
    private let credentials: () -> APNs.Credentials?
    private let signingKey: () -> String?
    private var signer: APNs.Signer?
    private var signerKey: String?
    /// The last state actually sent, so an unchanged one costs nothing. ActivityKit budgets pushes per activity per
    /// hour, and hooks fire far more often than the picture changes: a turn ending in a project you are watching is
    /// news, the twentieth tool call of that turn is not.
    private var lastSent: APNs.ActivityState?
    private var lastSentAt: Date?
    /// Never more than one push every this often, whatever changed, so a burst of hook events cannot spend the
    /// budget. A blocking wait ignores it, because that is the whole reason the phone is on the table.
    nonisolated static let floor: TimeInterval = 20

    init(registry: PhoneRegistry, credentials: @escaping () -> APNs.Credentials?, signingKey: @escaping () -> String?) {
        self.registry = registry
        self.credentials = credentials
        self.signingKey = signingKey
    }

    /// Whether a state is worth a push now: a change of state or of who wants you always is, a blocking wait always
    /// is, and everything else waits out the floor. Pure, so the rule is testable without a network.
    nonisolated static func shouldSend(_ next: APNs.ActivityState, last: APNs.ActivityState?, lastSentAt: Date?,
                           urgent: Bool, now: Date = Date(), floor: TimeInterval = PhonePusher.floor) -> Bool {
        guard let last else { return true }
        if urgent { return true }
        if next.state != last.state || next.tool != last.tool || next.project != last.project { return true }
        if let lastSentAt, now.timeIntervalSince(lastSentAt) < floor { return false }
        return next != last
    }

    func send(_ state: APNs.ActivityState, alert: (title: String, body: String)? = nil, urgent: Bool = false, now: Date = Date()) {
        guard !registry.devices.isEmpty, let credentials = credentials(), credentials.isComplete else { return }
        guard Self.shouldSend(state, last: lastSent, lastSentAt: lastSentAt, urgent: urgent, now: now) else { return }
        guard let signer = makeSigner(credentials) else { return }
        lastSent = state
        lastSentAt = now
        let devices = registry.devices
        Task { [weak self] in
            guard let body = try? APNs.payload(event: "update", state: state, alert: alert, staleAfter: 30 * 60, now: now) else { return }
            guard let bearer = try? await signer.bearer(now: now) else {
                log.error("could not sign an APNs token")
                return
            }
            for device in devices {
                let outcome = await Self.post(body: body, to: device.id, bearer: bearer, credentials: credentials, urgent: urgent)
                switch outcome {
                case .sent:
                    self?.registry.note(id: device.id, pushedAt: now, error: nil)
                case .gone:
                    // The phone dropped the activity or deleted the app; keeping the row would only fail forever.
                    log.notice("a phone's activity is gone, unregistering it")
                    self?.registry.remove(id: device.id)
                case .failed(let reason):
                    self?.registry.note(id: device.id, pushedAt: nil, error: reason)
                }
            }
        }
    }

    private func makeSigner(_ credentials: APNs.Credentials) -> APNs.Signer? {
        guard let pem = signingKey() else { return nil }
        if let signer, signerKey == pem { return signer }
        guard let made = try? APNs.Signer(pem: pem, credentials: credentials) else {
            log.error("the APNs key could not be read as a P-256 private key")
            return nil
        }
        signer = made
        signerKey = pem
        return made
    }

    enum Outcome: Equatable {
        case sent, gone, failed(String)
    }

    /// One `POST /3/device/<token>`. URLSession speaks HTTP/2, which APNs requires.
    nonisolated static func post(body: Data, to deviceToken: String, bearer: String,
                                 credentials: APNs.Credentials, urgent: Bool) async -> Outcome {
        guard let url = URL(string: "\(APNs.host)/3/device/\(deviceToken)") else { return .failed("bad device token") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("bearer \(bearer)", forHTTPHeaderField: "authorization")
        request.setValue(credentials.topic, forHTTPHeaderField: "apns-topic")
        request.setValue("liveactivity", forHTTPHeaderField: "apns-push-type")
        // 10 wakes the screen for a wait; 5 lets Apple hold a routine refresh until it is cheap.
        request.setValue(urgent ? "10" : "5", forHTTPHeaderField: "apns-priority")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        do {
            let (data, response) = try await NetworkSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failed("no response") }
            switch http.statusCode {
            case 200: return .sent
            case 410: return .gone
            default:
                let reason = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["reason"] as? String
                // 400 BadDeviceToken means the same thing 410 does: this activity will never accept another push.
                if reason == "BadDeviceToken" || reason == "Unregistered" { return .gone }
                return .failed(reason ?? "HTTP \(http.statusCode)")
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
