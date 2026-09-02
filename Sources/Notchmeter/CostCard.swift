import Foundation

/// One provider's weight in a range: what sizes its arc of the donut and its share in the legend.
struct CostWeight: Equatable, Sendable, Identifiable {
    let tool: ToolID
    let weight: Double
    var id: ToolID { tool }
}

/// One provider's arc of the donut, as fractions of the circle clockwise from twelve o'clock.
struct CostArc: Equatable, Sendable, Identifiable {
    let tool: ToolID
    let start: Double
    let end: Double
    var id: ToolID { tool }
}

/// The assistants the Cost card carries: the ones that reported spend, in the user's order
/// (`Preferences.toolOrder`), less any the card is set to leave out (`Preferences.costCardTools`). The figure in
/// the middle, the donut, the legend and the card's own lines all read from one of these, so the card cannot
/// show a total over one set of assistants and a split over another.
///
/// A tool that cannot derive spend from something it publishes has no `ProviderCost` and so is never here: no
/// zero row, no invented figure (docs/accuracy.md).
struct CostSelection: Equatable, Sendable {
    let providers: [ProviderCost]

    init(providers: [ProviderCost] = []) {
        self.providers = providers
    }

    init(all: [ProviderCost], order: [ToolID], carried: Set<ToolID>) {
        providers = order.compactMap { tool in carried.contains(tool) ? all.first { $0.tool == tool } : nil }
    }

    var isEmpty: Bool { providers.isEmpty }

    func provider(_ tool: ToolID) -> ProviderCost? { providers.first { $0.tool == tool } }

    /// The range across the carried providers: their dollars, tokens, models and projects added together.
    func totals(_ range: CostRange) -> RangeTotals {
        providers.reduce(into: RangeTotals()) { $0.add($1.totals(range)) }
    }

    /// What the carried providers priced in the last hour. One whose source is day-resolution (a billing export)
    /// contributes nothing rather than a zero, which is why the burn multiple below needs one that can say.
    var lastHour: Double { providers.compactMap(\.lastHour).reduce(0, +) }

    var typicalHourly: Double { providers.compactMap(\.typicalHourly).reduce(0, +) }

    var burnMultiple: Double? {
        guard providers.contains(where: { $0.burnMultiple != nil }), typicalHourly > 0 else { return nil }
        return lastHour / typicalHourly
    }

    var unpricedModels: Set<String> {
        providers.reduce(into: Set<String>()) { $0.formUnion($1.unpricedModels) }
    }

    /// What sizes each provider's slice, in the mode's own unit: tokens under Tokens, dollars otherwise. A rate
    /// per million tokens cannot be shared out (the shares would not add up to the whole), so $/MTok is sized by
    /// its dollars. A provider with nothing in the range is left out, so no slice is a zero-width sliver.
    func weights(range: CostRange, mode: CostCardMode) -> [CostWeight] {
        providers.compactMap { provider in
            let totals = provider.totals(range)
            let weight = mode == .tokens ? Double(totals.tokens.total) : totals.cost
            return weight > 0 ? CostWeight(tool: provider.tool, weight: weight) : nil
        }
    }

    /// A provider's share of the range in the mode's own unit, 0...1; nil where nothing was spent in it.
    func share(of tool: ToolID, range: CostRange, mode: CostCardMode) -> Double? {
        let weights = weights(range: range, mode: mode)
        let total = weights.reduce(0) { $0 + $1.weight }
        guard total > 0, let mine = weights.first(where: { $0.tool == tool })?.weight else { return nil }
        return mine / total
    }
}

/// The Cost card's donut: one arc per assistant that spent in the range, sized by its share and drawn in that
/// assistant's own colour, with the total in the middle.
///
/// With one assistant reporting it is the ring the card has always drawn, to the same twelfth of a per cent.
/// With none — a range nothing was spent in — it is the bare track rather than a full circle of some colour,
/// which would claim a spender.
enum CostDonut {
    /// The gap at twelve o'clock the ring has always left.
    static let gap = 0.012
    /// The hairline between two arcs, so the boundary reads where two colours sit close.
    static let separation = 0.01

    /// `fill` is the month against its budget where one is set (the arc the card has always drawn against a
    /// budget), nil where there is no budget and the arc is the whole circle.
    static func arcs(_ weights: [CostWeight], fill: Double? = nil) -> [CostArc] {
        guard let fill else { return arcs(weights, from: gap, to: 1 - gap) }
        return arcs(weights, from: 0, to: max(gap, min(1, fill)))
    }

    static func arcs(_ weights: [CostWeight], from: Double, to: Double) -> [CostArc] {
        let total = weights.reduce(0) { $0 + $1.weight }
        guard total > 0, to > from else { return [] }
        var arcs: [CostArc] = []
        var start = from
        for (index, weight) in weights.enumerated() {
            let last = index == weights.count - 1
            let end = last ? to : start + (to - from) * weight.weight / total
            arcs.append(CostArc(tool: weight.tool, start: start, end: end - (last ? 0 : min(separation, (end - start) / 3))))
            start = end
        }
        return arcs
    }
}
