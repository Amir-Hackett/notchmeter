import Foundation

/// One notification to send: a window that has just crossed into a state worth interrupting for, or one whose
/// reset has come (or is about to).
struct PaceAlert: Equatable, Sendable {
    /// Escalating states; a period fires each one at most once and never a lower one after a higher one. `reminder`
    /// and `reset` stand apart: each fires once per period on its own clock, whatever the pace did.
    enum Stage: Int, Codable, Comparable, Sendable {
        case onTrack = 1
        case behind
        /// Behind, and under an hour from running out.
        case runningOut
        /// The reset is within the user's lead time.
        case reminder = 10
        /// The window that was nearly gone has reset.
        case reset = 11

        static func < (lhs: Stage, rhs: Stage) -> Bool { lhs.rawValue < rhs.rawValue }

        var isEscalating: Bool { rawValue < 10 }
    }

    let tool: ToolID
    let window: LimitWindow
    let stage: Stage

    var identifier: String {
        "\(tool.rawValue)/\(window.id)/\(stage.rawValue)/\(Int(window.resetsAt?.timeIntervalSince1970 ?? 0))"
    }
}

/// The highest stage already sent for each window in its current reset period, and the resets and reminders
/// already announced; persisted so a relaunch cannot repeat a notification.
struct AlertMemory: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        let resetsAt: Date
        let stage: PaceAlert.Stage
    }

    var entries: [String: Entry] = [:]
    /// Per window, the reset whose passing was announced.
    var resets: [String: Date] = [:]
    /// Per window, the reset a reminder was sent for.
    var reminders: [String: Date] = [:]

    static let empty = AlertMemory()
    static let defaultsKey = "paceAlertMemory"

    static func key(_ tool: ToolID, _ window: LimitWindow) -> String {
        "\(tool.rawValue)/\(window.id)"
    }

    static func load(from defaults: UserDefaults) -> AlertMemory {
        guard let data = defaults.data(forKey: defaultsKey), let memory = try? JSONDecoder().decode(AlertMemory.self, from: data) else { return .empty }
        return memory
    }

    func save(to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}

/// A window worth telling the user about when it resets: it was at least 80 % used, or behind pace, when last seen.
struct WatchedReset: Equatable, Sendable, Codable {
    let tool: ToolID
    let window: LimitWindow
    let seenAt: Date

    static let watchAbove = 0.8

    static func watch(_ tool: ToolID, _ window: LimitWindow, now: Date) -> WatchedReset? {
        guard let used = window.usedFraction, let resetsAt = window.resetsAt, resetsAt > now else { return nil }
        guard used >= watchAbove || Pace.status(for: window, now: now) == .behind else { return nil }
        return WatchedReset(tool: tool, window: window, seenAt: now)
    }
}

/// Pace-crossing notifications: a window is reported when its pace first reaches on track or behind, and again
/// when it first comes within an hour of running out. Each stage fires once per reset period, only as an
/// escalation, and only once a tenth of the period has elapsed, because the projection from the first minutes
/// of a window is noise no one should be interrupted for. Reset and reminder alerts are timer-driven: they fire
/// when the clock passes the reset (or the lead time before it) of a watched window, once each per period.
enum NotificationScheduler {
    static let runningOutWithin: TimeInterval = 3600
    static let minimumElapsedFraction = 0.1
    /// Resets reported a little apart (a Codex snapshot's reset is measured from when it was written) are the same period.
    static let samePeriodTolerance: TimeInterval = 600

    /// Which stages the user wants; a stage that is off is still remembered, so turning it on later cannot replay old crossings.
    struct Options: Equatable, Sendable {
        var onTrack = true
        var behind = true
        var runningOut = true
        var reset = true
        var reminderLead: TimeInterval? = nil

        static let all = Options()

        func wants(_ stage: PaceAlert.Stage) -> Bool {
            switch stage {
            case .onTrack: onTrack
            case .behind: behind
            case .runningOut: runningOut
            case .reset: reset
            case .reminder: reminderLead != nil
            }
        }
    }

