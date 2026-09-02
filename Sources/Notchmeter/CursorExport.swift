import Foundation

/// What Cursor's usage export last answered, written by CursorProvider after every attempt and read by the Cost
/// card. Without it a refusal, an export with nothing in it, and an export nobody ever fetched all reach the card
/// as the same silence, and the card printed "no spend read yet" for an account it had just read.
///
/// Nothing here is derived: the count and the sum are the export's own (docs/accuracy.md).
struct CursorExportRead: Codable, Equatable, Sendable {
    var readAt: Date
    /// How many usage events the export returned. Zero is an answer, not a failure.
    var events: Int
    /// What those events cost, as the export itself priced them.
    var costUSD: Double
    /// Why it could not be read, in the words the card prints; nil when it answered.
    var problem: String?

    static let defaultsKey = "cursorUsageEventsLastRead"

    init(readAt: Date, events: Int = 0, costUSD: Double = 0, problem: String? = nil) {
        self.readAt = readAt
        self.events = events
        self.costUSD = costUSD
        self.problem = problem
    }

    static func load(from defaults: UserDefaults) -> CursorExportRead? {
        guard let data = defaults.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(CursorExportRead.self, from: data)
    }

    func save(to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
