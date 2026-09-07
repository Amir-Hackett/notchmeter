import Foundation
import Testing
@testable import Notchmeter

/// Reaching the API from the network: the token itself, the bearer header, and the rule that a request which did not
/// arrive over loopback needs both a matching token and a Host that is an address rather than a name.
@Suite(.serialized) struct RemoteAccessRules {
    init() { Localization.use(language: "en") }

    @Test func tokensAreLongRandomAndURLSafe() {
        let a = RemoteAccess.newToken(), b = RemoteAccess.newToken()
        #expect(a != b)
        #expect(a.count >= 43)
        #expect(a.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
    }

    @Test func matchesIsExactAndSurvivesTheWrongLength() {
        let token = RemoteAccess.newToken()
        #expect(RemoteAccess.matches(token, token: token))
        #expect(!RemoteAccess.matches(String(token.dropLast()), token: token))
        #expect(!RemoteAccess.matches(token + "x", token: token))
        #expect(!RemoteAccess.matches("", token: token))
        #expect(!RemoteAccess.matches(token, token: ""))
    }

    @Test func readsOnlyABearerHeader() {
        #expect(RemoteAccess.bearer(in: "Bearer abc") == "abc")
        #expect(RemoteAccess.bearer(in: "bearer abc") == "abc")
        #expect(RemoteAccess.bearer(in: "  Bearer   abc  ") == "abc")
        #expect(RemoteAccess.bearer(in: "Basic abc") == nil)
        #expect(RemoteAccess.bearer(in: "Bearer ") == nil)
        #expect(RemoteAccess.bearer(in: "abc") == nil)
        #expect(RemoteAccess.bearer(in: nil) == nil)
    }

    @Test func onlyAddressLiteralsPassAsAHost() {
        #expect(LocalAPI.isAddressLiteral("192.168.1.20:6737", port: 6737))
        #expect(LocalAPI.isAddressLiteral("192.168.1.20", port: 6737))
        #expect(LocalAPI.isAddressLiteral("100.72.3.9:6737", port: 6737))
        #expect(LocalAPI.isAddressLiteral("[fd7a::1]:6737", port: 6737))
        // A name is never one, however it resolves — this is the DNS-rebinding guard.
        #expect(!LocalAPI.isAddressLiteral("notchmeter.attacker.example:6737", port: 6737))
        #expect(!LocalAPI.isAddressLiteral("my-mac.local:6737", port: 6737))
        #expect(!LocalAPI.isAddressLiteral("999.1.1.1", port: 6737))
        #expect(!LocalAPI.isAddressLiteral("192.168.1", port: 6737))
        #expect(!LocalAPI.isAddressLiteral("", port: 6737))
    }

    @Test func aNetworkRequestNeedsTheTokenAndTheLoopbackRuleIsUnchanged() {
        let token = RemoteAccess.newToken()
        // Over loopback: exactly as before, no credential, and a token being set changes nothing.
        #expect(LocalAPI.refusal(host: "127.0.0.1:6737", origin: nil, port: 6737, allowedOrigins: [],
                                 fromLoopback: true, authorization: nil, token: token) == nil)
        // From the network: the right token passes.
        #expect(LocalAPI.refusal(host: "192.168.1.20:6737", origin: nil, port: 6737, allowedOrigins: [],
                                 fromLoopback: false, authorization: "Bearer \(token)", token: token) == nil)
        // Wrong, missing, or malformed credentials do not.
        #expect(LocalAPI.refusal(host: "192.168.1.20:6737", origin: nil, port: 6737, allowedOrigins: [],
                                 fromLoopback: false, authorization: "Bearer \(RemoteAccess.newToken())", token: token) == .unauthorized)
        #expect(LocalAPI.refusal(host: "192.168.1.20:6737", origin: nil, port: 6737, allowedOrigins: [],
                                 fromLoopback: false, authorization: nil, token: token) == .unauthorized)
        #expect(LocalAPI.refusal(host: "192.168.1.20:6737", origin: nil, port: 6737, allowedOrigins: [],
                                 fromLoopback: false, authorization: "Basic \(token)", token: token) == .unauthorized)
        // Remote access off: no token stored, so nothing from the network is answered even with a guess.
        #expect(LocalAPI.refusal(host: "192.168.1.20:6737", origin: nil, port: 6737, allowedOrigins: [],
                                 fromLoopback: false, authorization: "Bearer \(token)", token: nil) == .unauthorized)
        // A good token still cannot rescue a rebinding Host, and the Origin allow-list still applies.
        #expect(LocalAPI.refusal(host: "notchmeter.attacker.example:6737", origin: nil, port: 6737, allowedOrigins: [],
                                 fromLoopback: false, authorization: "Bearer \(token)", token: token) == .badHost)
        #expect(LocalAPI.refusal(host: "192.168.1.20:6737", origin: "https://evil.example", port: 6737, allowedOrigins: [],
                                 fromLoopback: false, authorization: "Bearer \(token)", token: token) == .origin)
    }

    @MainActor @Test func theServedResponsesSayWhichRefusalItWas() {
        let token = RemoteAccess.newToken()
        let api = LocalAPI(port: 6737, remoteToken: { token }, report: { UsageReport(tools: [:], cost: nil, advice: []) })
        let denied = String(decoding: api.respond(to: LocalAPI.Request(method: "GET", path: "/v1/limits", headers: ["host": "192.168.1.20:6737"], body: Data()), fromLoopback: false), as: UTF8.self)
        #expect(denied.hasPrefix("HTTP/1.1 401 Unauthorized"))
        #expect(denied.contains("WWW-Authenticate: Bearer"))
        #expect(!denied.contains(token))

        let allowed = String(decoding: api.respond(to: LocalAPI.Request(method: "GET", path: "/v1/limits", headers: ["host": "192.168.1.20:6737", "authorization": "Bearer \(token)"], body: Data()), fromLoopback: false), as: UTF8.self)
        #expect(allowed.hasPrefix("HTTP/1.1 200 OK"))
        #expect(allowed.contains("\"schema\" : \"notchmeter.limits.v1\""))

        // The same listener with no token stored answers nothing from the network, and everything on loopback.
        let closed = LocalAPI(port: 6737, remoteToken: { nil }, report: { UsageReport(tools: [:], cost: nil, advice: []) })
        let refused = String(decoding: closed.respond(to: LocalAPI.Request(method: "GET", path: "/v1/limits", headers: ["host": "192.168.1.20:6737", "authorization": "Bearer \(token)"], body: Data()), fromLoopback: false), as: UTF8.self)
        #expect(refused.hasPrefix("HTTP/1.1 401"))
        let local = String(decoding: closed.respond(to: LocalAPI.Request(method: "GET", path: "/v1/limits", headers: ["host": "127.0.0.1:6737"], body: Data())), as: UTF8.self)
        #expect(local.hasPrefix("HTTP/1.1 200 OK"))
    }

    @Test func theAddressListSkipsLoopbackAndLinkLocal() {
        for address in RemoteAccess.lanAddresses() {
            #expect(!address.hasPrefix("127."))
            #expect(!address.hasPrefix("169.254."))
        }
        #expect(RemoteAccess.lanAddresses() == RemoteAccess.lanAddresses().sorted())
    }
}
