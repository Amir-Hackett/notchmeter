import Foundation

/// OpenCode's sessions with nothing installed: read from OpenCode's own database every few seconds while OpenCode is
/// writing to it (OpenCodeStore.sessions), and turned into the same events a hook would have sent, so the Sessions
/// card, the rings and the notices treat them like any other session. Each event carries `SessionSource.localStorage`,
/// and the row says where it came from.
///
/// What this can and cannot know. A session appears when OpenCode writes it, and a turn is working from its prompt
/// until its answer closes, read from the newest messages' own timestamps, so a turn's clock is the prompt's rather
/// than the moment the app noticed. It learns of a turn's end on the next read, up to `interval` late (longer on
/// battery), and it never learns of a wait: a permission request lives in OpenCode's memory, not its database, so a
/// session read this way is never shown waiting, and a waiting one reads as working. The plugin (Settings ›
/// Integrations) reports the turn's end as it happens and the wait itself; once it has spoken, this stands down for
/// the rest of the run, since the two would describe the same session twice.
enum OpenCodeSessions {
    /// What the last read said of one session.
    struct Seen: Equatable, Sendable {
        let turn: OpenCodeSessionState.Turn
        let parentID: String?
    }

    /// How often the database's fingerprint is looked at while OpenCode is shown; a read happens only when it moved.
    static let interval: TimeInterval = 5
    /// On battery or in Low Power Mode.
    static let slowInterval: TimeInterval = 15
    /// While nothing is read (OpenCode off or absent, its plugin reporting, reads paused): only a look at whether that
    /// is still so.
    static let idleInterval: TimeInterval = 60
    /// How far back a session is read: an idle one older than this would be set aside by the tracker at once
    /// (SessionTracker.idleAfter), so it is not worth a row.
    static let lookBack: TimeInterval = SessionTracker.idleAfter

    /// One event to replay into the store, at the moment the database says it happened.
    struct Event: Equatable, Sendable {
        let message: Hook.Message
        let at: Date
    }

    /// The events that take the tracker from what `previous` recorded to what `current` says, oldest first, and the
    /// new record. `previous` is nil on the first read of a run, which shows every session as it stands without
    /// announcing a turn that ended before the app was looking. Times are clamped to the read window, so a replayed
    /// event can never land in the future or older than a session the tracker would keep.
    static func events(previous: [String: Seen]?, current: [OpenCodeSessionState], now: Date,
                       branch: (String) -> String? = Hook.gitBranch(cwd:)) -> (events: [Event], seen: [String: Seen]) {
        var events: [Event] = []
        var seen: [String: Seen] = [:]
        let floor = now.addingTimeInterval(-lookBack)
        func at(_ date: Date?) -> Date { min(max(date ?? now, floor), now) }
        let byID = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func emit(_ event: String, _ state: OpenCodeSessionState, at time: Date, failure: String? = nil) {
            let directory = state.directory ?? state.parentID.flatMap { byID[$0]?.directory }
            var message = Hook.Message(event: event, needsInput: false, sessionID: state.parentID ?? state.id,
                                       project: directory.flatMap(ProjectName.ofPath), branch: directory.flatMap(branch),
                                       agentID: state.parentID == nil ? nil : state.id, failure: failure, tool: .opencode)
            message.source = .localStorage
            events.append(Event(message: message, at: time))
        }
        for state in current {
            let before = previous?[state.id]
            if state.archived {
                if before != nil, state.parentID == nil { emit("SessionEnd", state, at: now) }
                continue
            }
            seen[state.id] = Seen(turn: state.turn, parentID: state.parentID)
            if state.parentID != nil {
                // A subagent's session is counted on the session it works for, while its own turn runs.
                let wasWorking = before.map { if case .working = $0.turn { true } else { false } } ?? false
                switch state.turn {
                case .working(let since) where !wasWorking: emit("SubagentStart", state, at: at(since))
                case .idle where wasWorking: emit("SubagentStop", state, at: now)
                default: break
                }
                continue
            }
            switch (before?.turn, state.turn) {
            case (nil, .working(let since)):
                emit("SessionStart", state, at: at(since))
                emit("UserPromptSubmit", state, at: at(since))
            case (nil, .idle(let finished, let started, let failure)):
                // Seen for the first time already finished: on a later read a whole turn ran between two reads, and
                // it is replayed so its finish is told; on the first read of a run it ended before the app looked.
                if previous != nil, let started, let finished {
                    emit("SessionStart", state, at: at(started))
                    emit("UserPromptSubmit", state, at: at(started))
                    emit(failure == nil ? "Stop" : "StopFailure", state, at: at(finished), failure: failure)
                } else {
                    emit("SessionStart", state, at: at(finished ?? state.updated))
                }
            case (.working(let was)?, .working(let since)) where since > was:
                emit("UserPromptSubmit", state, at: at(since))
            case (.working?, .idle(let finished, _, let failure)):
                emit(failure == nil && finished != nil ? "Stop" : "StopFailure", state, at: at(finished), failure: failure)
            case (.idle?, .working(let since)):
                emit("UserPromptSubmit", state, at: at(since))
            case (.idle(let was, _, _)?, .idle(let finished?, let started, let failure)) where finished > (was ?? .distantPast):
                emit("UserPromptSubmit", state, at: at(started ?? finished))
                emit(failure == nil ? "Stop" : "StopFailure", state, at: at(finished), failure: failure)
            default:
                break
            }
        }
        // A session that was working and is gone (deleted, or quiet past the read window) ended its turn unseen.
        for (id, before) in previous ?? [:] where seen[id] == nil && byID[id] == nil {
            guard case .working = before.turn else { continue }
            let state = OpenCodeSessionState(id: id, parentID: before.parentID, directory: nil, title: nil, updated: now, archived: false,
                                             turn: .idle(finishedAt: nil, turnStarted: nil, failure: nil))
            emit(before.parentID == nil ? "StopFailure" : "SubagentStop", state, at: now)
        }
        return (events.sorted { $0.at < $1.at }, seen)
    }

    /// OpenCode's own title for each top-level session read, by the tracker's key, for SessionTracker.name.
    static func names(_ current: [OpenCodeSessionState]) -> [String: String] {
        current.reduce(into: [:]) { names, state in
            guard state.parentID == nil, !state.archived, let title = state.title else { return }
            names[SessionTracker.key(tool: .opencode, session: state.id, host: nil)] = title
        }
    }
}
