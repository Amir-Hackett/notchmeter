import Foundation
import Testing
@testable import Notchmeter

/// The waiting sound, split three ways. A wait is a permission, a question or a plan to approve, each with its
/// own sound; these pin which hook payload is which kind, that each kind reaches its own preference, and that the
/// single waiting sound a user chose before the split carries over to all three until they choose again.
@MainActor @Suite struct EventSounds {
    func withSuite(_ name: String, _ body: (UserDefaults) throws -> Void) rethrows {
        let suite = "NotchmeterTests.EventSounds.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    let installed = ["Basso", "Glass", "Hero", "Ping", "Pop", "Tink"]

    func permission(_ tool: String) -> Hook.Request {
        Hook.Request(id: "r", kind: .permission(tool: tool, summary: tool, detail: nil, suggestions: []))
    }

    @Test func aRequestSaysWhichKindOfWaitItIs() {
        #expect(Hook.waitKind(event: "PermissionRequest", notificationType: nil, request: permission("Bash")) == .permission)
        #expect(Hook.waitKind(event: "PermissionRequest", notificationType: nil, request: permission("ExitPlanMode")) == .plan,
                "Claude Code asks for a plan's approval as a permission for ExitPlanMode")
        #expect(Hook.waitKind(event: "PermissionRequest", notificationType: nil, request: permission("mcp__plan__ExitPlanMode")) == .permission,
                "only the tool itself, not a name that contains it")
        let question = Hook.Request(id: "q", kind: .question([PendingRequest.Question(text: "Which?", options: [PendingRequest.Option(label: "A")])]))
        #expect(Hook.waitKind(event: "PreToolUse", notificationType: nil, request: question) == .question)
    }

    @Test func aWaitWithNoRequestIsKnownByItsTypeOrIsAPermission() {
        #expect(Hook.waitKind(event: "Notification", notificationType: "permission_prompt", request: nil) == .permission)
        #expect(Hook.waitKind(event: "Notification", notificationType: "idle_prompt", request: nil) == .permission,
                "the idle nudge's banner says it may be waiting for your approval")
        #expect(Hook.waitKind(event: "Notification", notificationType: "elicitation_dialog", request: nil) == .question)
        #expect(Hook.waitKind(event: "Notification", notificationType: "elicitation_url_dialog", request: nil) == .question)
        #expect(Hook.waitKind(event: "Notification", notificationType: "agent_needs_input", request: nil) == .question)
        #expect(Hook.waitKind(event: "Elicitation", notificationType: nil, request: nil) == .question)
        #expect(Hook.waitKind(event: "PermissionRequest", notificationType: nil, request: nil) == .permission,
                "Codex's and Gemini CLI's waits name no tool the app keeps, and a permission is what they are")
    }

    @Test func claudeCodesPlanApprovalParsesAsAPlan() throws {
        let payload = try JSONSerialization.data(withJSONObject: [
            "hook_event_name": "PermissionRequest", "session_id": "s", "tool_name": "ExitPlanMode",
            "tool_input": ["plan": "1. Split the waiting sound"], "permission_mode": "plan",
        ])
        let message = try #require(Hook.message(from: payload, branch: { _ in nil }))
        #expect(message.needsInput)
        #expect(message.waitKind == .plan)
        let question = try JSONSerialization.data(withJSONObject: [
            "hook_event_name": "PreToolUse", "session_id": "s", "tool_name": "AskUserQuestion",
            "tool_input": ["questions": [["question": "Which?", "header": "Pick", "options": [["label": "A"]]]]],
        ])
        #expect(try #require(Hook.message(from: question, branch: { _ in nil })).waitKind == .question)
    }

    @Test func theOracleNamesTheKindTheStoreSettledEvenWithTheRequestDropped() {
        var message = Hook.Message(event: "PermissionRequest", needsInput: true, sessionID: "s")
        message.request = permission("ExitPlanMode")
        let kind = message.waitKind
        message.request = nil
        #expect(UsageStore.hookFacts(message)["wait"] as? String == "permission", "the request is what said plan")
        #expect(UsageStore.hookFacts(message, wait: kind)["wait"] as? String == "plan")
        #expect(UsageStore.hookFacts(Hook.Message(event: "Stop", needsInput: false))["wait"] == nil, "no wait, no kind")
    }

    /// The rule the store keeps, not only the helper: with answering from the notch off the request is dropped
    /// before the tracker sees it, and the plan must still sound as a plan and be named one in the oracle.
    @Test func aPlanSoundsAsAPlanWithAnsweringFromTheNotchOff() throws {
        try withSuite("store") { defaults in
            let prefs = Preferences(defaults: defaults)
            prefs.notifyWaiting = true
            prefs.answerFromNotch = false
            let store = UsageStore(prefs: prefs, providers: [], cache: ReadingCache(defaults: defaults), defaults: defaults,
                                   drainLog: nil, reportFile: nil)
            var raised: [Hook.WaitKind] = []
            store.deliverSessionEvent = { event, _ in if case .waiting(_, let kind) = event { raised.append(kind) } }
            var waits: [String] = []
            store.emitHookFacts = { facts in if let wait = facts["wait"] as? String { waits.append(wait) } }
            let payload = try JSONSerialization.data(withJSONObject: [
                "hook_event_name": "PermissionRequest", "session_id": "s", "tool_name": "ExitPlanMode",
                "tool_input": ["plan": "1. Split the waiting sound"], "permission_mode": "plan",
            ])
            let message = try #require(Hook.message(from: payload, branch: { _ in nil }))
            #expect(message.request != nil, "the payload carries the request the store will drop")
            store.hookReceived(message)
            #expect(raised == [.plan])
            #expect(waits == ["plan"])
            #expect(store.sessions.pending(now: Date()).isEmpty, "the request itself was dropped")
        }
    }

    /// A wait answered in the terminal is never reported, so a session can still read as waiting when its next
    /// request arrives; that request is a new wait with its own sound, not a continuation of the old one.
    @Test func aNewRequestOnAnUnansweredWaitStartsAWaitOfItsOwn() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        func request(_ id: String, tool: String) -> Hook.Message {
            var message = Hook.Message(event: "PermissionRequest", needsInput: true, sessionID: "a")
            message.request = Hook.Request(id: id, kind: .permission(tool: tool, summary: tool, detail: nil, suggestions: []))
            return message
        }
        var tracker = SessionTracker()
        let prompt = Hook.Message(event: "Notification", needsInput: true, sessionID: "a", notificationType: "permission_prompt")
        #expect(tracker.apply(prompt, now: t0).startedWaiting?.id == "a")
        #expect(tracker.apply(request("r1", tool: "ExitPlanMode"), now: t0.addingTimeInterval(5)).startedWaiting?.id == "a",
                "waiting with no request standing: the plan is a wait of its own")
        #expect(tracker.apply(request("r1", tool: "ExitPlanMode"), now: t0.addingTimeInterval(6)).startedWaiting == nil,
                "a replayed request is not a new wait")
        #expect(tracker.apply(request("r2", tool: "Bash"), now: t0.addingTimeInterval(7)).startedWaiting == nil,
                "one replacing a standing request is the same wait, as before")
    }

    @Test func theDefaultEntryNamesTheSoundItRestores() {
        #expect(NotificationSound.defaultTitle(for: NotificationSound.defaultChoice) == L("Default"))
        #expect(NotificationSound.defaultTitle(for: "system:Pop") == L("Default (%@)", "Pop"))
        #expect(NotificationSound.defaultTitle(for: "system:Hero").contains("Hero"))
    }

    @Test func eachSessionEventPlaysUnderItsOwnClass() {
        #expect(Notifier.soundEvent(for: .waiting(blocking: true, kind: .plan)) == .waiting(.plan))
        #expect(Notifier.soundEvent(for: .waiting(blocking: false)) == .waiting(.permission), "a wait that says nothing is a permission")
        #expect(Notifier.soundEvent(for: .finished(turn: 60)) == .finished)
        #expect(Notifier.SoundEvent.waiting(.question).name == "question")
        #expect(Notifier.SoundEvent.pace.name == "pace")
    }

    @Test func theDefaultsAreDistinctAndInstalled() {
        let choices = Hook.WaitKind.allCases.map { NotificationSound.defaultChoice(for: $0, installed: installed) }
        #expect(Set(choices).count == Hook.WaitKind.allCases.count, "three kinds, three sounds")
        #expect(NotificationSound.defaultChoice(for: .permission, installed: installed) == NotificationSound.defaultChoice,
                "a permission keeps the sound every wait played before the split")
        for choice in choices where choice.hasPrefix("system:") {
            #expect(NotificationSound.systemSounds().contains(String(choice.dropFirst("system:".count))), "\(choice) is on this Mac")
        }
        #expect(NotificationSound.defaultChoice(for: .plan, installed: []) == NotificationSound.defaultChoice,
                "a sound the Mac does not have is never offered as a name the picker cannot show")
    }

    @Test func aFreshInstallHearsThreeDifferentSounds() {
        withSuite("fresh") { defaults in
            let prefs = Preferences(defaults: defaults)
            let sounds = Hook.WaitKind.allCases.map { prefs.sound(for: .waiting($0)) }
            #expect(Set(sounds).count == 3)
            #expect(prefs.sound(for: .waiting(.permission)) == NotificationSound.defaultChoice)
        }
    }

    @Test func theOldWaitingSoundCarriesOverToAllThree() {
        withSuite("migrate") { defaults in
            defaults.set("custom:Chime.aiff", forKey: "soundWaiting")
            let prefs = Preferences(defaults: defaults)
            for kind in Hook.WaitKind.allCases {
                #expect(prefs.sound(for: .waiting(kind)) == "custom:Chime.aiff", "\(kind)")
            }
            prefs.soundPlan = "system:Hero"
            let reloaded = Preferences(defaults: defaults)
            #expect(reloaded.soundPlan == "system:Hero", "a choice of its own wins")
            #expect(reloaded.soundPermission == "custom:Chime.aiff" && reloaded.soundQuestion == "custom:Chime.aiff",
                    "and the other two still follow the choice they were migrated from")
            #expect(defaults.string(forKey: "soundWaiting") == "custom:Chime.aiff", "left for an earlier build run again")
        }
    }

    @Test func anOldChoiceOfNoneStaysSilent() {
        withSuite("none") { defaults in
            defaults.set(NotificationSound.none, forKey: "soundWaiting")
            #expect(Hook.WaitKind.allCases.allSatisfy { Preferences.storedWaitSound($0, defaults: defaults, installed: installed) == NotificationSound.none },
                    "someone who silenced waits does not start hearing Pop and Hero after an update")
            defaults.removeObject(forKey: "soundWaiting")
            #expect(Preferences.storedWaitSound(.question, defaults: defaults, installed: installed) == "system:Pop")
            #expect(Preferences.storedWaitSound(.plan, defaults: defaults, installed: installed) == "system:Hero")
        }
    }

    @Test func soundOffSilencesEveryKind() {
        withSuite("off") { defaults in
            let prefs = Preferences(defaults: defaults)
            prefs.notificationSound = false
            for kind in Hook.WaitKind.allCases { #expect(prefs.sound(for: .waiting(kind)) == NotificationSound.none) }
        }
    }
}
