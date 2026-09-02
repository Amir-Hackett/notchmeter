import Foundation
import Testing
@testable import Notchmeter

/// Every shipped language carries the same keys with the same format specifiers, no key is empty, and the tables
/// hold exactly the keys the code asks for: a key without an entry would read as English in every language, and
/// an entry without a caller would be dead copy nobody could ever proofread.
@Suite struct LocalizationTables {
    static let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/Notchmeter")

    func table(_ language: String) throws -> [String: String] {
        try #require(Localization.table(language: language), "no table for \(language)")
    }

    /// The `%` conversions of a format string, positional ones sorted by position, `%%` left out.
    static func specifiers(_ format: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: #"%(?:(\d+)\$)?(ld|@)"#)
        var positional: [(Int, String)] = []
        var ordered: [String] = []
        for match in pattern.matches(in: format, range: NSRange(format.startIndex..., in: format)) {
            let kind = String(format[Range(match.range(at: 2), in: format)!])
            if let range = Range(match.range(at: 1), in: format), let position = Int(format[range]) {
                positional.append((position, kind))
            } else {
                ordered.append(kind)
            }
        }
        return ordered + positional.sorted { $0.0 < $1.0 }.map { "\($0.0)$\($0.1)" }
    }

    /// The literal key of every lookup under Sources/Notchmeter: an `L("…")` call, and the `WindowLabel` cases
    /// that carry a key for a lookup made later, when the window's name is read.
    static func keysInSources() throws -> Set<String> {
        let pattern = try NSRegularExpression(pattern: #"(?:\bL\(|\.key\(|\.filled\()"((?:[^"\\]|\\.)*)""#)
        var keys: Set<String> = []
        let files = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(files.count > 20)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let raw = String(text[Range(match.range(at: 1), in: text)!])
                keys.insert(raw.replacingOccurrences(of: #"\""#, with: "\"").replacingOccurrences(of: #"\\"#, with: #"\"#))
            }
        }
        return keys
    }

    @Test func everyLanguageHasTheSameKeysAndSpecifiers() throws {
        let english = try table("en")
        #expect(english.count > 150)
        for language in Localization.languages.dropFirst() {
            let other = try table(language)
            #expect(Set(other.keys) == Set(english.keys), "\(language) keys differ from en")
            for (key, value) in other {
                #expect(!value.isEmpty, "\(language) leaves \(key) empty")
                #expect(Self.specifiers(value) == Self.specifiers(key), "\(language) changes the arguments of \(key)")
            }
        }
    }

    @Test func englishReadsAsItsKeys() throws {
        for (key, value) in try table("en") {
            #expect(value == key, "en entry for \(key) differs from its key")
            #expect(!key.isEmpty)
        }
    }

    @Test func tablesHoldExactlyTheKeysTheCodeUses() throws {
        let used = try Self.keysInSources()
        let shipped = Set(try table("en").keys)
        #expect(used.subtracting(shipped).isEmpty, "keys used but not shipped: \(used.subtracting(shipped).sorted())")
        #expect(shipped.subtracting(used).isEmpty, "keys shipped but never used: \(shipped.subtracting(used).sorted())")
    }

    @Test func specifiersAreComparedByPositionAndKind() {
        #expect(Self.specifiers("~%ld%% left") == ["ld"])
        #expect(Self.specifiers("%2$@ then %1$ld") == ["1$ld", "2$@"])
        #expect(Self.specifiers("plain") == [])
    }

    @Test func chineseTableSpeaksChinese() throws {
        let chinese = try table("zh-Hans")
        #expect(chinese["Session"] == "会话")
        #expect(chinese["Weekly"] == "每周")
        #expect(chinese["Settings…"] == "设置…")
        #expect(chinese["Open at login"] == "登录时打开")
        #expect(String(format: chinese["Resets in %@"]!, "4 天 17 小时") == "4 天 17 小时后重置")
        #expect(Localization.canonical("zh-hans") == "zh-Hans")
        #expect(Localization.canonical("fr") == nil)
    }

    @Test func aMissingKeyReadsAsItself() {
        #expect(L("not a key in any table") == "not a key in any table")
    }

    /// Six languages ship, all left-to-right. The compact strip beside the notch is pinned to left-to-right in code
    /// (NotchCompactView, EdgeCompactView) because it refers to the physical notch, so a right-to-left language
    /// (Arabic, Hebrew) can be added without the strip mirroring away from its hover geometry; the rest of the
    /// panel is free to mirror.
    @Test func everyShippedLanguageSpeaksForItself() throws {
        #expect(Localization.languages == ["en", "zh-Hans", "zh-Hant", "ja", "ko", "vi"])
        #expect(try table("zh-Hant")["Session"] == "工作階段")
        #expect(try table("ja")["Session"] == "セッション")
        #expect(try table("ko")["Session"] == "세션")
        #expect(try table("vi")["Session"] == "Phiên")
        for language in Localization.languages {
            let plist = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("scripts/Info.plist"), encoding: .utf8)
            #expect(plist.contains("<string>\(language)</string>"), "CFBundleLocalizations lacks \(language)")
        }
    }
}


/// The in-app language picker's mechanism.
@Suite struct LanguagePicker {
    @Test func aShippedCodeIsWrittenAsAppleLanguagesAndReadBack() {
        let suite = "NotchmeterTests.LanguagePicker"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        Localization.applyPreferred(language: "ja", defaults: defaults)
        #expect(defaults.persistentDomain(forName: suite)?["AppleLanguages"] as? [String] == ["ja"])
        #expect(Localization.preferred(domain: defaults.persistentDomain(forName: suite)) == "ja")
        Localization.applyPreferred(language: "ZH-HANS", defaults: defaults)
        #expect(defaults.persistentDomain(forName: suite)?["AppleLanguages"] as? [String] == ["zh-Hans"])
        Localization.applyPreferred(language: "fr", defaults: defaults)
        #expect(defaults.persistentDomain(forName: suite)?["AppleLanguages"] == nil)
        Localization.applyPreferred(language: nil, defaults: defaults)
        #expect(Localization.preferred(domain: defaults.persistentDomain(forName: suite)) == nil)
        #expect(Localization.preferred(domain: ["AppleLanguages": ["en-US"]]) == nil)
        for code in Localization.languages { #expect(Localization.nativeNames[code] != nil) }
    }
}
