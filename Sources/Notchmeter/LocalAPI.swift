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
        case badHost, origin
    }

    /// Why a request must not be answered: a Host that is not the loopback address, or an Origin not allowed.
    nonisolated static func refusal(host: String?, origin: String?, port: UInt16, allowedOrigins: [String]) -> Refusal? {
        let hosts: Set<String> = ["127.0.0.1:\(port)", "localhost:\(port)", "127.0.0.1", "localhost", "[::1]:\(port)"]
        guard let host = host?.trimmingCharacters(in: .whitespaces).lowercased(), hosts.contains(host) else { return .badHost }
        if let origin = origin?.trimmingCharacters(in: .whitespaces), !origin.isEmpty, !allowedOrigins.contains(where: { $0.caseInsensitiveCompare(origin) == .orderedSame }) {
            return .origin
        }
        return nil
    }

    private var listener: NWListener?
    private let report: () -> UsageReport
    private let hook: (Hook.Message) -> Void
    private let allowedOrigins: () -> [String]
    let port: UInt16
    private(set) var isRunning = false

    init(port: UInt16 = LocalAPI.port, allowedOrigins: @escaping () -> [String] = { [] }, hook: @escaping (Hook.Message) -> Void = { _ in },
         report: @escaping () -> UsageReport) {
        self.port = port
        self.allowedOrigins = allowedOrigins
        self.hook = hook
        self.report = report
    }

    func start() {
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        parameters.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: parameters) else {
            log.error("could not listen on 127.0.0.1:\(self.port)")
            return
        }
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready:
                    self?.isRunning = true
                    log.notice("listening on 127.0.0.1:\(self?.port ?? 0)")
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
    }

    private func serve(_ connection: NWConnection, buffered: Data = Data()) {
        if buffered.isEmpty { connection.start(queue: .main) }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, complete, _ in
            Task { @MainActor in
                guard let self else { return }
                let received = buffered + (data ?? Data())
                if let request = Self.parse(received) {
                    let response = self.respond(to: request)
                    connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
                } else if complete || received.count > Self.maximumBody * 2 {
                    connection.send(content: Self.response(status: 400, body: Data()), completion: .contentProcessed { _ in connection.cancel() })
                } else {
                    self.serve(connection, buffered: received)
                }
            }
        }
    }

    func respond(to request: Request) -> Data {
        if let refusal = Self.refusal(host: request.header("host"), origin: request.header("origin"), port: port, allowedOrigins: allowedOrigins()) {
            log.notice("refused a request: \(String(describing: refusal), privacy: .public)")
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

    /// The hook payload a remote machine posts: Claude Code's own event JSON (as `--hook` reads it) plus `host`; the
    /// branch is taken from the payload since the checkout is not on this Mac.
    nonisolated static func hookMessage(from body: Data) -> Hook.Message? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        guard let base = Hook.message(from: body, branch: { _ in (object["branch"] as? String).flatMap { $0.isEmpty ? nil : $0 } }) else { return nil }
        let host = (object["host"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return Hook.Message(event: base.event, needsInput: base.needsInput, sessionID: base.sessionID, project: base.project,
                            notificationType: base.notificationType, branch: base.branch, permissionMode: base.permissionMode,
                            agentID: base.agentID, failure: base.failure, host: host)
    }

    nonisolated static func response(status: Int, body: Data) -> Data {
        let reason = switch status {
        case 200: "OK"
        case 202: "Accepted"
        case 400: "Bad Request"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        default: "Service Unavailable"
        }
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + body
    }
}