    /// `rate` is a measured drain in fraction per hour (DrainLog); with one, the run-out time comes from it rather
    /// than the even-burn projection.
    static func stage(for window: LimitWindow, now: Date, rate: Double? = nil) -> PaceAlert.Stage? {
        guard let used = window.usedFraction, let resetsAt = window.resetsAt, let period = window.periodDuration,
              let elapsed = Pace.elapsedFraction(resetsAt: resetsAt, period: period, now: now), elapsed >= minimumElapsedFraction,
              let result = Pace.evaluate(usedFraction: used, resetsAt: resetsAt, period: period, now: now)
        else { return nil }
        switch result.status {
        case .ahead:
            return nil
        case .onTrack:
            return .onTrack
        case .behind:
            let eta = Pace.secondsToRunOut(usedFraction: used, rate: rate, resetsAt: resetsAt, now: now)
                ?? Pace.secondsToRunOut(usedFraction: used, resetsAt: resetsAt, period: period, now: now)
            if let eta, eta < runningOutWithin { return .runningOut }
            return .behind
        }
    }

    static func plan(memory: AlertMemory, readings: [UsageReading], now: Date, options: Options = .all,
                     rates: [String: Double] = [:]) -> (alerts: [PaceAlert], memory: AlertMemory) {
        var memory = memory
        var alerts: [PaceAlert] = []
        for reading in readings {
            for window in reading.windows {
                guard let resetsAt = window.resetsAt else { continue }
                let key = AlertMemory.key(reading.tool, window)
                let previous = memory.entries[key]
                let samePeriod = previous.map { abs($0.resetsAt.timeIntervalSince(resetsAt)) < samePeriodTolerance } ?? false
                guard let stage = stage(for: window, now: now, rate: rates[key]) else {
                    if !samePeriod { memory.entries[key] = nil }
                    continue
                }
                if samePeriod, let previous, previous.stage >= stage { continue }
                memory.entries[key] = AlertMemory.Entry(resetsAt: resetsAt, stage: stage)
                if options.wants(stage) { alerts.append(PaceAlert(tool: reading.tool, window: window, stage: stage)) }
            }
        }
        memory.entries = memory.entries.filter { $0.value.resetsAt > now }
        return (alerts, memory)
    }

    /// The timer's half: for each watched window, a reminder once the lead time is reached and a reset once the
    /// reset has passed, each once per reset. Watched windows whose reset has passed are dropped from the list.
    static func planResets(memory: AlertMemory, watched: [WatchedReset], now: Date, options: Options) -> (alerts: [PaceAlert], memory: AlertMemory, watched: [WatchedReset]) {
        var memory = memory
        var alerts: [PaceAlert] = []
        var remaining: [WatchedReset] = []
        for watch in watched {
            guard let resetsAt = watch.window.resetsAt else { continue }
            let key = AlertMemory.key(watch.tool, watch.window)
            if now >= resetsAt {
                if options.reset, memory.resets[key] != resetsAt {
                    memory.resets[key] = resetsAt
                    alerts.append(PaceAlert(tool: watch.tool, window: watch.window, stage: .reset))
                }
                continue
            }
            remaining.append(watch)
            if let lead = options.reminderLead, resetsAt.timeIntervalSince(now) <= lead, memory.reminders[key] != resetsAt {
                memory.reminders[key] = resetsAt
                alerts.append(PaceAlert(tool: watch.tool, window: watch.window, stage: .reminder))
            }
        }
        memory.resets = memory.resets.filter { now.timeIntervalSince($0.value) < 2 * Period.week }
        memory.reminders = memory.reminders.filter { $0.value > now.addingTimeInterval(-Period.week) }
        return (alerts, memory, remaining)
    }
}

extension Pace {
    /// Seconds until the quota is gone at a measured rate (fraction per hour), only when that is before the reset.
    static func secondsToRunOut(usedFraction: Double, rate: Double?, resetsAt: Date, now: Date) -> TimeInterval? {
        guard let rate, rate > 0, usedFraction < 1 else { return nil }
        let eta = (1 - usedFraction) / rate * 3600
        guard eta > 0, eta < resetsAt.timeIntervalSince(now) else { return nil }
        return eta
    }
}
