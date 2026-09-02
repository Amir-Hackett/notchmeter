import Foundation

/// One notification to send: a window that has just crossed into a state worth interrupting for.
struct PaceAlert: Equatable, Sendable {
    /// Escalating states; a period fires each one at most once and never a lower one after a higher one.
    enum Stage: Int, Codable, Comparable, Sendable {
        case onTrack = 1
        case behind
        /// Behind, and under an hour from running out.
        case runningOut

        static func < (lhs: Stage, rhs: Stage) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    let tool: ToolID
    let window: LimitWindow
    let stage: Stage

    var identifier: String {
        "\(tool.rawValue)/\(window.id)/\(stage.rawValue)/\(Int(window.resetsAt?.timeIntervalSince1970 ?? 0))"
    }
}

/// The highest stage already sent for each window in its current reset period; persisted so a relaunch cannot
/// repeat a notification.
struct AlertMemory: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        let resetsAt: Date
        let stage: PaceAlert.Stage
    }

    var entries: [String: Entry] = [:]

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

/// Pace-crossing notifications: a window is reported when its pace first reaches on track or behind, and again
/// when it first comes within an hour of running out. Each stage fires once per reset period, only as an
/// escalation, and only once a tenth of the period has elapsed, because the projection from the first minutes
/// of a window is noise no one should be interrupted for.
enum NotificationScheduler {
    static let runningOutWithin: TimeInterval = 3600
    static let minimumElapsedFraction = 0.1
    /// Resets reported a little apart (a Codex snapshot's reset is measured from when it was written) are the same period.
    static let samePeriodTolerance: TimeInterval = 600

    static func stage(for window: LimitWindow, now: Date) -> PaceAlert.Stage? {
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
            if let eta = Pace.secondsToRunOut(usedFraction: used, resetsAt: resetsAt, period: period, now: now), eta < runningOutWithin {
                return .runningOut
            }
            return .behind
        }
    }

    static func plan(memory: AlertMemory, readings: [UsageReading], now: Date) -> (alerts: [PaceAlert], memory: AlertMemory) {
        var memory = memory
        var alerts: [PaceAlert] = []
        for reading in readings {
            for window in reading.windows {
                guard let resetsAt = window.resetsAt else { continue }
                let key = AlertMemory.key(reading.tool, window)
                let previous = memory.entries[key]
                let samePeriod = previous.map { abs($0.resetsAt.timeIntervalSince(resetsAt)) < samePeriodTolerance } ?? false
                guard let stage = stage(for: window, now: now) else {
                    if !samePeriod { memory.entries[key] = nil }
                    continue
                }
                if samePeriod, let previous, previous.stage >= stage { continue }
                memory.entries[key] = AlertMemory.Entry(resetsAt: resetsAt, stage: stage)
                alerts.append(PaceAlert(tool: reading.tool, window: window, stage: stage))
            }
        }
        memory.entries = memory.entries.filter { $0.value.resetsAt > now }
        return (alerts, memory)
    }
}
