import Foundation
import Testing
@testable import Notchmeter

/// Six sound categories, each with its own sound and its own Silence box (SoundCategory). These pin which notice
/// plays which category on every path that can make a sound — a session event, a pace alert, an advice line — that
/// the choices of 0.8.0 and 0.7.9 are what a user hears after the update, that a stored None becomes a ticked box
/// rather than a sound, that a pick on one row never moves another row or clears its box at the next launch, and
/// that a burst of banners makes one sound (SoundSpacing).
@MainActor @Suite struct SoundCategories {
    func withSuite(_ name: String, _ body: (UserDefaults) throws -> Void) rethrows {
        let suite = "NotchmeterTests.SoundCategories.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    let installed = ["Basso", "Glass", "Hero", "Ping", "Pop", "Purr", "Tink"]
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - Which notice plays which category

    @Test func aWaitThatHasNotStoppedTheSessionPlaysTheWaitingReminder() throws {
        for kind in Hook.WaitKind.allCases {
            #expect(Notifier.soundCategory(for: .waiting(blocking: false, kind: kind)) == .waiting, "\(kind)")
        }
        #expect(Notifier.soundCategory(for: .waiting(blocking: true, kind: .permission), quietNudge: true) == .waiting,
                "a quiet Cursor turn is a possible wait, not the request the permission sound promises")
        #expect(Notifier.soundCategory(for: .finished(turn: 90), quietNudge: true) == .completion)
        // Claude Code's idle reminder, as the hook delivers it.
        let payload = try JSONSerialization.data(withJSONObject: [
            "hook_event_name": "Notification", "session_id": "s", "notification_type": "idle_prompt",
            "message": "Claude is waiting for your input",
        ])
        let message = try #require(Hook.message(from: payload, branch: { _ in nil }))
        #expect(message.needsInput && !message.blocksSession)
        #expect(Notifier.soundCategory(for: .waiting(blocking: message.blocksSession, kind: message.waitKind)) == .waiting)
        // And an elicitation, which has stopped the session, is still a question.
        let elicitation = Hook.Message(event: "Notification", needsInput: true, sessionID: "s", notificationType: "elicitation_dialog")
        #expect(Notifier.soundCategory(for: .waiting(blocking: elicitation.blocksSession, kind: elicitation.waitKind)) == .question)
    }

    /// The rule the store keeps: the idle reminder reaches the notifier as a wait that has not stopped the session,
    /// and a quiet Cursor turn as one on a session marked as a nudge, so both sound as the reminder.
    @Test func theStoreHandsTheNotifierWhatItNeedsToPickTheReminder() {
        withSuite("store") { defaults in
            let prefs = Preferences(defaults: defaults)
            prefs.notifyWaiting = true
            let store = UsageStore(prefs: prefs, providers: [], cache: ReadingCache(defaults: defaults), defaults: defaults,
                                   drainLog: nil, reportFile: nil)
            var played: [SoundCategory] = []
            store.deliverSessionEvent = { event, session in played.append(Notifier.soundCategory(for: event, quietNudge: session.quietNudge)) }
            store.hookReceived(Hook.Message(event: "UserPromptSubmit", needsInput: false, sessionID: "s", project: "p"), now: t0)
            store.hookReceived(Hook.Message(event: "Stop", needsInput: false, sessionID: "s", project: "p"), now: t0.addingTimeInterval(5))
            store.hookReceived(Hook.Message(event: "Notification", needsInput: true, sessionID: "s", project: "p", notificationType: "idle_prompt"),
                               now: t0.addingTimeInterval(65))
            #expect(played == [.waiting], "the idle reminder")

            played = []
            func cursor(_ event: String) -> Hook.Message { Hook.Message(event: event, needsInput: false, sessionID: "c1", project: "p", tool: .cursor) }
            store.hookReceived(cursor("UserPromptSubmit"), now: t0.addingTimeInterval(100))
            store.hookReceived(cursor("afterAgentThought"), now: t0.addingTimeInterval(105))
            store.sweepSessions(now: t0.addingTimeInterval(105 + SessionTracker.quietAfter + 1))
            #expect(played == [.waiting], "a quiet Cursor turn")
        }
    }

    @Test func paceAlertsSoundAsALimitOnlyWhenAWindowIsNearlyOrWhollyGone() {
        #expect(Notifier.soundCategory(for: PaceAlert.Stage.runningOut) == .limit)
        #expect(Notifier.soundCategory(for: PaceAlert.Stage.limitHit) == .limit)
        for stage in [PaceAlert.Stage.onTrack, .behind, .reminder, .reset] {
            #expect(Notifier.soundCategory(for: stage) == nil, "\(stage) arrives without a sound")
        }
    }

    @Test func onlyAdviceAboutMoneyAlreadyFlowingMakesASound() {
        func line(_ priority: Advice.Priority) -> Advice { Advice(id: "x", tool: .claude, priority: priority, symbol: "dollarsign", text: "x") }
        #expect(Notifier.soundCategory(for: line(.danger)) == .limit)
        for priority in [Advice.Priority.attention, .warn, .info] {
            #expect(Notifier.soundCategory(for: line(priority)) == nil, "\(priority)")
        }
    }

