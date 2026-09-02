import CoreGraphics
import Foundation
import Testing
@testable import Notchmeter

/// Every oracle line is one JSON object with sorted keys, a UTC timestamp and the event name; rects, nils and the
/// home directory come out in a form a tester can rely on.
@Suite struct OracleLines {
    let at = DateParsing.iso8601("2026-09-01T12:34:56.789Z")!

    @Test func oneSortedObjectPerLine() throws {
        let line = try #require(Oracle.line(event: "panel", fields: ["state": "expanded", "cause": "dwell"], at: at, home: "/Users/test"))
        #expect(line == #"{"cause":"dwell","event":"panel","state":"expanded","t":"2026-09-01T12:34:56.789Z"}"#)
        #expect(!line.contains("\n"))
        #expect(try #require(Oracle.line(event: "launched", fields: [:], at: at, home: "")) == #"{"event":"launched","t":"2026-09-01T12:34:56.789Z"}"#)
    }

    @Test func rectsNilsNumbersAndTheHomeDirectory() throws {
        let fields: [String: Any] = [
            "compact": CGRect(x: 1, y: 2.5, width: 3, height: 4),
            "expanded": CGRect.null,
            "used": Optional<Double>.none as Any,
            "plan": Optional("Max 5x") as Any,
            "path": "/Users/test/.claude/projects/x.jsonl",
            "nested": ["inner": "/Users/test/Library", "list": [1, "/Users/test"]],
            "flag": true,
            "count": 7,
            "fraction": 0.25,
        ]
        let line = try #require(Oracle.line(event: "snapshot", fields: fields, at: at, home: "/Users/test"))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        #expect(object["compact"] as? [String: Double] == ["x": 1, "y": 2.5, "width": 3, "height": 4])
        let expanded = try #require(object["expanded"] as? [String: Any])
        #expect(expanded["x"] is NSNull)
        #expect(expanded["width"] as? Double == 0)
        #expect(object["used"] is NSNull)
        #expect(object["plan"] as? String == "Max 5x")
        #expect(object["path"] as? String == "~/.claude/projects/x.jsonl")
        let nested = try #require(object["nested"] as? [String: Any])
        #expect(nested["inner"] as? String == "~/Library")
        #expect((nested["list"] as? [Any])?[1] as? String == "~")
        #expect(object["flag"] as? Bool == true)
        #expect(object["count"] as? Int == 7)
        #expect(object["fraction"] as? Double == 0.25)
        #expect(!line.contains("/Users/test"))
        #expect(line.contains(#""flag":true"#))
    }

    @Test func readingsCarryLabelsAndFractionsOnly() throws {
        let now = at
        let window = LimitWindow(id: "five_hour", label: "Session", usedFraction: 0.71, resetsAt: now.addingTimeInterval(4 * 3600), periodDuration: Period.fiveHours)
        let reading = UsageReading(tool: .claude, windows: [window], plan: "Max 5x", fetchedAt: now, observedAt: nil)
        let ready = Oracle.fields(.claude, .ready(reading), now: now)
        #expect(ready["tool"] as? String == "claude")
        #expect(ready["status"] as? String == "ready")
        #expect(ready["stale"] as? Bool == false)
        let windows = try #require(ready["windows"] as? [[String: Any]])
        #expect(windows.count == 1)
        #expect(windows[0]["label"] as? String == "Session")
        #expect((windows[0]["used"] as? NSNumber)?.doubleValue == 0.71)
        #expect(windows[0]["pace"] as? String == "behind")
        #expect(Set(windows[0].keys) == ["id", "label", "used", "resetsAt", "pace"])
        let readyLine = try #require(Oracle.line(event: "reading", fields: ready, at: at, home: ""))
        #expect(readyLine.contains(#""used":0.71}"#))
        #expect(Oracle.fraction(1.0 / 3).description == "0.3333")

        let failed = Oracle.fields(.codex, .failed("token abc123 rejected", cached: reading), now: now)
        #expect(failed["status"] as? String == "failed")
        #expect(failed["stale"] as? Bool == true)
        let line = try #require(Oracle.line(event: "reading", fields: failed, at: at, home: ""))
        #expect(!line.contains("abc123"))
        #expect(Oracle.kind(.notInstalled) == "notInstalled")
        #expect(Oracle.fields(.cursor, .off, now: now).keys.sorted() == ["status", "tool"])
    }

    @Test func pathComesFromTheArgumentsThenTheEnvironment() {
        #expect(Oracle.path(arguments: ["Notchmeter", "--e2e-oracle", "/tmp/x.jsonl"], environment: ["NOTCHMETER_ORACLE": "/tmp/y.jsonl"]) == "/tmp/x.jsonl")
        #expect(Oracle.path(arguments: ["Notchmeter"], environment: ["NOTCHMETER_ORACLE": "/tmp/y.jsonl"]) == "/tmp/y.jsonl")
        #expect(Oracle.path(arguments: ["Notchmeter", "--e2e-oracle"], environment: [:]) == nil)
        #expect(Oracle.path(arguments: ["Notchmeter"], environment: ["NOTCHMETER_ORACLE": ""]) == nil)
    }
}
