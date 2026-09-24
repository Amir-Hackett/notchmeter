import Foundation

/// Kimi Code keeps its hooks in its TOML config, `config.toml` in its share folder, one `[[hooks]]` table per entry
/// with `event`, `command`, and optionally `matcher` and `timeout` (kimi-cli `hooks/config.py`, `HookDef`;
/// docs/en/customization/hooks.md, read 2026-09-24). The app carries no TOML parser and needs none for what it does
/// to this file: find the `[[hooks]]` tables, read four keys out of each, rewrite one value in place, and append new
/// tables at the end. That is done on the text, line by line, so every byte that is not Notchmeter's — comments,
/// key order, the user's own spacing — is left exactly as it was, which parsing the file and writing it back out
/// could never promise.
///
/// What the scanner cannot be sure of, it refuses rather than guesses. A file that already defines `hooks` some
/// other way (a root `hooks = [...]` array, a `[hooks]` table, a dotted `hooks.x` key) would be broken by an
/// appended `[[hooks]]`, since TOML forbids defining a key twice, and a file that ends inside an unclosed
/// multi-line string or array is not one to append to either; both read as `conflict`, and Add and Repair leave
/// the file untouched and say to paste the snippet instead (HookSettings.Failure.tomlHooksKey).
enum KimiHookFile {
    /// One `[[hooks]]` table, as far as the notch cares: the four documented keys, each nil when absent or written
    /// in a form this scanner does not read (a multi-line string, say).
    struct Table: Equatable {
        var event: String?
        var command: String?
        var matcher: String?
        var timeout: Int?
        /// Where the command's value sits in the text, quotes included, so Repair can rewrite it without touching
        /// anything else on the line. UTF-8 offsets rather than String.Index, so the ranges survive the text being
        /// copied and rebuilt.
        var commandRange: Range<Int>?
    }

    struct Scan: Equatable {
        var tables: [Table]
        /// `hooks` is already defined some other way than as an array of tables, or the text ends inside a value;
        /// either way nothing may be appended.
        var conflict: Bool
    }

    /// The comment written above the tables Notchmeter appends, so a reader of the file knows whose they are.
    static let marker = "# Notchmeter: session and turn events for the notch. Notchmeter › Settings › Hooks adds and repairs these."