    // MARK: - What a user of an earlier build hears after the update

    /// Every row of 0.8.0 as its user left it: a custom finish, a permission of their own, a question set to None,
    /// the Hero plan and a pace sound. Each lands on its category, the waiting reminder takes the permission sound
    /// the idle reminder played in 0.8.0, and nothing an earlier build reads is rewritten.
    @Test func the080ChoicesAreWhatTheSixCategoriesPlay() {
        withSuite("from080") { defaults in
            let stored = ["soundFinished": "custom:Done.aiff", "soundPermission": "system:Tink", "soundQuestion": NotificationSound.none,
                          "soundPlan": "system:Hero", "soundPace": "system:Funk"]
            for (key, value) in stored { defaults.set(value, forKey: key) }
            let prefs = Preferences(defaults: defaults)
            #expect(prefs.sound(for: .completion) == "custom:Done.aiff")
            #expect(prefs.sound(for: .permission) == "system:Tink")
            #expect(prefs.sound(for: .waiting) == "system:Tink", "what Claude Code's idle reminder played through 0.8.0")
            #expect(prefs.sound(for: .plan) == "system:Hero")
            #expect(prefs.sound(for: .limit) == "system:Funk", "the pace sound is the limit sound")
            #expect(prefs.sound(for: .question) == NotificationSound.none)
            #expect(prefs.silencedSounds == [.question], "a None is a ticked box")
            #expect(prefs.soundChoice(for: .question) == NotificationSound.defaultChoice(for: .question), "over the sound it comes back to")
            for (key, value) in stored { #expect(defaults.string(forKey: key) == value, "\(key) is left for an earlier build") }
            #expect(defaults.object(forKey: "soundWaitingReminder") == nil)
            #expect(defaults.object(forKey: "silenceQuestion") == nil, "reading writes nothing")
        }
    }

    @Test func aPermissionSilencedIn080SilencesTheReminderToo() {
        withSuite("permissionNone") { defaults in
            defaults.set(NotificationSound.none, forKey: "soundPermission")
            let prefs = Preferences(defaults: defaults)
            #expect(prefs.silencedSounds == [.permission, .waiting],
                    "the idle reminder was silent in 0.8.0, and it does not start sounding after the update")
        }
    }

    @Test func aFreshInstallStartsOnTheCategoryDefaults() {
        withSuite("fresh") { defaults in
            for category in SoundCategory.allCases {
                let stored = Preferences.storedSound(category, defaults: defaults, installed: installed)
                #expect(stored.choice == NotificationSound.defaultChoice(for: category, installed: installed))
                #expect(!stored.silenced)
            }
            #expect(Preferences.storedSound(.waiting, defaults: defaults, installed: installed).choice == "system:Purr")
            #expect(Preferences.storedSound(.completion, defaults: defaults, installed: installed).choice == "system:Glass")
            #expect(Preferences.storedSound(.limit, defaults: defaults, installed: installed).choice == "system:Basso")
        }
    }

