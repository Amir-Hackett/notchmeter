import Foundation
import Network
import os

private let log = Logger(subsystem: "com.amirhackett.notchmeter", category: "api")

/// `GET http://127.0.0.1:6737/v1/limits` (and `/v1/limits/<tool>`): the same JSON as `--probe --json`, from the
/// store's cached readings, for status-line scripts, widgets and dashboards. Loopback only, no authentication,
/// `Access-Control-Allow-Origin: *`; off by default because it widens the surface of an app whose pitch is that
/// nothing leaves the Mac.
@MainActor
final class LocalAPI {
    static let port: UInt16 = 6737
    private var listener: NWListener?
    private let report: () -> UsageReport
    private(set) var isRunning = false

    init(report: @escaping () -> UsageReport) {
        self.report = report
    }

    func start() {
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.port)!)
        parameters.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: parameters) else {
            log.error("could not listen on 127.0.0.1:\(Self.port)")
            return
        }
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready:
                    self?.isRunning = true
                    log.notice("listening on 127.0.0.1:\(Self.port)")
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

    private func serve(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, _, _ in
            Task { @MainActor in
                let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let response = self?.respond(to: request) ?? Self.response(status: 503, body: Data())
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }

    /// The path of a request line, or nil when it is not a GET.
    static func path(of request: String) -> String? {
        let line = request.split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? request
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else { return nil }
        return String(parts[1])
    }

    private func respond(to request: String) -> Data {
        guard let path = Self.path(of: request) else { return Self.response(status: 405, body: Data()) }
        let full = report()
        switch path {
        case "/v1/limits", "/v1/limits/", "/":
            return Self.response(status: 200, body: full.json)
        default:
            guard path.hasPrefix("/v1/limits/"), let tool = ToolID(rawValue: String(path.dropFirst("/v1/limits/".count))) else {
                return Self.response(status: 404, body: Data("{\"error\":\"not found\"}".utf8))
            }
            let single = UsageReport(tools: full.tools.filter { $0.key == tool }, order: [tool], cost: tool == .claude ? full.cost : nil,
                                     advice: full.advice.filter { $0.tool == tool }, drains: full.drains, sessions: tool == .claude ? full.sessions : [], now: full.now)
            return Self.response(status: 200, body: single.json)
        }
    }

    static func response(status: Int, body: Data) -> Data {
        let reason = status == 200 ? "OK" : status == 404 ? "Not Found" : status == 405 ? "Method Not Allowed" : "Service Unavailable"
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: application/json\r\nContent-Length: \(body.count)\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + body
    }
}
