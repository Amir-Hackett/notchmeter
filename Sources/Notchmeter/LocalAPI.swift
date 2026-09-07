import Foundation
import Network
import os

private let log = Logger(subsystem: "com.amirhackett.notchmeter", category: "api")

/// `GET http://127.0.0.1:6737/v1/limits` (and `/v1/limits/<tool>`): the same JSON as `--probe --json`, from the
/// store's cached readings, for status-line scripts, widgets and the command-line tool; `POST /v1/hook` takes the
/// same fields the Claude Code hook keeps (plus a `host` label), so a remote machine's hook reaches the notch over
/// an SSH tunnel. Loopback only, no authentication, and no web page may read it: a request carrying an `Origin`
/// header is refused unless that origin is in the Settings allow-list, and `Host` must be the loopback address, so a
/// DNS-rebinding host cannot reach it either. Off by default because it widens the surface of an app whose pitch
/// is that nothing leaves the Mac.
@MainActor
final class LocalAPI {
    nonisolated static let port: UInt16 = 6737
    nonisolated static let maximumBody = 64 * 1024

    struct Request: Equatable {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data

        func header(_ name: String) -> String? { headers[name.lowercased()] }
    }

    /// A parsed HTTP/1.1 request, or nil while the head (or the body its Content-Length promises) is incomplete.
    nonisolated static func parse(_ data: Data) -> Request? {
        guard let headEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[data.startIndex..<headEnd.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = headers["content-length"].flatMap(Int.init) ?? 0
        let body = data[headEnd.upperBound...]
        guard body.count >= length, length <= maximumBody else { return body.count > maximumBody ? Request(method: String(requestLine[0]), path: String(requestLine[1]), headers: headers, body: Data()) : nil }
        return Request(method: String(requestLine[0]), path: String(requestLine[1]), headers: headers, body: Data(body.prefix(length)))
    }

    /// The path of a request line, or nil when it is not a GET (kept for the tests and the status-line client).
    nonisolated static func path(of request: String) -> String? {
        guard let parsed = parse(Data(request.utf8) + Data("\r\n\r\n".utf8)), parsed.method == "GET" else { return nil }
        return parsed.path
    }

    enum Refusal: Equatable {
        case badHost, origin, unauthorized
    }

    /// Why a request must not be answered.
    ///
    /// Over loopback the rule is unchanged and needs no credential: the Host must be the loopback address, so a
    /// DNS-rebinding page cannot reach the port, and an Origin must be in the allow-list.
    ///
    /// A request that arrived over the network is held to more. It must carry `Authorization: Bearer <token>`
    /// matching the stored token, compared in constant time; with remote access off — `token` nil — it is refused
    /// whatever it carries, so a listener left bound by a crash still answers nothing. Its Host must be an address
    /// literal rather than a name, which keeps the rebinding protection that the loopback rule gets for free: an
    /// attacker's page can point a hostname at this Mac, but the browser then sends that hostname in Host.
    nonisolated static func refusal(host: String?, origin: String?, port: UInt16, allowedOrigins: [String],
                                    fromLoopback: Bool = true, authorization: String? = nil, token: String? = nil) -> Refusal? {
        let host = host?.trimmingCharacters(in: .whitespaces).lowercased()
        if fromLoopback {
            let hosts: Set<String> = ["127.0.0.1:\(port)", "localhost:\(port)", "127.0.0.1", "localhost", "[::1]:\(port)"]
            guard let host, hosts.contains(host) else { return .badHost }
        } else {
            guard let token, let bearer = RemoteAccess.bearer(in: authorization), RemoteAccess.matches(bearer, token: token) else {
                return .unauthorized
            }
            guard let host, isAddressLiteral(host, port: port) else { return .badHost }
        }
        if let origin = origin?.trimmingCharacters(in: .whitespaces), !origin.isEmpty, !allowedOrigins.contains(where: { $0.caseInsensitiveCompare(origin) == .orderedSame }) {
            return .origin
        }
        return nil
    }

    /// Whether a Host header names an address rather than a name: dotted-quad IPv4, or a bracketed IPv6 literal,
    /// each with or without this listener's port. A name — however it resolves — is not one.
    nonisolated static func isAddressLiteral(_ host: String, port: UInt16) -> Bool {
        var value = host
        if value.hasSuffix(":\(port)") { value = String(value.dropLast(":\(port)".count)) }
        if value.hasPrefix("["), value.hasSuffix("]") {
            let inner = String(value.dropFirst().dropLast())
            return !inner.isEmpty && inner.allSatisfy { $0.isHexDigit || $0 == ":" || $0 == "." } && inner.contains(":")
        }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.count <= 3 && part.allSatisfy(\.isNumber) && (UInt8(part) != nil)
        }
    }

    private var listener: NWListener?
    private let report: () -> UsageReport
    private let hook: (Hook.Message) -> Void
    private let allowedOrigins: () -> [String]
    /// The remote-access token, read afresh per request so rotating it takes effect without a restart; nil keeps the
    /// listener loopback-only and refuses everything that arrives from the network.
    private let remoteToken: () -> String?
    let port: UInt16
    private(set) var isRunning = false
    /// Whether the listener is bound beyond loopback, for the Settings row and the diagnostics line.
    private(set) var isRemote = false

    init(port: UInt16 = LocalAPI.port, allowedOrigins: @escaping () -> [String] = { [] }, remoteToken: @escaping () -> String? = { nil },
         hook: @escaping (Hook.Message) -> Void = { _ in }, report: @escaping () -> UsageReport) {
        self.port = port
        self.allowedOrigins = allowedOrigins
        self.remoteToken = remoteToken
        self.hook = hook
        self.report = report
    }

