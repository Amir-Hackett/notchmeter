import AVFoundation
import Foundation
import Testing
@testable import Notchmeter

/// The format gate on imported sounds. Notification Center plays only aiff, wav and caf from ~/Library/Sounds,
/// while the Preview button's NSSound decodes anything, so before 0.5.0 an imported mp3 previewed and then every
/// banner using it was silent. An import in any other format is now transcoded into a .caf, a leftover .mp3 in the
/// folder is neither offered nor handed to the banner, and an unreadable file is refused by name.
@Suite struct NotificationSoundFormat {
    init() { Localization.use(language: "en") }

    /// A fresh scratch tree with a `src/` for sources and a `Sounds/` standing in for ~/Library/Sounds.
    func scratch() throws -> (root: URL, sounds: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notchmeter-sound-format-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        return (root, root.appendingPathComponent("Sounds"))
    }

    /// A tenth of a second of AAC in an .m4a: a format NSSound plays and UNNotificationSound does not, written with
    /// the encoder macOS ships so the test needs no binary fixture.
    func writeAAC(to url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
        ]
        let output = try AVAudioFile(forWriting: url, settings: settings)
        let frames: AVAudioFrameCount = 4_410
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for i in 0..<Int(frames) { buffer.floatChannelData![0][i] = Float(sin(Double(i) * 0.1)) * 0.5 }
        try output.write(from: buffer)
    }

    @Test func aFormatTheBannerCannotPlayIsTranscodedToCAFOnImport() throws {
        let (root, sounds) = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("src/chime.m4a")
        try writeAAC(to: source)

        let imported = try NotificationSound.importCustom(source, folder: sounds)
        let expected = "custom:chime.caf"
        #expect(imported == expected)
        let again = try NotificationSound.importCustom(source, folder: sounds)
        let expectedSecond = "custom:chime 2.caf"
        #expect(again == expectedSecond, "a clash on the transcoded name gets the same numbered suffix a copy would")

        let written = try AVAudioFile(forReading: sounds.appendingPathComponent("chime.caf"))
        let linearPCM = kAudioFormatLinearPCM
        #expect(written.fileFormat.streamDescription.pointee.mFormatID == linearPCM)
        let sampleRate = 44_100.0
        #expect(written.fileFormat.sampleRate == sampleRate, "the source's rate is kept; only the codec changes")
        // AAC works in 1024-frame packets and the decoder hands back whole packets, so the tail of a 4410-frame
        // source can come back a packet short; what matters is that the sound is there, not that one exact count.
        let atLeast: AVAudioFramePosition = 4_410 - 1_024
        #expect(written.length >= atLeast, "the source's audio survives the round trip")
        #expect(NotificationSound.customSounds(folder: sounds) == ["chime 2.caf", "chime.caf"])
        #expect(NotificationSound.unSound(for: imported) != nil)
        #expect(NotificationSound.unSound(for: imported) != .default)
    }

    /// The Settings row awaits this from the main actor, where until 0.5.0 the import ran inline: a copy then, a
    /// whole-file decode now, which froze Settings and the rings for the length of the track. The choice and the
    /// file arrive exactly as from the synchronous import, and the transcode itself happened off the main thread.
    @MainActor @Test func anImportAwaitedFromTheMainActorStillAppliesItsChoice() async throws {
        let (root, sounds) = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("src/chime.m4a")
        try writeAAC(to: source)

        let imported = try await NotificationSound.importCustomInBackground(source, folder: sounds)
        let expected = "custom:chime.caf"
        #expect(imported == expected)
        #expect(NotificationSound.customSounds(folder: sounds) == ["chime.caf"])
        #expect(NotificationSound.unSound(for: imported) != .default)

        var message: String?
        do {
            _ = try await NotificationSound.importCustomInBackground(root.appendingPathComponent("src/missing.mp3"), folder: sounds)
        } catch {
            message = error.localizedDescription
        }
        #expect(message == "missing.mp3 could not be read as audio, so nothing was imported.", "a refusal comes back the same way")
    }

    @Test func aPlayableFormatIsStillCopiedVerbatim() throws {
        let (root, sounds) = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("src/Ding.WAV")
        try Data([0, 1, 2]).write(to: source)
        let imported = try NotificationSound.importCustom(source, folder: sounds)
        let expected = "custom:Ding.WAV"
        #expect(imported == expected, "the extension's case is the user's; only the lookup lowercases it")
        #expect(try Data(contentsOf: sounds.appendingPathComponent("Ding.WAV")) == Data([0, 1, 2]))
    }

    @Test func aFileThatIsNotAudioIsRefusedByNameAndLeavesNothingBehind() throws {
        let (root, sounds) = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("src/notes.mp3")
        try Data("not audio at all".utf8).write(to: source)
        var message: String?
        do {
            _ = try NotificationSound.importCustom(source, folder: sounds)
        } catch {
            message = error.localizedDescription
        }
        #expect(message == "notes.mp3 could not be read as audio, so nothing was imported.")
        #expect(NotificationSound.customSounds(folder: sounds).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: sounds.appendingPathComponent("notes.caf").path))
    }

    @Test func aLeftoverMP3FromAnOlderBuildIsNeitherOfferedNorSentToTheBanner() throws {
        let (root, sounds) = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: sounds, withIntermediateDirectories: true)
        for name in ["old.mp3", "old.m4a", "keep.aiff", "keep.caf"] {
            try Data([0]).write(to: sounds.appendingPathComponent(name))
        }
        #expect(NotificationSound.customSounds(folder: sounds) == ["keep.aiff", "keep.caf"])
        #expect(NotificationSound.isUnplayableCustom("custom:old.mp3"))
        #expect(NotificationSound.isUnplayableCustom("custom:Old.M4A"))
        #expect(!NotificationSound.isUnplayableCustom("custom:keep.aiff"))
        #expect(!NotificationSound.isUnplayableCustom("system:Glass"))
        // The banner falls back to the default sound rather than naming a file that plays as silence.
        #expect(NotificationSound.unSound(for: "custom:old.mp3") == .default)
        #expect(NotificationSound.unSound(for: "custom:old.m4a") == .default)
        #expect(NotificationSound.unSound(for: "custom:keep.aiff") != .default)
    }
}
