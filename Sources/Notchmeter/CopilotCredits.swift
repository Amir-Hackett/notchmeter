import Foundation

/// What GitHub last said about the seat's AI credits, written by CopilotProvider after every successful read of
/// the quota endpoint and read back for the next read's delta and by the Cost card. Without it a seat that is not
/// metered in credits, a seat that has used none, and a seat nobody has read yet would all reach the card as the
/// same silence (docs/accuracy.md).
struct CopilotCreditsRead: Codable, Equatable, Sendable {
    var readAt: Date
    /// The month's `credits_used` added up across the snapshots; nil when no snapshot carried the field, which
    /// is a seat GitHub does not meter in credits.
    var credits: Double?

    static let defaultsKey = "copilotCreditsLastRead"

    init(readAt: Date, credits: Double?) {
        self.readAt = readAt
        self.credits = credits
    }

    /// True when the seat is metered in credits at all.
    var metered: Bool { credits != nil }

    func save(to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    static func load(from defaults: UserDefaults) -> CopilotCreditsRead? {
        guard let data = defaults.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(CopilotCreditsRead.self, from: data)
    }
}
