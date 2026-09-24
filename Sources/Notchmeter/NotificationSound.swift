import AppKit
import AVFoundation
import UserNotifications

/// The six kinds of notice a sound is chosen for, each with its own sound and its own Silence box in
/// Settings › Notifications › Sounds. Through 0.8.0 there were five pickers and one switch for all of them: a
/// pace crossing, three kinds of wait and a finished turn, with Claude Code's idle reminder sharing the
/// permission sound although nothing had asked for permission, and the only way to quiet one kind was a None
/// entry in its picker that threw the chosen sound away. The Silence box is separate from the choice so that
/// silencing a kind and bringing it back later returns the sound it had.
///
/// The raw value is the word the oracle's `notification` line uses for the sound (docs/testing.md). The order
/// is the Settings rows' order.
enum SoundCategory: String, CaseIterable, Sendable {
    /// A turn longer than the minimum finished (`Notifier.SessionEvent.finished`).
    case completion
    /// A session that may be waiting on you without having said it has stopped: Claude Code's idle reminder
    /// (`idle_prompt`, `Hook.Message.blocksSession` false) and a Cursor turn gone quiet with nothing running
    /// (`SessionTracker.quietNudges`), which is inferred rather than reported.
    case waiting
    /// A tool waiting for approval, and every wait that has stopped the session without saying what it wants.
    case permission
    /// `AskUserQuestion`, an MCP server's elicitation, an agent asking for input.
    case question
    /// `ExitPlanMode`: a plan written and waiting for a yes.
    case plan
    /// A window almost out or out (the pace alerts' two loud stages, a StopFailure for the rate limit included),
    /// and advice about money already being spent.
    case limit

    /// The category a wait that has stopped the session plays under, by what it asks for.
    init(_ kind: Hook.WaitKind) {
        self = switch kind {
        case .permission: .permission
        case .question: .question
        case .plan: .plan
        }
    }
}

/// The sound for one class of notification: the system default, none, one of the alert sounds in
/// /System/Library/Sounds, or a file the user imported into ~/Library/Sounds (where UNNotificationSound can find
/// it by name). Stored as one string: "default", "none", "system:Glass" or "custom:My Chime.aiff". No picker
/// offers "none" since the Silence boxes arrived (SoundCategory); it is what `Preferences.sound(for:)` answers
/// for a silenced category, and a choice of None an earlier build stored is read as that category silenced.
enum NotificationSound {
    static let defaultChoice = "default"
    static let none = "none"
    static let systemFolder = URL(fileURLWithPath: "/System/Library/Sounds")
    static var userFolder: URL { Paths.home.appendingPathComponent("Library/Sounds") }

    /// The file extensions Notification Center will actually play from ~/Library/Sounds. UNNotificationSound is
    /// documented to play Linear PCM, MA4, uLaw or aLaw packaged as aiff, wav or caf, and nothing else: an mp3 or an
    /// AAC .m4a handed to it by name plays silence. NSSound decodes those happily, so until 0.5.0 the Preview button
    /// confirmed a chime that every banner then dropped, and the one notification class the user had customised was
    /// the quiet one. Everything outside this set is transcoded into a .caf on import rather than refused, so the
    /// user still gets the sound they picked.
    static let playable: Set<String> = ["aiff", "aif", "wav", "caf"]