    /// Each category writes under a key of its own and never under 0.7.9's shared one, which three categories
    /// still read and which an earlier build run again still reads too.
    @Test func everyCategoryHasKeysOfItsOwn() {
        let own = SoundCategory.allCases.map(Preferences.soundKey(for:))
        #expect(Set(own).count == SoundCategory.allCases.count)
        #expect(!own.contains("soundWaiting"))
        #expect(Set(SoundCategory.allCases.map(Preferences.silenceKey(for:))).count == SoundCategory.allCases.count)
        #expect(Preferences.soundKey(for: .limit) == "soundPace" && Preferences.soundKey(for: .completion) == "soundFinished",
                "the rows that were already there keep the keys their choices sit under")
    }

    // MARK: - A pick moves one row, and only on screen

    /// The reminder reads the permission key while it has none of its own, so a permission picked on a fresh
    /// install would otherwise become the reminder's sound at the next launch.
    @Test func pickingAPermissionSoundLeavesTheReminderWhereItWas() {
        withSuite("pin") { defaults in
            let prefs = Preferences(defaults: defaults)
            let reminder = prefs.soundChoice(for: .waiting)
            prefs.soundChoices[.permission] = "system:Glass"
            let reloaded = Preferences(defaults: defaults)
            #expect(reloaded.soundChoice(for: .permission) == "system:Glass")
            #expect(reloaded.soundChoice(for: .waiting) == reminder, "the reminder kept its own sound")
            #expect(defaults.string(forKey: "soundWaitingReminder") == reminder, "pinned under its own key")
        }
        withSuite("pin080") { defaults in
            defaults.set("system:Tink", forKey: "soundPermission")
            let prefs = Preferences(defaults: defaults)
            prefs.soundChoices[.permission] = "system:Glass"
            let reloaded = Preferences(defaults: defaults)
            #expect(reloaded.soundChoice(for: .waiting) == "system:Tink", "and one inherited from 0.8.0 stays inherited")
        }
    }

    @Test func pickingASoundOnARowSilencedByAnOldNoneKeepsItsBoxTicked() {
        withSuite("pickSilenced") { defaults in
            defaults.set(NotificationSound.none, forKey: "soundQuestion")
            let prefs = Preferences(defaults: defaults)
            prefs.soundChoices[.question] = "system:Glass"
            #expect(prefs.sound(for: .question) == NotificationSound.none, "choosing is not unsilencing")
            let reloaded = Preferences(defaults: defaults)
            #expect(reloaded.silencedSounds.contains(.question), "nor is relaunching")
            #expect(reloaded.soundChoice(for: .question) == "system:Glass")
            reloaded.setSilenced(false, .question)
            #expect(reloaded.sound(for: .question) == "system:Glass")
            #expect(Preferences(defaults: defaults).sound(for: .question) == "system:Glass")
        }
    }

    // MARK: - The Silence boxes

    @Test func aSilencedCategoryKeepsItsSoundAndSilencesOnlyItself() {
        withSuite("silence") { defaults in
            let prefs = Preferences(defaults: defaults)
            prefs.soundChoices[.completion] = "system:Tink"
            prefs.setSilenced(true, .completion)
            #expect(prefs.sound(for: .completion) == NotificationSound.none)
            #expect(prefs.soundChoice(for: .completion) == "system:Tink", "the choice is kept")
            for category in SoundCategory.allCases where category != .completion {
                #expect(prefs.sound(for: category) != NotificationSound.none, "\(category) still sounds")
            }
            #expect(defaults.object(forKey: "silenceCompletion") as? Bool == true)
            let reloaded = Preferences(defaults: defaults)
            #expect(reloaded.silencedSounds == [.completion])
            reloaded.setSilenced(false, .completion)
            #expect(reloaded.sound(for: .completion) == "system:Tink", "and comes back as it was")
            #expect(defaults.object(forKey: "silenceCompletion") as? Bool == false)
        }
    }

    /// Clearing a box an old None ticked is final: the None is still in the key for an earlier build, and the box's
    /// own key now outranks it.
    @Test func aBoxClearedOverAnOldNoneStaysCleared() {
        withSuite("clearNone") { defaults in
            defaults.set(NotificationSound.none, forKey: "soundPace")
            let prefs = Preferences(defaults: defaults)
            #expect(prefs.silencedSounds == [.limit])
            prefs.setSilenced(false, .limit)
            let reloaded = Preferences(defaults: defaults)
            #expect(reloaded.silencedSounds.isEmpty)
            #expect(reloaded.sound(for: .limit) == NotificationSound.defaultChoice(for: .limit))
            #expect(defaults.string(forKey: "soundPace") == NotificationSound.none)
        }
    }

    @Test func theSnapshotNamesWhatEachCategoryWouldPlay() {
        withSuite("snapshot") { defaults in
            let prefs = Preferences(defaults: defaults)
            prefs.soundChoices[.plan] = "system:Tink"
            prefs.setSilenced(true, .waiting)
            let fields = prefs.soundFields
            #expect(Set(fields.keys) == Set(SoundCategory.allCases.map(\.rawValue)))
            #expect(fields["plan"] == "system:Tink")
            #expect(fields["waiting"] == NotificationSound.none)
        }
    }

    // MARK: - One sound per burst

    @Test func aBurstMakesOneSound() {
        var spacing = SoundSpacing()
        let offsets: [TimeInterval] = [0, 0.2, 1.9, SoundSpacing.interval, SoundSpacing.interval + 1]
        let admitted = offsets.map { spacing.admit(at: t0.addingTimeInterval($0)) }
        // The first sounds; a second banner in the same refresh, and one just inside two seconds, are silent and
        // do not stretch the burst; two seconds after the first, a sound again, which starts a burst of its own.
        let expected = [true, false, false, true, false]
        #expect(admitted == expected)
        #expect(spacing.last == t0.addingTimeInterval(SoundSpacing.interval))
    }

    @Test func aClockSteppedBackwardsHoldsNothing() {
        var spacing = SoundSpacing()
        let first = spacing.admit(at: t0)
        let backwards = spacing.admit(at: t0.addingTimeInterval(-30))
        #expect(first)
        #expect(backwards, "a stamp in the future is not a sound a moment ago")
    }

    // MARK: - Settings

    @Test func theSearchFindsTheSoundsBlock() throws {
        let entries = SettingsSearch.entries()
        let silence = try #require(SettingsSearch.hit(for: "silence", current: .general, in: entries))
        #expect(silence.pane == .notifications)
        #expect(silence.sections == [.sounds])
        let limit = try #require(SettingsSearch.hit(for: "limit alert", current: .general, in: entries))
        #expect(limit.sections == [.sounds])
        for category in SoundCategory.allCases {
            #expect(SettingsSearch.sections(matching: category.title, in: entries).contains(.sounds), "\(category.title)")
        }
    }
}
