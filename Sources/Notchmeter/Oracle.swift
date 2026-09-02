import CoreGraphics
import Foundation
import os

/// `--e2e-oracle <path>` (or NOTCHMETER_ORACLE=<path>): one JSON object per line for every observable state
/// change, so a tester that can move the real mouse but cannot see the app's windows can still check what the
/// app did. Every line carries "t" (ISO 8601, UTC) and "event"; docs/testing.md lists the events and their fields.
/// Nothing that names a place under the home directory leaves the process except into this file: every string is
/// scrubbed of that path, and readings carry window labels and fractions only, never a token or a transcript.
final class Oracle: @unchecked Sendable {
    static let shared = Oracle()
    static let snapshotNotification = Notification.Name("com.amirhackett.notchmeter.oracle.snapshot")

    private struct Sink {
        var handle: FileHandle?
        var count = 0
    }

    private let sink = OSAllocatedUnfairLock(initialState: Sink())

    var isActive: Bool { sink.withLock { $0.handle != nil } }
    var count: Int { sink.withLock { $0.count } }

    /// The launch argument wins over the environment; nil when neither names a file.
    static func path(arguments: [String] = CommandLine.arguments, environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if let index = arguments.firstIndex(of: "--e2e-oracle"), index + 1 < arguments.count { return arguments[index + 1] }
        if let path = environment["NOTCHMETER_ORACLE"], !path.isEmpty { return path }
        return nil
    }

    /// Appends to the file, creating it and its folder as needed.
    @discardableResult
    func start(path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: url) else { return false }
        _ = try? handle.seekToEnd()
        sink.withLock { $0 = Sink(handle: handle) }
        return true
    }

    func emit(_ event: String, _ fields: [String: Any] = [:]) {
        guard isActive, let line = Self.line(event: event, fields: fields) else { return }
        sink.withLock { state in
            state.handle?.write(Data((line + "\n").utf8))
            state.count += 1
        }
    }

    /// One line, keys sorted so a tester can compare lines textually. Rects become {x, y, width, height}, a nil
    /// or non-finite value becomes null, and the home directory in any string becomes "~".
    static func line(event: String, fields: [String: Any], at date: Date = Date(), home: String = Paths.home.path) -> String? {
        var object = fields.mapValues { scrub($0, home: home) }
        object["t"] = timestamp(date)
        object["event"] = event
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    static func scrub(_ value: Any, home: String) -> Any {
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            return mirror.children.first.map { scrub($0.value, home: home) } ?? NSNull()
        }
        // Numbers are matched by their exact type: through NSNumber, an Int or a Bool would cast as a Double too.
        let kind = type(of: value)
        if kind == Double.self || kind == CGFloat.self, let double = value as? Double {
            return finite(double)
        }
        switch value {
        case let string as String:
            return home.isEmpty ? string : string.replacingOccurrences(of: home, with: "~")
        case let rect as CGRect:
            return ["x": finite(rect.minX), "y": finite(rect.minY), "width": finite(rect.width), "height": finite(rect.height)]
        case let dictionary as [String: Any]:
            return dictionary.mapValues { scrub($0, home: home) }
        case let array as [Any]:
            return array.map { scrub($0, home: home) }
        default:
            return value
        }
    }

    private static func finite(_ value: Double) -> Any {
        value.isFinite ? value : NSNull()
    }

    // MARK: - Fields

    /// A reading as the oracle sees it: the status kind and, for each window, its label and fractions.
    static func fields(_ tool: ToolID, _ status: ToolStatus, now: Date = Date()) -> [String: Any] {
        var fields: [String: Any] = ["tool": tool.rawValue, "status": kind(status)]
        if let reading = status.reading {
            fields["stale"] = status.staleReading != nil
            fields["plan"] = reading.plan as Any
            fields["windows"] = reading.windows.map { window -> [String: Any] in
                ["id": window.id, "label": window.label, "used": window.usedFraction.map(fraction) as Any,
                 "resetsAt": window.resetsAt.map(timestamp) as Any,
                 "pace": Pace.status(for: window, now: now).map { String(describing: $0) } as Any]
            }
        }
        return fields
    }

    /// Four decimals as a decimal number, so 0.71 is written "0.71" rather than the binary double's 17 digits.
    static func fraction(_ value: Double) -> NSDecimalNumber {
        NSDecimalNumber(string: String(format: "%.4f", value), locale: Locale(identifier: "en_US_POSIX"))
    }

    static func kind(_ status: ToolStatus) -> String {
        switch status {
        case .notInstalled: "notInstalled"
        case .off: "off"
        case .waiting: "waiting"
        case .idle: "idle"
        case .needsAttention: "needsAttention"
        case .ready: "ready"
        case .failed: "failed"
        }
    }
}