    /// The alert sounds macOS ships, by name ("Glass"), sorted.
    static func systemSounds(folder: URL = systemFolder) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasSuffix(".aiff") || $0.hasSuffix(".aif") || $0.hasSuffix(".caf") }
            .map { ($0 as NSString).deletingPathExtension }
            .sorted()
    }

    /// The sound each category starts with, chosen so the six can be told apart without looking. A permission
    /// keeps the system's own alert, which is what every wait played before the kinds were split and the one most
    /// people already answer by reflex. A question takes Pop, short and light, since it asks for a choice rather
    /// than leave; a plan takes Hero, the fuller rising one, since a plan ready is a piece of work finished and
    /// waiting for a yes. A finished turn takes Glass, the clear chime of something done. The waiting reminder
    /// takes Purr, the softest of the set, because it stands for a session that may need you rather than one
    /// that has stopped; and a limit takes Basso, the low thud macOS itself plays when something cannot go on.
    /// A system sound this Mac does not have falls back to the default rather than to a name the picker cannot
    /// show.
    static func defaultChoice(for category: SoundCategory, installed: [String] = systemSounds()) -> String {
        let name: String? = switch category {
        case .completion: "Glass"
        case .waiting: "Purr"
        case .permission: nil
        case .question: "Pop"
        case .plan: "Hero"
        case .limit: "Basso"
        }
        guard let name, installed.contains(name) else { return defaultChoice }
        return "system:\(name)"
    }

    /// The Default entry's name in a row whose default is `defaultTag`: plain "Default" for the system alert, and
    /// "Default (Pop)" where a category starts with a sound of its own, so choosing it says what it restores.
    static func defaultTitle(for defaultTag: String) -> String {
        defaultTag == defaultChoice ? L("Default") : L("Default (%@)", title(for: defaultTag))
    }

    /// The sounds the user imported, by file name. Only the extensions Notification Center can play are offered:
    /// a .mp3 or .m4a that an earlier build copied in verbatim would preview and then never sound on a banner.
    static func customSounds(folder: URL = userFolder) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { playable.contains(($0 as NSString).pathExtension.lowercased()) }
            .sorted()
    }

    /// True for a "custom:" choice whose file Notification Center cannot play by name.
    static func isUnplayableCustom(_ choice: String) -> Bool {
        guard choice.hasPrefix("custom:") else { return false }
        return !playable.contains((String(choice.dropFirst("custom:".count)) as NSString).pathExtension.lowercased())
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
                // A "custom:chime.mp3" stored by a build before 0.5.0 names a file Notification Center plays as
                // silence; the default sound is what the user would have heard had they never imported it.
                if isUnplayableCustom(choice) { return .default }
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

    enum ImportFailure: LocalizedError {
        case unreadable(URL)

        var errorDescription: String? {
            switch self {
            case .unreadable(let url): L("%@ could not be read as audio, so nothing was imported.", url.lastPathComponent)
            }
        }
    }

    /// Puts a chosen file into ~/Library/Sounds and returns its choice string; a name clash gets a numbered suffix.
    /// A file in a format Notification Center plays (`playable`) is copied as it is; anything else is decoded and
    /// written as Linear PCM in a .caf of the same name, so an mp3 picked from Downloads sounds on the banner
    /// exactly as it did under Preview.
    static func importCustom(_ source: URL, folder: URL = userFolder) throws -> String {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let copyVerbatim = playable.contains(source.pathExtension.lowercased())
        let base = source.deletingPathExtension().lastPathComponent
        let ext = copyVerbatim ? source.pathExtension : "caf"
        var name = "\(base).\(ext)"
        var target = folder.appendingPathComponent(name)
        var counter = 2
        while fm.fileExists(atPath: target.path) {
            name = "\(base) \(counter).\(ext)"
            target = folder.appendingPathComponent(name)
            counter += 1
        }
        if copyVerbatim {
            try fm.copyItem(at: source, to: target)
        } else {
            try transcodeToCAF(source, to: target)
        }
        return "custom:\(name)"
    }

    /// `importCustom` run off the calling actor, for the Settings row. Until 0.5.0 the import was a copy, a few
    /// milliseconds however long the file, and ran on the main actor because the row's state lives there. Now
    /// that an mp3 or m4a is decoded and re-encoded whole, the same call on the main actor froze Settings, the
    /// notch rings and the menu bar item for as long as the decode took, which grows with the track: a four-minute
    /// song picked from Music was a stall of a second or more. The file work happens on a detached task and only
    /// the choice string, or the failure, comes back to whoever awaited it.
    static func importCustomInBackground(_ source: URL, folder: URL = userFolder) async throws -> String {
        try await Task.detached(priority: .userInitiated) { try importCustom(source, folder: folder) }.value
    }

    /// Decodes any file AVFoundation can read into 16-bit Linear PCM in a .caf, the one container that takes any
    /// sample rate and channel count Notification Center will play. The source's own rate and channels are kept so
    /// nothing is resampled; only the codec changes. A file AVFoundation cannot open (a PDF renamed .mp3, a DRM
    /// track) is reported by name rather than as a bare CoreAudio code, and nothing is left behind in the folder.
    private static func transcodeToCAF(_ source: URL, to target: URL) throws {
        let input: AVAudioFile
        do {
            input = try AVAudioFile(forReading: source)
        } catch {
            throw ImportFailure.unreadable(source)
        }
        let format = input.processingFormat
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16384) else {
            throw ImportFailure.unreadable(source)
        }
        do {
            let output = try AVAudioFile(forWriting: target, settings: settings)
            // The loop stops on the frame count rather than on an empty read: on macOS 26 a read at the end of the
            // file throws (as a bare nilError) instead of handing back zero frames, which turned every transcode
            // into a refusal the first time this was tried.
            while input.framePosition < input.length {
                try input.read(into: buffer)
                if buffer.frameLength == 0 { break }
                try output.write(from: buffer)
            }
        } catch {
            try? FileManager.default.removeItem(at: target)
            throw ImportFailure.unreadable(source)
        }
    }
}
