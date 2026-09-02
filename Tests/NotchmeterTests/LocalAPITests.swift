import Foundation
import Testing
@testable import Notchmeter

/// The loopback API: what it refuses (any Origin not allowed, any Host but the loopback address), what it parses,
/// and a remote hook posted to it landing in the session tracker.
@Suite(.serialized) struct LoopbackAPI {
    init() { Localization.use(language: "en") }

    @Test func refusesWebOriginsAndForeignHosts() {
        #expect(LocalAPI.refusal(host: "127.0.0.1:6737", origin: nil, port: 6737, allowedOrigins: []) == nil)
        #expect(LocalAPI.refusal(host: "localhost:6737", origin: nil, port: 6737, allowedOrigins: []) == nil)
        #expect(LocalAPI.refusal(host: "127.0.0.1:6737", origin: "https://evil.example", port: 6737, allowedOrigins: []) == .origin)
        #expect(LocalAPI.refusal(host: "127.0.0.1:6737", origin: "http://localhost:3000", port: 6737, allowedOrigins: ["http://localhost:3000"]) == nil)
        #expect(LocalAPI.refusal(host: "notchmeter.attacker.example:6737", origin: nil, port: 6737, allowedOrigins: []) == .badHost)
        #expect(LocalAPI.refusal(host: nil, origin: nil, port: 6737, allowedOrigins: []) == .badHost)
        #expect(LocalAPI.refusal(host: "127.0.0.1:6738", origin: nil, port: 6737, allowedOrigins: []) == .badHost)
    }

    @Test func parsesHeadersAndBodies() throws {
        let get = try #require(LocalAPI.parse(Data("GET /v1/limits HTTP/1.1\r\nHost: 127.0.0.1:6737\r\nOrigin: https://x\r\n\r\n".utf8)))
        #expect(get.method == "GET")
        #expect(get.path == "/v1/limits")
        #expect(get.header("origin") == "https://x")
        #expect(get.header("Host") == "127.0.0.1:6737")
        #expect(LocalAPI.parse(Data("POST /v1/hook HTTP/1.1\r\nContent-Length: 10\r\n\r\n{\"a\"".utf8)) == nil)
        let post = try #require(LocalAPI.parse(Data("POST /v1/hook HTTP/1.1\r\nHost: localhost:6737\r\nContent-Length: 7\r\n\r\n{\"a\":1}".utf8)))
        #expect(post.body == Data("{\"a\":1}".utf8))
        #expect(LocalAPI.path(of: "POST /v1/hook HTTP/1.1\r\n") == nil)
    }

    @MainActor @Test func aRefusedRequestGetsA403AndTheReportIsServedOtherwise() {
        let api = LocalAPI(port: 6737, allowedOrigins: { ["http://ok"] }, report: { UsageReport(tools: [:], cost: nil, advice: []) })
        let refused = String(decoding: api.respond(to: LocalAPI.Request(method: "GET", path: "/v1/limits", headers: ["host": "127.0.0.1:6737", "origin": "https://evil"], body: Data())), as: UTF8.self)
        #expect(refused.hasPrefix("HTTP/1.1 403 Forbidden"))
        #expect(!refused.contains("Access-Control-Allow-Origin"))
        let badHost = String(decoding: api.respond(to: LocalAPI.Request(method: "GET", path: "/v1/limits", headers: ["host": "rebind.example:6737"], body: Data())), as: UTF8.self)
        #expect(badHost.hasPrefix("HTTP/1.1 403 Forbidden"))
        let served = String(decoding: api.respond(to: LocalAPI.Request(method: "GET", path: "/v1/limits", headers: ["host": "127.0.0.1:6737", "origin": "http://ok"], body: Data())), as: UTF8.self)
        #expect(served.hasPrefix("HTTP/1.1 200 OK"))
        #expect(served.contains("\"schema\" : \"notchmeter.limits.v1\""))
        let missing = String(decoding: api.respond(to: LocalAPI.Request(method: "GET", path: "/nope", headers: ["host": "127.0.0.1:6737"], body: Data())), as: UTF8.self)
        #expect(missing.hasPrefix("HTTP/1.1 404"))
        let method = String(decoding: api.respond(to: LocalAPI.Request(method: "DELETE", path: "/v1/limits", headers: ["host": "127.0.0.1:6737"], body: Data())), as: UTF8.self)
        #expect(method.hasPrefix("HTTP/1.1 405"))
    }

    @MainActor @Test func aRemoteHookPostedOverTheLoopbackLandsInTheSessionTracker() async throws {
        var tracker = SessionTracker()
        let port: UInt16 = 6739
        let received = OSAllocatedUnfairLockBox<Hook.Message?>(nil)
        let api = LocalAPI(port: port, hook: { received.set($0) }, report: { UsageReport(tools: [:], cost: nil, advice: []) })
        api.start()
        try await Task.sleep(for: .milliseconds(300))
        guard api.isRunning else {
            api.stop()
            return
        }
        defer { api.stop() }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/hook")!)
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"hook_event_name":"UserPromptSubmit","session_id":"r1","cwd":"/home/dev/scout","branch":"feat/remote","host":"devbox","permission_mode":"plan"}"#.utf8)
        request.setValue("127.0.0.1:\(port)", forHTTPHeaderField: "Host")
        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 202)
        #expect(String(decoding: data, as: UTF8.self).contains("accepted"))
        let message = try #require(received.get())
        #expect(message.host == "devbox")
        #expect(message.branch == "feat/remote")
        #expect(message.project == "scout")
        tracker.apply(message, now: Date())
        #expect(tracker.working.first?.id == "r1@devbox")
        #expect(tracker.working.first?.displayName == "scout@devbox")
        #expect(tracker.working.first?.permissionMode == "plan")
        #expect(SessionTracker.waitingPhrase([tracker.working.first!]) == "scout@devbox")
        var blocked = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/limits")!)
        blocked.setValue("https://evil.example", forHTTPHeaderField: "Origin")
        let (_, refused) = try await URLSession(configuration: .ephemeral).data(for: blocked)
        #expect((refused as? HTTPURLResponse)?.statusCode == 403)
    }

    @Test func theHookPayloadTakesTheBranchFromTheRemoteRatherThanTheLocalDisk() throws {
        let message = try #require(LocalAPI.hookMessage(from: Data(#"{"hook_event_name":"Stop","session_id":"s","cwd":"/x/notchmeter","branch":"main","host":"vps"}"#.utf8)))
        #expect(message.branch == "main")
        #expect(message.host == "vps")
        #expect(LocalAPI.hookMessage(from: Data("{}".utf8)) == nil)
    }
}

/// A tiny thread-safe box for the loopback test's callback.
final class OSAllocatedUnfairLockBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T

    init(_ value: T) { self.value = value }

    func set(_ new: T) {
        lock.lock()
        value = new
        lock.unlock()
    }

    func get() -> T {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