    func start() {
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        // Binding beyond loopback is what the token buys. Without one the socket stays where it has always been, so
        // a failed or refused Keychain write can only ever make remote access not happen, never happen unguarded.
        let remote = remoteToken() != nil
        if !remote {
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        }
        isRemote = remote
        let made: NWListener?
        if remote {
            made = try? NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        } else {
            made = try? NWListener(using: parameters)
        }
        guard let listener = made else {
            log.error("could not listen on \(remote ? "0.0.0.0" : "127.0.0.1"):\(self.port)")
            return
        }
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready:
                    self?.isRunning = true
                    log.notice("listening on \(self?.isRemote == true ? "0.0.0.0" : "127.0.0.1"):\(self?.port ?? 0)")
                case .failed(let error):
                    self?.isRunning = false
                    log.error("listener failed: \(error.localizedDescription, privacy: .public)")
                case .cancelled:
                    self?.isRunning = false
                default:
                    break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.serve(connection) }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
        isRemote = false
    }

    private func serve(_ connection: NWConnection, buffered: Data = Data()) {
        if buffered.isEmpty { connection.start(queue: .main) }
        let fromLoopback = Self.isLoopback(connection.endpoint)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, complete, _ in
            Task { @MainActor in
                guard let self else { return }
                let received = buffered + (data ?? Data())
                if let request = Self.parse(received) {
                    let response = self.respond(to: request, fromLoopback: fromLoopback)
                    connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
                } else if complete || received.count > Self.maximumBody * 2 {
                    connection.send(content: Self.response(status: 400, body: Data()), completion: .contentProcessed { _ in connection.cancel() })
                } else {
                    self.serve(connection, buffered: received)
                }
            }
        }
    }

    /// Whether a peer is on this Mac. An inbound connection's endpoint is the far end, so a loopback address there
    /// means the request never touched the network and is held to the original, credential-free rule.
    nonisolated static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        if case .ipv4(let address) = host { return address.isLoopback }
        if case .ipv6(let address) = host { return address.isLoopback || (address.asIPv4?.isLoopback ?? false) }
        if case .name(let name, _) = host { return name.lowercased() == "localhost" }
        return false
    }

    func respond(to request: Request, fromLoopback: Bool = true) -> Data {
        if let refusal = Self.refusal(host: request.header("host"), origin: request.header("origin"), port: port,
                                      allowedOrigins: allowedOrigins(), fromLoopback: fromLoopback,
                                      authorization: request.header("authorization"), token: remoteToken()) {
            log.notice("refused a request: \(String(describing: refusal), privacy: .public)")
            if refusal == .unauthorized {
                return Self.response(status: 401, body: Data("{\"error\":\"unauthorized\"}".utf8),
                                     extraHeaders: ["WWW-Authenticate": "Bearer realm=\"notchmeter\""])
            }
            return Self.response(status: 403, body: Data("{\"error\":\"\(refusal == .origin ? "origin not allowed" : "host not allowed")\"}".utf8))
        }
        switch (request.method, request.path) {
        case ("GET", "/v1/limits"), ("GET", "/v1/limits/"), ("GET", "/"):
            return Self.response(status: 200, body: report().json)
        case ("POST", "/v1/hook"):
            guard let message = Self.hookMessage(from: request.body) else {
                return Self.response(status: 400, body: Data("{\"error\":\"hook_event_name missing\"}".utf8))
            }
            hook(message)
            return Self.response(status: 202, body: Data("{\"accepted\":true}".utf8))
        case ("GET", let path) where path.hasPrefix("/v1/limits/"):
            guard let tool = ToolID(rawValue: String(path.dropFirst("/v1/limits/".count))) else {
                return Self.response(status: 404, body: Data("{\"error\":\"not found\"}".utf8))
            }
            return Self.response(status: 200, body: report().limited(to: tool).json)
        case ("GET", _):
            return Self.response(status: 404, body: Data("{\"error\":\"not found\"}".utf8))
        default:
            return Self.response(status: 405, body: Data())
        }
    }

    /// The hook payload a remote machine posts: Claude Code's or Cursor's own event JSON (as `--hook` reads it) plus
    /// `host`; the branch is taken from the payload since the checkout is not on this Mac. `Hook.message(from:)`
    /// tags a Cursor payload by its shape, or by a `"tool": "cursor"` key, so the session is keyed
    /// `cursor:<conversation_id>@<host>` and lights the Cursor ring.
    nonisolated static func hookMessage(from body: Data) -> Hook.Message? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        guard let base = Hook.message(from: body, branch: { _ in (object["branch"] as? String).flatMap { $0.isEmpty ? nil : $0 } }) else { return nil }
        let host = (object["host"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return Hook.Message(event: base.event, needsInput: base.needsInput, sessionID: base.sessionID, project: base.project,
                            notificationType: base.notificationType, branch: base.branch, permissionMode: base.permissionMode,
                            agentID: base.agentID, failure: base.failure, host: host, tool: base.tool)
    }

    nonisolated static func response(status: Int, body: Data, extraHeaders: [String: String] = [:]) -> Data {
        let reason = switch status {
        case 200: "OK"
        case 202: "Accepted"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        default: "Service Unavailable"
        }
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        for key in extraHeaders.keys.sorted() { head += "\(key): \(extraHeaders[key]!)\r\n" }
        head += "Content-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + body
    }
}
