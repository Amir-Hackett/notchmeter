import AppKit
import UserNotifications

/// The sound for one class of notification: the system default, none, one of the alert sounds in
/// /System/Library/Sounds, or a file the user imported into ~/Library/Sounds (where UNNotificationSound can find
/// it by name). Stored as one string: "default", "none", "system:Glass" or "custom:My Chime.aiff".
enum NotificationSound {
    static let defaultChoice = "default"
    static let none = "none"
    static let systemFolder = URL(fileURLWithPath: "/System/Library/Sounds")
    static var userFolder: URL { Paths.home.appendingPathComponent("Library/Sounds") }

    /// The alert sounds macOS ships, by name ("Glass"), sorted.
    static func systemSounds(folder: URL = systemFolder) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasSuffix(".aiff") || $0.hasSuffix(".aif") || $0.hasSuffix(".caf") }
            .map { ($0 as NSString).deletingPathExtension }
            .sorted()
    }

    /// The sounds the user imported, by file name.
    static func customSounds(folder: URL = userFolder) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { ["aiff", "aif", "caf", "wav", "m4a", "mp3"].contains(($0 as NSString).pathExtension.lowercased()) }
            .sorted()
    }

    /// What the notification centre plays for a choice; nil for "none".
    static func unSound(for choice: String) -> UNNotificationSound? {
        switch choice {
        case none: return nil
        case defaultChoice, "": return .default
        default:
            if choice.hasPrefix("system:") {
                let name = String(choice.dropFirst("system:".count))
                return UNNotificationSound(named: UNNotificationSoundName(rawValue: "\(name).aiff"))
            }
            if choice.hasPrefix("custom:") {
                return UNNotificationSound(named: UNNotificationSoundName(rawValue: String(choice.dropFirst("custom:".count))))
            }
            return .default
        }
    }

    /// The choice's name for a picker.
    static func title(for choice: String) -> String {
        switch choice {
        case none: L("None")
        case defaultChoice, "": L("Default")
        default:
            choice.hasPrefix("system:") ? String(choice.dropFirst("system:".count))
                : choice.hasPrefix("custom:") ? (String(choice.dropFirst("custom:".count)) as NSString).deletingPathExtension
                : choice
        }
    }

    /// Plays the choice once, for the Preview button.
    @MainActor
    static func preview(_ choice: String) {
        switch choice {
        case none: return
        case defaultChoice, "": NSSound(named: "Ping")?.play()
        default:
            if choice.hasPrefix("system:") {
                NSSound(named: NSSound.Name(String(choice.dropFirst("system:".count))))?.play()
            } else if choice.hasPrefix("custom:") {
                NSSound(contentsOf: userFolder.appendingPathComponent(String(choice.dropFirst("custom:".count))), byReference: true)?.play()
            }
        }
    }

    /// Copies a chosen file into ~/Library/Sounds and returns its choice string; a name clash gets a numbered suffix.
    static func importCustom(_ source: URL, folder: URL = userFolder) throws -> String {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var name = source.lastPathComponent
        var target = folder.appendingPathComponent(name)
        var counter = 2
        while fm.fileExists(atPath: target.path) {
            name = "\(source.deletingPathExtension().lastPathComponent) \(counter).\(source.pathExtension)"
            target = folder.appendingPathComponent(name)
            counter += 1
        }
        try fm.copyItem(at: source, to: target)
        return "custom:\(name)"
    }
}
