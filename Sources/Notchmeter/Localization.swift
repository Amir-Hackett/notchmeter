import Foundation
import os

/// The user-visible copy, looked up in Resources/<language>.lproj/Localizable.strings. Keys are the English text,
/// so an entry missing from a table still reads correctly; LocalizationTests keeps every table complete and every
/// key in use.
enum Localization {
    /// The languages shipped, as .lproj names. CFBundleLocalizations in scripts/Info.plist lists the same ones,
    /// because a resource bundle takes the language macOS chose for the app, and it chooses from that list.
    static let languages = ["en", "zh-Hans", "zh-Hant", "ja", "ko", "vi"]
    static let bundleName = "Notchmeter_Notchmeter.bundle"

    /// The name each language gives itself, for the picker.
    static let nativeNames: [String: String] = [
        "en": "English", "zh-Hans": "简体中文", "zh-Hant": "繁體中文", "ja": "日本語", "ko": "한국어", "vi": "Tiếng Việt",
    ]

    /// The resource bundle SwiftPM builds. Its own accessor looks beside the executable and at the build path, which
    /// covers `swift run` and the tests; scripts/build.sh puts a copy under Contents/Resources, which covers the app.
    static let resources: Bundle = {
        if let url = Bundle.main.resourceURL?.appendingPathComponent(bundleName),
           FileManager.default.fileExists(atPath: url.path), let bundle = Bundle(url: url) {
            return bundle
        }
        return Bundle.module
    }()

    private static let pinned = OSAllocatedUnfairLock<(language: String, table: [String: String])?>(initialState: nil)

    /// Pins the copy to one shipped language for the rest of the process (`--lang zh-Hans`, and the tests); nil,
    /// or a language not shipped, follows the one macOS chose for the app.
    static func use(language: String?) {
        let shipped = language.flatMap(canonical)
        let table = shipped.flatMap(table(language:))
        pinned.withLock { $0 = shipped.flatMap { code in table.map { (code, $0) } } }
    }

    /// The language the copy comes out in.
    static var current: String {
        if let pinned = pinned.withLock({ $0?.language }) { return pinned }
        return resources.preferredLocalizations.first.flatMap(canonical) ?? languages[0]
    }

    static func string(_ key: String) -> String {
        if let pinned = pinned.withLock({ $0 }) { return pinned.table[key] ?? key }
        return resources.localizedString(forKey: key, value: nil, table: nil)
    }

    /// One language's whole table, read straight from its .strings file; nil when that language is not shipped.
    static func table(language: String) -> [String: String]? {
        // SwiftPM lowercases the .lproj names it copies, and a case-sensitive volume would not match zh-Hans to zh-hans.
        guard let lproj = resources.localizations.first(where: { $0.caseInsensitiveCompare(language) == .orderedSame }),
              let url = resources.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: lproj),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: String]
    }

    /// The entry of `languages` a code names, whatever its case; nil for a language not shipped.
    static func canonical(_ language: String) -> String? {
        languages.first { $0.caseInsensitiveCompare(language) == .orderedSame }
    }

    /// The in-app language picker: a shipped code is written as `AppleLanguages` into the app's own defaults domain,
    /// which macOS reads at the next launch (the same key System Settings › Language & Region › Applications sets);
    /// nil removes it so the app follows the system again. Takes effect at relaunch, as the picker says.
    static func applyPreferred(language: String?, defaults: UserDefaults) {
        if let language, let code = canonical(language) {
            defaults.set([code], forKey: "AppleLanguages")
        } else {
            defaults.removeObject(forKey: "AppleLanguages")
        }
    }

    /// What the picker stored in the domain, when it stored a shipped language; the global domain's own
    /// AppleLanguages (the system language) is not consulted.
    static func preferred(domain: [String: Any]?) -> String? {
        (domain?["AppleLanguages"] as? [String])?.first.flatMap(canonical)
    }
}

func L(_ key: String) -> String {
    Localization.string(key)
}

/// `%@` takes a String and `%ld` an Int; a literal per cent sign is `%%`. Positions (`%1$@`) let a translation reorder.
func L(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: Localization.string(key), arguments: arguments)
}