    /// Reads the tables out of a TOML text. Table headers are recognised only outside multi-line strings and
    /// multi-line arrays, whose lines may begin with `[` without being headers.
    static func scan(_ text: String) -> Scan {
        var tables: [Table] = []
        var current: Int?
        var atRoot = true
        var conflict = false
        var closing: String?
        var arrayDepth = 0
        var offset = 0
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let lineStart = offset
            offset += rawLine.utf8.count + 1
            let line = rawLine.hasSuffix("\r") ? rawLine.dropLast() : rawLine
            if let delimiter = closing {
                if line.contains(delimiter) { closing = nil }
                continue
            }
            if arrayDepth > 0 {
                arrayDepth += depthChange(in: line)
                continue
            }
            let trimmed = line.drop { $0 == " " || $0 == "\t" }
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if trimmed.hasPrefix("[[") {
                atRoot = false
                let name = headerName(trimmed.dropFirst(2), closing: "]]")
                if name == "hooks" {
                    tables.append(Table())
                    current = tables.count - 1
                } else {
                    current = nil
                    if name?.hasPrefix("hooks.") == true { conflict = true }
                }
                continue
            }
            if trimmed.hasPrefix("[") {
                atRoot = false
                current = nil
                let name = headerName(trimmed.dropFirst(), closing: "]")
                if name == "hooks" || name?.hasPrefix("hooks.") == true { conflict = true }
                continue
            }
            guard let equals = trimmed.firstIndex(of: "=") else { continue }
            let key = unquoted(trimmed[..<equals].trimmingCharacters(in: .whitespaces))
            let valueText = trimmed[trimmed.index(after: equals)...].drop { $0 == " " || $0 == "\t" }
            if atRoot, key == "hooks" || key.hasPrefix("hooks.") { conflict = true }
            // A multi-line string or array opened on this line swallows the lines after it until it closes.
            for delimiter in ["\"\"\"", "'''"] where valueText.hasPrefix(delimiter) {
                if !valueText.dropFirst(3).contains(delimiter) { closing = delimiter }
            }
            if closing == nil, valueText.hasPrefix("[") { arrayDepth = max(0, depthChange(in: valueText)) }
            guard let index = current, closing == nil else { continue }
            let valueStart = lineStart + line.utf8.distance(from: line.startIndex, to: valueText.startIndex)
            switch key {
            case "event": tables[index].event = string(valueText)?.value
            case "matcher": tables[index].matcher = string(valueText)?.value
            case "command":
                if let parsed = string(valueText) {
                    tables[index].command = parsed.value
                    tables[index].commandRange = valueStart..<(valueStart + parsed.length)
                }
            case "timeout": tables[index].timeout = integer(valueText)
            default: break
            }
        }
        if closing != nil || arrayDepth > 0 { conflict = true }
        return Scan(tables: tables, conflict: conflict)
    }

    /// The hooks in the shape HookSettings' status and merge rules read: `{"hooks": {event: [{command, timeout}]}}`,
    /// one flat element per table that names both an event and a command.
    static func settings(from scan: Scan) -> [String: Any] {
        var hooks: [String: [[String: Any]]] = [:]
        for table in scan.tables {
            guard let event = table.event, let command = table.command else { continue }
            var element: [String: Any] = ["command": command]
            if let timeout = table.timeout { element["timeout"] = timeout }
            if let matcher = table.matcher { element["matcher"] = matcher }
            hooks[event, default: []].append(element)
        }
        return ["hooks": hooks]
    }

    /// One table as Notchmeter writes it: the event, then the handler's command and timeout.
    static func table(event: String, handler: [String: Any]) -> String {
        var lines = ["[[hooks]]", "event = \(basicString(event))"]
        if let command = handler["command"] as? String { lines.append("command = \(basicString(command))") }
        if let timeout = (handler["timeout"] as? NSNumber)?.intValue { lines.append("timeout = \(timeout)") }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The text with `tables` appended after a blank line and the marker comment; the text as it was when there is
    /// nothing to append.
    static func appending(_ tables: [String], to text: String) -> String {
        guard !tables.isEmpty else { return text }
        var result = text
        if !result.isEmpty {
            if !result.hasSuffix("\n") { result += "\n" }
            result += "\n"
        }
        return result + marker + "\n" + tables.joined(separator: "\n")
    }

    /// The text with each range (UTF-8 offsets) replaced by its string. Ranges must not overlap.
    static func replacing(_ replacements: [(range: Range<Int>, with: String)], in text: String) -> String {
        guard !replacements.isEmpty else { return text }
        let bytes = Array(text.utf8)
        var result: [UInt8] = []
        var cursor = 0
        for replacement in replacements.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
            guard replacement.range.lowerBound >= cursor, replacement.range.upperBound <= bytes.count else { continue }
            result.append(contentsOf: bytes[cursor..<replacement.range.lowerBound])
            result.append(contentsOf: Array(replacement.with.utf8))
            cursor = replacement.range.upperBound
        }
        result.append(contentsOf: bytes[cursor...])
        return String(decoding: result, as: UTF8.self)
    }

    /// A TOML basic string: backslash and quote escaped, control characters as `\uXXXX` or their short escapes.
    static func basicString(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            case _ where scalar.value < 0x20 || scalar.value == 0x7F: out += String(format: "\\u%04X", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    /// The file's text: empty when there is no file, which is where Add starts from.
    static func read(at url: URL) throws -> String {
        guard FileManager.default.fileExists(atPath: url.path) else { return "" }
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Scanning helpers

    /// The name inside a table header, `[name]` or `[[name]]`, whitespace and a trailing comment ignored; nil for
    /// a header that does not close.
    private static func headerName(_ rest: Substring, closing: String) -> String? {
        guard let end = rest.range(of: closing) else { return nil }
        let name = rest[..<end.lowerBound].trimmingCharacters(in: .whitespaces)
        return name.split(separator: ".").map { unquoted($0.trimmingCharacters(in: .whitespaces)) }.joined(separator: ".")
    }

    /// A bare key, or a quoted one without its quotes.
    private static func unquoted(_ key: String) -> String {
        if key.count >= 2, let first = key.first, first == key.last, first == "\"" || first == "'" {
            return String(key.dropFirst().dropLast())
        }
        return key
    }

    /// How much a line opens (+) or closes (-) array brackets, outside strings and before a comment.
    private static func depthChange(in line: Substring) -> Int {
        var depth = 0
        var quote: Character?
        var escaped = false
        for character in line {
            if let open = quote {
                if escaped { escaped = false } else if character == "\\" && open == "\"" { escaped = true } else if character == open { quote = nil }
                continue
            }
            switch character {
            case "\"", "'": quote = character
            case "#": return depth
            case "[": depth += 1
            case "]": depth -= 1
            default: break
            }
        }
        return depth
    }

    /// A single-line basic (`"…"`, escapes read) or literal (`'…'`) string at the start of `text`, with its length
    /// in UTF-8 bytes, quotes included; nil for anything else, a multi-line string among them.
    static func string(_ text: Substring) -> (value: String, length: Int)? {
        guard let quote = text.first, quote == "\"" || quote == "'", !text.hasPrefix("\"\"\""), !text.hasPrefix("'''") else { return nil }
        var value = ""
        var scalars = text.unicodeScalars.dropFirst().makeIterator()
        var length = 1
        while let scalar = scalars.next() {
            length += String(scalar).utf8.count
            if quote == "'" {
                if scalar == "'" { return (value, length) }
                value.unicodeScalars.append(scalar)
                continue
            }
            switch scalar {
            case "\"": return (value, length)
            case "\\":
                guard let escape = scalars.next() else { return nil }
                length += String(escape).utf8.count
                switch escape {
                case "\\": value += "\\"
                case "\"": value += "\""
                case "n": value += "\n"
                case "t": value += "\t"
                case "r": value += "\r"
                case "b": value += "\u{08}"
                case "f": value += "\u{0C}"
                case "e": value += "\u{1B}"
                case "u", "U":
                    var hex = ""
                    for _ in 0..<(escape == "u" ? 4 : 8) {
                        guard let digit = scalars.next() else { return nil }
                        hex.unicodeScalars.append(digit)
                        length += 1
                    }
                    guard let code = UInt32(hex, radix: 16), let decoded = Unicode.Scalar(code) else { return nil }
                    value.unicodeScalars.append(decoded)
                default: return nil
                }
            default:
                value.unicodeScalars.append(scalar)
            }
        }
        return nil
    }

    /// A TOML decimal integer at the start of `text` (underscores allowed between digits, a sign allowed), up to
    /// whitespace or a comment.
    private static func integer(_ text: Substring) -> Int? {
        let token = text.prefix { $0 != " " && $0 != "\t" && $0 != "#" }
        return Int(token.replacingOccurrences(of: "_", with: ""))
    }
}
