import Foundation

/// One synthetic window standing for every model-scoped window a tool publishes at once — "All models" — for a
/// plan that splits its allowance by model (Cursor's Enterprise "Cursor models" and "Other models", Anthropic's
/// per-model weekly caps).
///
/// It is derived here, never read from a vendor, so it must not claim precision the source does not have
/// (docs/accuracy.md). The rules, in order:
///
/// - Only windows that publish a `usedFraction` count. A window with no limit says nothing and contributes
///   nothing, rather than being read as zero.
/// - Fewer than two model-scoped windows report → nil. Nothing synthetic appears where there is nothing to
///   combine, and a lone model window is already on the card under its own name.
/// - Where the vendor itself publishes the total those windows are shares of, that figure is adopted exactly as
///   it stands and is never recomputed from the shares: Cursor's "Included usage" already IS the plan total, and
///   adding the splits back together would round differently from the vendor's own arithmetic. A window counts as
///   that total when it is not scoped to a model, covers the same period and reset as every model window it would
///   cover, and does not read below any of them — one that reads lower is not their parent, whatever it is.
/// - Otherwise the figure is the highest of the model windows. Never a mean: averaging a maxed-out model with an
///   untouched one would show headroom that does not exist.
/// - The reset is the soonest among the windows covered, so a countdown never runs past the first cap to bite.
///
/// No money is added up. The combined window carries no `amountUSD`: a share of a total and a dollar figure are
/// not the same arithmetic, and summing shares across models would double-count the total's own dollars.
enum CombinedWindow {
    /// The stable id the ring pickers and `Preferences.ringWindows` store.
    static let id = "combined"

    static func of(reading: UsageReading) -> LimitWindow? {
        of(windows: reading.windows)
    }

    static func of(windows: [LimitWindow]) -> LimitWindow? {
        let reporting = windows.filter { $0.usedFraction != nil && $0.id != id }
        let models = reporting.filter { $0.model != nil }
        guard models.count >= 2, let highest = models.compactMap(\.usedFraction).max() else { return nil }
        let total = reporting.first { candidate in
            candidate.model == nil
                && (candidate.usedFraction ?? 0) >= highest
                && models.allSatisfy { candidate.resetsAt == $0.resetsAt && candidate.periodDuration == $0.periodDuration }
        }
        let covered = total.map { [$0] + models } ?? models
        return LimitWindow(
            id: id,
            label: .key("All models"),
            usedFraction: total?.usedFraction ?? highest,
            resetsAt: covered.compactMap(\.resetsAt).min(),
            note: L("Combined from the windows below"),
            periodDuration: total?.periodDuration ?? models.first { $0.usedFraction == highest }?.periodDuration,
            source: .localEstimate
        )
    }
}
