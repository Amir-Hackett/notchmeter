import Foundation
import SwiftUI
import Observation
import ServiceManagement

enum NotchVisibility: String, CaseIterable, Codable {
    case onHover, onClick, always, hideWhenIdle

    var title: String {
        switch self {
        case .onHover: L("Open on hover")
        case .onClick: L("Open on click")
        case .always: L("Always open")
        case .hideWhenIdle: L("Hide when idle")
        }
    }
}

/// Where the panel lives. Top merges with the physical notch; the sides are a notch of the same shape cut into
/// that edge of the screen, with the panel opening beside them; the bottom is a Codenotch-style bar.
enum PanelEdge: String, CaseIterable, Codable {
    case top, left, right, bottom

    var title: String {
        switch self {
        case .top: L("Top, in the notch")
        case .left: L("Left edge")
        case .right: L("Right edge")
        case .bottom: L("Bottom, above the Dock")
        }
    }

    var detail: String {
        switch self {
        case .top: L("Readings sit beside the notch and open below it.")
        case .left: L("A notch cut into the left-hand edge, with the panel opening beside it. It gives way to a Dock or Stage Manager's strip on that side.")
        case .right: L("A notch cut into the right-hand edge, with the panel opening beside it. It gives way to a Dock on that side.")
        case .bottom: L("A bar resting on top of the Dock.")
        }
    }

    /// The Settings and Options label for the compact readout, which has to name the shape the reader can
    /// actually see: rings beside the hardware notch, inside the notch cut into a side edge, or inside the bar on
    /// the bottom. "In the side notch" rather than "In the notch", which at a glance is the top layout's own
    /// label. The bottom keeps its wording: the user asked about the sides, and leaving it alone retires no key
    /// from every localisation table.
    var compactStyleTitle: String {
        switch self {
        case .top: L("Beside the notch")
        case .left, .right: L("In the side notch")
        case .bottom: L("In the pill")
        }
    }
}

/// What each tool shows while the panel is closed: its rings, the rings with its percentages, or the digits alone.
enum CompactStyle: String, CaseIterable, Codable {
    case rings, ringsAndNumbers, numbers

    var title: String {
        switch self {
        case .rings: L("Rings")
        case .ringsAndNumbers: L("Rings + numbers")
        case .numbers: L("Numbers")
        }
    }

    var showsRings: Bool { self != .numbers }
    var showsNumbers: Bool { self != .rings }
}

/// Which display carries the panel: the built-in one with the notch, the main (menu bar) display, the one under the
/// pointer, every display at once, the displays switched on one by one (`selected`, Preferences.displaySwitches),
/// or one named by its identity key (DisplayIdentity; an older preference holds the localizedName and still
/// matches on it).
enum DisplayChoice: Hashable, Codable {
    case builtIn, main, pointer, all, selected, named(String)

    static let fixed: [DisplayChoice] = [.builtIn, .main, .pointer, .all, .selected]

    var title: String {
        switch self {
        case .builtIn: L("Built-in display")
        case .main: L("Main display (the one with the menu bar)")
        case .pointer: L("Display with the pointer")
        case .all: L("All displays")
        case .selected: L("Chosen displays")
        case .named(let name): name
        }
    }

    var rawValue: String {
        switch self {
        case .builtIn: "builtIn"
        case .main: "main"
        case .pointer: "pointer"
        case .all: "all"
        case .selected: "selected"
        case .named(let name): "named:\(name)"
        }
    }

    init?(rawValue: String) {
        switch rawValue {
        case "builtIn": self = .builtIn
        case "main": self = .main
        case "pointer": self = .pointer
        case "all": self = .all
        case "selected": self = .selected
        default:
            guard rawValue.hasPrefix("named:"), rawValue.count > 6 else { return nil }
            self = .named(String(rawValue.dropFirst(6)))
        }
    }
}

/// How much room the open panel gives each card.
enum Density: String, CaseIterable, Codable {
    case comfortable, compact

    var title: String {
        switch self {
        case .comfortable: L("Comfortable")
        case .compact: L("Compact")
        }
    }

    var cardPadding: CGFloat { self == .compact ? 9 : 12 }
    /// The panel's vertical rhythm, from the widest gap to the narrowest: between one card and the next, between
    /// the rows inside a card, and between the lines inside a row. Three gaps and no others, so a row and a whole
    /// card are never separated by the same distance.
    var cardSpacing: CGFloat { self == .compact ? 7 : 10 }
    var rowSpacing: CGFloat { self == .compact ? 8 : 12 }
    var lineSpacing: CGFloat { self == .compact ? 4 : 5 }
    var costRing: CGFloat { self == .compact ? 72 : 92 }
}

/// How the open panel is laid out. Simple is one sheet with a row per assistant, the cost and the sessions, each
/// row carrying one figure and opening in place onto the detail (SimplePanel.swift); Detailed is the card per
/// assistant the panel was until 0.8.0. Simple is the default for new installs and for everyone who never chose,
/// because the panel is read at a glance and one figure a row is what a glance takes in.
enum PanelMode: String, CaseIterable, Codable {
    case simple, detailed

    var title: String {
        switch self {
        case .simple: L("Simple")
        case .detailed: L("Detailed")
        }
    }
}

/// What a Sessions card row leads with (SessionsCard.line): the conversation's own title, with the project, branch
/// and terminal under it, or the project, with the title under it. Title is the default because it is what the
/// row has led with since 0.7.0 and what tells two sessions of one project apart; project suits a reader who
/// keeps one conversation per repository and finds the work by where it runs.
enum SessionRowLead: String, CaseIterable, Codable {
    case title, project

    var title: String {
        switch self {
        case .title: L("Conversation title")
        case .project: L("Project name")
        }
    }
}

enum PanelWidth: String, CaseIterable, Codable {
    case standard, wide

    var title: String {
        switch self {
        case .standard: L("Standard")
        case .wide: L("Wide")
        }
    }

    var points: CGFloat { self == .wide ? 460 : 380 }
}

/// What the notch does when an assistant waits for the user or a turn ends: nothing beyond the dot and the
/// notification, a glance, or the panel opening. A glance is the session's own card (NoticeCard), settling by
/// itself. Until 0.7.5 it was the whole panel for a few seconds, and 0.7.4 added the card as a fourth choice
/// beside it; the whole panel crossing the screen for a finished turn was the thing nobody wanted, so the glance
/// became the card and the fourth choice folded into it (`stored(_:)` reads a stored "card" as `.glance`).
enum SessionAttention: String, CaseIterable, Codable {
    case nothing, glance, openPanel

    var title: String {
        switch self {
        case .nothing: L("Do nothing")
        case .glance: L("Glance (a card for a few seconds)")
        case .openPanel: L("Open the panel")
        }
    }

    /// The stored value, with 0.7.4's "card" read as the glance it became.
    static func stored(_ raw: String?) -> SessionAttention {
        raw == "card" ? .glance : SessionAttention(rawValue: raw ?? "") ?? .nothing
    }
}

/// The menu bar pin's shape: the figures as text, or up to four mini bars in one template glyph.
/// What colours the drawn menu bar icon. Pace is the app's own vocabulary — the same amber and vermillion the
/// rings and the pace notes use — and it is the default because it is the only one that says anything on its own.
/// Monochrome is for a menu bar that is otherwise all one colour, and it stays a template image, so macOS paints
/// it the way it paints every other icon there, inverted highlight included. Custom is a colour of one's own; the
/// fraction still reads, the warning no longer does.
enum MenuBarTint: String, CaseIterable, Codable {
    case pace, monochrome, custom

    var title: String {
        switch self {
        case .pace: L("By pace")
        case .monochrome: L("Monochrome")
        case .custom: L("Custom colour")
        }
    }
}

/// A colour as it is kept in the preferences: six hex digits, no alpha. Anything unreadable is the label colour,
/// which is what the icon draws in when nothing has been chosen.
enum HexColour {
    static func colour(_ hex: String) -> NSColor {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")).uppercased()
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return .labelColor }
        return NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                       blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    static func hex(_ colour: NSColor) -> String {
        guard let rgb = colour.usingColorSpace(.sRGB) else { return "FFFFFF" }
        let byte = { (component: CGFloat) in UInt32((max(0, min(1, component)) * 255).rounded()) }
        return String(format: "%02X%02X%02X", byte(rgb.redComponent), byte(rgb.greenComponent), byte(rgb.blueComponent))
    }
}

enum MenuBarStyle: String, CaseIterable, Codable {
    case text, bars, rings, dots

    var title: String {
        switch self {
        case .text: L("Text")
        case .bars: L("Bars")
        case .rings: L("Rings")
        case .dots: L("Dots")
        }
    }
}

/// The Cost card's unit: dollars, tokens, or dollars per million tokens (cache reads included).
enum CostCardMode: String, CaseIterable, Codable {
    case cost, tokens, perMillionTokens

    var title: String {
        switch self {
        case .cost: L("Cost")
        case .tokens: L("Tokens")
        case .perMillionTokens: L("$/MTok")
        }
    }

    var next: CostCardMode {
        switch self {
        case .cost: .tokens
        case .tokens: .perMillionTokens
        case .perMillionTokens: .cost
        }
    }
}

/// A key combination for a global shortcut: a Carbon virtual key code and Carbon modifier flags.
struct Hotkey: Equatable, Codable, Sendable {
    let keyCode: UInt32
    let modifiers: UInt32

    static let commandKey: UInt32 = 1 << 8
    static let shiftKey: UInt32 = 1 << 9
    static let optionKey: UInt32 = 1 << 11
    static let controlKey: UInt32 = 1 << 12

    /// "⌃⌥⇧⌘N" in the order the menu bar draws them.
    var description: String {
        var text = ""
        if modifiers & Self.controlKey != 0 { text += "⌃" }
        if modifiers & Self.optionKey != 0 { text += "⌥" }
        if modifiers & Self.shiftKey != 0 { text += "⇧" }
        if modifiers & Self.commandKey != 0 { text += "⌘" }
        return text + KeyNames.name(for: keyCode)
    }
}

/// The reminder before a window resets: off, ten minutes or an hour ahead.
enum ResetReminder: String, CaseIterable, Codable {
    case off, tenMinutes, oneHour

    var title: String {
        switch self {
        case .off: L("Off")
        case .tenMinutes: L("10 minutes before")
        case .oneHour: L("1 hour before")
        }
    }

    var lead: TimeInterval? {
        switch self {
        case .off: nil
        case .tenMinutes: 600
        case .oneHour: 3600
        }
    }
}

enum ToolOrder {
    /// A stored order with names that are no tool dropped, repeats removed, and every tool it leaves out appended
    /// in default order, so a tool added in a later version appears without a reset.
    static func normalize(_ stored: [String]?) -> [ToolID] {
        var order: [ToolID] = []
        for name in stored ?? [] {
            if let tool = ToolID(rawValue: name), !order.contains(tool) { order.append(tool) }
        }
        order.append(contentsOf: ToolID.allCases.filter { !order.contains($0) })
        return order
    }
}

/// Brings the per-tool preferences an earlier build wrote up to the tools this build knows, once per tool, before
/// Preferences reads them.
///
/// Two things need it. A stored `enabledTools` names every tool that was on when it was written, so a tool added in
/// a later version was read as switched off for anyone who had ever ticked a box, where a user who never had came to
/// it switched on; a new tool now starts switched on for both. And 0.9.0 split the one Antigravity row into Gemini
/// CLI's and Antigravity's, so the new Gemini CLI row inherits everything the combined row had — switched on or off,
/// its place in the order (just before Antigravity, where a new install has it), its pin beside the menu bar, peak
/// hours, its ring and Hide choices, whether its Settings row was open — and a user whose one row was Gemini CLI's
/// all along finds it as they left it. Antigravity keeps its own settings as they were.
///
/// `knownTools` records which tools the stored preferences have been brought up to, so each tool is migrated
/// exactly once and a later choice to switch it off is never undone. Without it the stored preferences predate 0.9.0
/// and were written against the five tools every build before then shipped.
enum ToolMigration {
    static let knownToolsKey = "knownTools"
    /// The tools every build before 0.9.0 knew.
    static let before090 = ["claude", "codex", "cursor", "antigravity", "copilot"]
    /// A new tool that takes over part of an older one's row, with the row whose settings it starts from.
    static let inherits: [ToolID: ToolID] = [.gemini: .antigravity]

    /// The keys that name tools: sets stored as arrays, and dictionaries keyed by tool. `costCardTools` is one
    /// of them: 0.8.0 stored it, so a user whose only per-tool choice was a Cost card tick would otherwise read
    /// as a first launch, be recorded as knowing every tool, and never have OpenCode's spend join the card.
    /// It is never inherited, since a tool that reports no cost is never in it.
    static let setKeys = ["enabledTools", "menuBarPinnedTools", "peakHoursTools", "settingsExpandedTools", "costCardTools",
                          "sessionReadingOffTools", "answerFromNotchOffTools", "limitNoticesOffTools", "sessionNoticesOffTools"]
    static let dictionaryKeys = ["ringWindows", "hiddenWindows", "revealedWindows"]

    struct Outcome: Equatable {
        /// Tools this run met for the first time.
        var added: [ToolID] = []
        /// Of those, the ones that took another tool's settings, by the tool they took them from.
        var inherited: [ToolID: ToolID] = [:]
    }

    /// Migrates `defaults` in place and records every tool as known. A first launch, with nothing stored, only
    /// records; a run with nothing new is a no-op.
    @discardableResult
    static func migrate(_ defaults: UserDefaults) -> Outcome {
        let current = ToolID.allCases.map(\.rawValue)
        let stored = defaults.stringArray(forKey: knownToolsKey)
        // Nothing recorded and no tool named anywhere: a first launch (or one that never changed a tool setting),
        // whose defaults already cover every tool. An empty list counts as nothing, since that is also what a
        // registered default looks like to a lookup that cannot tell the domains apart.
        let namesATool = (setKeys + ["toolOrder"]).contains { !(defaults.stringArray(forKey: $0) ?? []).isEmpty }
            || dictionaryKeys.contains { !(defaults.dictionary(forKey: $0) ?? [:]).isEmpty }
        let firstLaunch = stored == nil && !namesATool
        let known = firstLaunch ? current : stored ?? before090
        let added = ToolID.allCases.filter { !known.contains($0.rawValue) }
        var outcome = Outcome(added: added)
        guard !added.isEmpty else {
            if stored != current { defaults.set(current, forKey: knownToolsKey) }
            return outcome
        }
        for tool in added {
            let source = inherits[tool].flatMap { known.contains($0.rawValue) ? $0 : nil }
            if let source { outcome.inherited[tool] = source }
            if var enabled = defaults.stringArray(forKey: "enabledTools"), !enabled.contains(tool.rawValue) {
                // A tool of its own starts switched on, as it does for a user who never changed the set; one that
                // takes over part of another's row is on exactly when that row was.
                if source.map({ enabled.contains($0.rawValue) }) ?? true {
                    enabled.append(tool.rawValue)
                    defaults.set(enabled, forKey: "enabledTools")
                }
            }
            guard let source else { continue }
            if let order = defaults.stringArray(forKey: "toolOrder") {
                defaults.set(inserting(tool.rawValue, before: source.rawValue, in: order), forKey: "toolOrder")
            }
            for key in setKeys where key != "enabledTools" {
                guard var set = defaults.stringArray(forKey: key), set.contains(source.rawValue), !set.contains(tool.rawValue) else { continue }
                set.append(tool.rawValue)
                defaults.set(set, forKey: key)
            }
            for key in dictionaryKeys {
                guard var dictionary = defaults.dictionary(forKey: key), let value = dictionary[source.rawValue], dictionary[tool.rawValue] == nil else { continue }
                dictionary[tool.rawValue] = value
                defaults.set(dictionary, forKey: key)
            }
        }
        defaults.set(current, forKey: knownToolsKey)
        return outcome
    }

    /// `order` with `tool` placed just before `source`, or at the end when `source` is not in it; unchanged when
    /// `tool` is already there.
    static func inserting(_ tool: String, before source: String, in order: [String]) -> [String] {
        guard !order.contains(tool) else { return order }
        var result = order
        result.insert(tool, at: order.firstIndex(of: source) ?? order.count)
        return result
    }
}

/// What the Settings window follows, and with it the shape the readouts sit in wherever that shape is a capsule
/// floating on the desktop rather than a notch flush against the glass: the bottom bar, the top bar on a Mac with
/// no hardware notch, and a side edge a pinned Dock or Stage Manager's strip already holds. `EdgePanelRoot` sets
/// the root scheme from it; the notch layout is `NotchController`'s and reads it nowhere at all.
///
/// The open panel's contents do not follow it, in any layout: `NotchExpandedView` ends in an unconditional
/// `.foregroundStyle(.white)` and `.colorScheme(.dark)`. The notch layout's panel has to be black to read as one
/// shape with the physical notch, and the edge card is the same view rather than a second one, so both are white
/// on dark whatever is chosen. A notch cut into a side edge forces dark inside its own shape for the sister
/// reason — it is claiming to be screen the Mac does not have, and screen the Mac does not have is dark.
///
/// Until 0.7.5 one combination reached only halfway: from macOS 26 the edge card's surface was `glassEffect`
/// applied outside the content's forced-dark environment, so under Light it put that white text over light glass
/// in every edge layout. Seen on a macOS 26 screen (2026-09-21), the card's glass is now dark whatever is chosen
/// (EdgePanelCard); the pill still follows this setting.
enum AppearanceChoice: String, CaseIterable, Codable {
    case system, light, dark

    var title: String {
        switch self {
        case .system: L("Match system")
        case .light: L("Light")
        case .dark: L("Dark")
        }
    }

    /// nil follows the system. The panel's contents never read it — they are white on dark in every layout — and
    /// nor does a flush side notch. On macOS 26 the glass surface under the edge card does, which is the
    /// white-text-on-light-glass case this type's doc names.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// Which side of the physical notch the readouts sit on. macOS puts the frontmost app's menu titles immediately
/// left of the notch, so the right side is normally the free one; `split` is the old behaviour.
enum CompactSide: String, CaseIterable, Codable {
    case trailing, leading, split, auto

    var title: String {
        switch self {
        case .trailing: L("Right of the notch")
        case .leading: L("Left of the notch")
        case .split: L("Both sides")
        case .auto: L("Auto")
        }
    }

    /// Auto's rule lives in CompactFit, which answers with a whole fit — side, style and how many tools — rather
    /// than a side alone, because the menu bar squeezes from both ends; what it sheds first is `compactKeep`.
}

/// What Readouts › Auto gives up first once neither end of the menu bar has room for the strip (CompactFit.steps):
/// the figures, a level at a time, before any assistant is left out; or the assistants the user put last, before
/// any figure is thinned. Tools is the default because it is what the strip has always done, and because an
/// assistant that is left out takes its state with it — a waiting mark, a limit reached — which nothing else in
/// the strip carries, while a thinned figure is still a figure. A fixed side never gives anything up, so this
/// reaches nothing but Auto.
enum CompactKeep: String, CaseIterable, Codable {
    case tools, numbers

    var title: String {
        switch self {
        case .tools: L("Keep the tools")
        case .numbers: L("Keep the numbers")
        }
    }
}

/// A second read a provider makes only because the user asked for it.
///
/// The switch is read from UserDefaults at the moment the provider fetches, never handed to it when it is built:
/// a provider constructed anywhere in the app follows the setting, and a construction that forgets to wire one up
/// cannot silently disable the read. Cursor's usage export was off for every install for exactly that reason.
enum ProviderOptIn: String, CaseIterable, Sendable {
    case codexResetCredits, cursorUsageEvents, copilotOrgBilling

    /// The defaults key, which is the case's own name; Preferences.Keys reads it from here.
    var key: String { rawValue }

    /// Cursor's export comes from the account the usage summary already reads, so it is on unless switched off;
    /// the other two reach endpoints of their own and stay off until asked for.
    var whenUnset: Bool { self == .cursorUsageEvents }

    func value(_ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: key) as? Bool ?? whenUnset
    }

    /// The live read a provider actor holds. UserDefaults is thread-safe and nothing is captured but the key.
    func reader(_ defaults: UserDefaults = .standard) -> @Sendable () -> Bool {
        nonisolated(unsafe) let defaults = defaults
        return { self.value(defaults) }
    }
}

@MainActor
@Observable
final class Preferences {
    @ObservationIgnored private let defaults: UserDefaults

    var enabledTools: Set<ToolID> {
        didSet {
            defaults.set(enabledTools.map(\.rawValue).sorted(), forKey: Keys.enabledTools)
            report(Keys.enabledTools, enabledTools.map(\.rawValue).sorted(), changed: enabledTools != oldValue)
        }
    }
    /// The assistants' order everywhere: the panel's cards, the rings beside the notch (the first on its left, the
    /// rest on its right), the edge pills, and the Advisor's tie-breaks.
    var toolOrder: [ToolID] {
        didSet {
            defaults.set(toolOrder.map(\.rawValue), forKey: Keys.toolOrder)
            report("toolOrder", toolOrder.map(\.rawValue), changed: toolOrder != oldValue, event: "order")
        }
    }
    /// Which assistants' pages in Settings have *Where each window comes from* open; empty, so every one starts
    /// folded. Before each assistant had a page it held which assistants had their options unfolded in the
    /// Assistants list, under the same key, so a choice made then opens the nearest thing to it now.
    var settingsExpandedTools: Set<ToolID> {
        didSet {
            defaults.set(settingsExpandedTools.map(\.rawValue).sorted(), forKey: Keys.settingsExpanded)
            report(Keys.settingsExpanded, settingsExpandedTools.map(\.rawValue).sorted(), changed: settingsExpandedTools != oldValue)
        }
    }
    var visibility: NotchVisibility {
        didSet { defaults.set(visibility.rawValue, forKey: Keys.visibility); report(Keys.visibility, visibility.rawValue, changed: visibility != oldValue) }
    }
    /// How long the pointer rests on the rings before the panel opens, 0.1 to 1 s.
    var hoverDelay: TimeInterval {
        didSet {
            // Same shape as finishedAfterMinutes below: the rounding writes back only when it changes the value,
            // because under @Observable the write re-enters this observer, and an unconditional one never returns.
            let settled = min(1, max(0.1, (hoverDelay * 20).rounded() / 20))
            if settled != hoverDelay { hoverDelay = settled; return }
            defaults.set(hoverDelay, forKey: Keys.hoverDelay)
            report(Keys.hoverDelay, hoverDelay, changed: hoverDelay != oldValue)
        }
    }
    var edge: PanelEdge {
        didSet { defaults.set(edge.rawValue, forKey: Keys.edge); report("edge", edge.rawValue, changed: edge != oldValue, event: "layout") }
    }
    var display: DisplayChoice {
        didSet { defaults.set(display.rawValue, forKey: Keys.display); report(Keys.display, display.rawValue, changed: display != oldValue) }
    }
    /// Under `DisplayChoice.selected`, the switch per display, keyed by its identity (DisplayIdentity) so a switch
    /// survives the display being unplugged and plugged back in. Only a switch the user turned is written; a display
    /// with none follows `DisplaySwitches.isOn`'s default, so a new display arrives on if it has a notch.
    var displaySwitches: [String: Bool] {
        didSet {
            defaults.set(displaySwitches, forKey: Keys.displaySwitches)
            report(Keys.displaySwitches, displaySwitches.map { "\($0.key):\($0.value)" }.sorted(), changed: displaySwitches != oldValue)
        }
    }
    var showOverFullScreenApps: Bool {
        didSet { defaults.set(showOverFullScreenApps, forKey: Keys.fullScreen); report(Keys.fullScreen, showOverFullScreenApps, changed: showOverFullScreenApps != oldValue) }
    }
    var compactStyle: CompactStyle {
        didSet {
            defaults.set(compactStyle.rawValue, forKey: Keys.compactStyle)
            report("compactStyle", compactStyle.rawValue, changed: compactStyle != oldValue, event: "compactStyle")
        }
    }
    /// "90% · 32m": the main window's reset countdown after its figure, in the styles that show numbers.
    var showResetCountdown: Bool {
        didSet { defaults.set(showResetCountdown, forKey: Keys.resetCountdown); report(Keys.resetCountdown, showResetCountdown, changed: showResetCountdown != oldValue) }
    }
    /// At plain rings, the outer ring's window as a figure beside the nest (CompactLabel.figures): the one number
    /// most people open the panel for, without giving up the rings for the digits style. On by default; the quiet
    /// dimming stays on the rings and leaves the figure legible.
    var compactPrimary: Bool {
        didSet { defaults.set(compactPrimary, forKey: Keys.compactPrimary); report(Keys.compactPrimary, compactPrimary, changed: compactPrimary != oldValue) }
    }
    /// Each assistant's symbol (ToolID.symbolName, the one on its card) drawn small in the middle of its rings, for
    /// a reader who cannot tell the identity colours apart: position in the strip says which tool a ring is only
    /// to someone who remembers the order. Off by default, since at this size it is a mark to learn, not a label.
    var ringSymbols: Bool {
        didSet { defaults.set(ringSymbols, forKey: Keys.ringSymbols); report(Keys.ringSymbols, ringSymbols, changed: ringSymbols != oldValue) }
    }
    /// What the closed notch shows while an assistant is working, waiting for the user or has just finished
    /// (ClosedNotch), and what it shows when nothing is running. Both are the readouts by default, which is the
    /// strip as it has always been; the notch layout reads them, and the edges and the pill keep their readouts.
    var closedWhileWorking: ClosedNotchMode {
        didSet { defaults.set(closedWhileWorking.rawValue, forKey: Keys.closedWhileWorking); report(Keys.closedWhileWorking, closedWhileWorking.rawValue, changed: closedWhileWorking != oldValue) }
    }
    var closedWhenQuiet: ClosedNotchMode {
        didSet { defaults.set(closedWhenQuiet.rawValue, forKey: Keys.closedWhenQuiet); report(Keys.closedWhenQuiet, closedWhenQuiet.rawValue, changed: closedWhenQuiet != oldValue) }
    }
    /// An assistant that is switched on and installed but has nothing to show — no reading, no spend, no session —
    /// stays off the panel and the strip until it has (UsageStore.visibleTools). The last visible one is never hidden.
    var hideEmptyTools: Bool {
        didSet { defaults.set(hideEmptyTools, forKey: Keys.hideEmptyTools); report(Keys.hideEmptyTools, hideEmptyTools, changed: hideEmptyTools != oldValue) }
    }
    /// Secondary figures (session block, tokens, cache writes, top projects, Cursor spend, the sparklines).
    /// Off by default so the panel fits the screen without scrolling.
    var showDetails: Bool {
        didSet { defaults.set(showDetails, forKey: Keys.showDetails); report(Keys.showDetails, showDetails, changed: showDetails != oldValue) }
    }

    var appearance: AppearanceChoice {
        didSet { defaults.set(appearance.rawValue, forKey: Keys.appearance); report(Keys.appearance, appearance.rawValue, changed: appearance != oldValue) }
    }
    /// The open panel's face (PanelTheme): Black, the panel as it has always been, or Paper. Settings › Appearance ›
    /// Theme; nothing outside the open panel follows it.
    var panelTheme: PanelTheme {
        didSet { defaults.set(panelTheme.rawValue, forKey: Keys.panelTheme); report(Keys.panelTheme, panelTheme.rawValue, changed: panelTheme != oldValue) }
    }
    /// How much of the desktop shows through the open panel (PanelMaterial). Nil until chosen: each layout then
    /// keeps what it has always drawn (`PanelMaterial.unchosen`), so an install that never opens the Theme section
    /// sees no change. Paper, Reduce Transparency and Increase Contrast draw it solid whatever it holds.
    var panelMaterial: PanelMaterial? {
        didSet {
            if let panelMaterial { defaults.set(panelMaterial.rawValue, forKey: Keys.panelMaterial) } else { defaults.removeObject(forKey: Keys.panelMaterial) }
            report(Keys.panelMaterial, panelMaterial?.rawValue as Any, changed: panelMaterial != oldValue)
        }
    }
    /// The app's own colour on the open panel (PanelAccent); terracotta, the icon's, unless chosen.
    var panelAccent: PanelAccent {
        didSet { defaults.set(panelAccent.rawValue, forKey: Keys.panelAccent); report(Keys.panelAccent, panelAccent.rawValue, changed: panelAccent != oldValue) }
    }
    /// Meters or nested dials on the Simple rows and the cards (UsageStyle); meters, the panel as it was, unless chosen.
    var usageStyle: UsageStyle {
        didSet { defaults.set(usageStyle.rawValue, forKey: Keys.usageStyle); report(Keys.usageStyle, usageStyle.rawValue, changed: usageStyle != oldValue) }
    }
    /// A small clock beside the reset of a window measured in hours (HourClock). Off by default: it is a picture of
    /// a figure the reset line already states, for a reader who takes in a clock faster than a countdown.
    var hourClock: Bool {
        didSet { defaults.set(hourClock, forKey: Keys.hourClock); report(Keys.hourClock, hourClock, changed: hourClock != oldValue) }
    }

    var compactSide: CompactSide {
        didSet {
            defaults.set(compactSide.rawValue, forKey: Keys.compactSide)
            report(Keys.compactSide, compactSide.rawValue, changed: compactSide != oldValue)
        }
    }
    /// What Auto sheds first when crowded (CompactKeep). AutoSideWatcher observes it and re-fits on a change.
    var compactKeep: CompactKeep {
        didSet {
            defaults.set(compactKeep.rawValue, forKey: Keys.compactKeep)
            report(Keys.compactKeep, compactKeep.rawValue, changed: compactKeep != oldValue)
        }
    }
    /// What Auto has made of the menu bar (AutoSideWatcher); nil until it has looked.
    var autoCompactFit: CompactFit?
    /// The room Auto last measured either side of the notch (AutoSideWatcher), which a news peek (NotchPeek) is
    /// laid out in; nil until it has looked. Not saved, like the fit beside it.
    var autoCompactRoom: NotchPeek.Room?
    /// The room a peek may take: what Auto measured, or nothing measured under a fixed side, where the readouts
    /// themselves are drawn without a measurement either.
    var peekRoom: NotchPeek.Room {
        compactSide == .auto ? autoCompactRoom ?? .unmeasured : .unmeasured
    }
    /// The fit the readouts are actually drawn at. A fixed side keeps every tool at the chosen style; Auto uses
    /// what it last measured, and until it has measured anything it sits centred on the notch — the arrangement
    /// it returns to whenever there is room, so the strip starts where it spends most of its life.
    var compactFit: CompactFit {
        guard compactSide == .auto else { return .whole(side: compactSide, style: compactStyle) }
        return autoCompactFit ?? .whole(side: .split, style: compactStyle)
    }
    /// The side the readouts are actually drawn on. Never `.auto`.
    var resolvedCompactSide: CompactSide { compactFit.side }

    var showSpend: Bool {
        didSet { defaults.set(showSpend, forKey: Keys.showSpend); report(Keys.showSpend, showSpend, changed: showSpend != oldValue) }
    }
    /// Which assistants the Cost card carries: its donut, its legend and the total in the middle. Every one that
    /// can report spend by default, and a stored name that cannot is dropped on load — a tool with no figure to
    /// carry has no `ProviderCost` and so could never be a row anyway. The card as a whole is hidden by Show
    /// total spend, not by this.
    var costCardTools: Set<ToolID> {
        didSet {
            defaults.set(costCardTools.map(\.rawValue).sorted(), forKey: Keys.costCardTools)
            report(Keys.costCardTools, costCardTools.map(\.rawValue).sorted(), changed: costCardTools != oldValue)
        }
    }
    var usageDisplay: UsageDisplay {
        didSet { defaults.set(usageDisplay.rawValue, forKey: Keys.usageDisplay); report(Keys.usageDisplay, usageDisplay.rawValue, changed: usageDisplay != oldValue) }
    }
    var resetDisplay: ResetDisplay {
        didSet { defaults.set(resetDisplay.rawValue, forKey: Keys.resetDisplay); report(Keys.resetDisplay, resetDisplay.rawValue, changed: resetDisplay != oldValue) }
    }
    var timeFormat: TimeFormatPreference {
        didSet { defaults.set(timeFormat.rawValue, forKey: Keys.timeFormat); report(Keys.timeFormat, timeFormat.rawValue, changed: timeFormat != oldValue) }
    }
    var density: Density {
        didSet { defaults.set(density.rawValue, forKey: Keys.density); report(Keys.density, density.rawValue, changed: density != oldValue) }
    }
    var panelMode: PanelMode {
        didSet { defaults.set(panelMode.rawValue, forKey: Keys.panelMode); report(Keys.panelMode, panelMode.rawValue, changed: panelMode != oldValue) }
    }
    var panelWidth: PanelWidth {
        didSet { defaults.set(panelWidth.rawValue, forKey: Keys.panelWidth); report(Keys.panelWidth, panelWidth.rawValue, changed: panelWidth != oldValue) }
    }
    /// Swipe down over the rings opens, swipe up over the panel closes, with a haptic tick on each transition.
    var gesturesEnabled: Bool {
        didSet { defaults.set(gesturesEnabled, forKey: Keys.gestures); report(Keys.gestures, gesturesEnabled, changed: gesturesEnabled != oldValue) }
    }
    /// OR-ed with the system's Reduce Motion wherever motion is decided.
    var reduceAnimations: Bool {
        didSet { defaults.set(reduceAnimations, forKey: Keys.reduceAnimations); report(Keys.reduceAnimations, reduceAnimations, changed: reduceAnimations != oldValue) }
    }
    /// Nil follows the default: off on a Mac whose panel can be shown beside a notch, on when it cannot.
    var showMenuBarItem: Bool? {
        didSet {
            if let showMenuBarItem { defaults.set(showMenuBarItem, forKey: Keys.menuBarItem) } else { defaults.removeObject(forKey: Keys.menuBarItem) }
            report(Keys.menuBarItem, showMenuBarItem as Any, changed: showMenuBarItem != oldValue)
        }
    }
    /// The pinned tools' two main figures beside the menu bar icon.
    var menuBarPin: Bool {
        didSet { defaults.set(menuBarPin, forKey: Keys.menuBarPin); report(Keys.menuBarPin, menuBarPin, changed: menuBarPin != oldValue) }
    }
    /// Which tools the pin shows; empty means the first visible tool.
    var menuBarPinnedTools: Set<ToolID> {
        didSet {
            defaults.set(menuBarPinnedTools.map(\.rawValue).sorted(), forKey: Keys.menuBarPinnedTools)
            report(Keys.menuBarPinnedTools, menuBarPinnedTools.map(\.rawValue).sorted(), changed: menuBarPinnedTools != oldValue)
        }
    }
    var menuBarStyle: MenuBarStyle {
        didSet { defaults.set(menuBarStyle.rawValue, forKey: Keys.menuBarStyle); report(Keys.menuBarStyle, menuBarStyle.rawValue, changed: menuBarStyle != oldValue) }
    }
    /// What colours the drawn icon: the pace, the menu bar's own colour, or one chosen below.
    var menuBarTint: MenuBarTint {
        didSet { defaults.set(menuBarTint.rawValue, forKey: Keys.menuBarTint); report(Keys.menuBarTint, menuBarTint.rawValue, changed: menuBarTint != oldValue) }
    }
    /// The colour `MenuBarTint.custom` draws in, six hex digits.
    var menuBarTintHex: String {
        didSet { defaults.set(menuBarTintHex, forKey: Keys.menuBarTintHex); report(Keys.menuBarTintHex, menuBarTintHex, changed: menuBarTintHex != oldValue) }
    }
    /// While the screen is captured, the rings lose their digits and the panel its Cost card.
    var hideFromScreenShare: Bool {
        didSet { defaults.set(hideFromScreenShare, forKey: Keys.screenShare); report(Keys.screenShare, hideFromScreenShare, changed: hideFromScreenShare != oldValue) }
    }
    /// ISO 4217 code and the user's own rate from a dollar. Nothing is fetched unless `fetchCurrencyRate` is on.
    var currencyCode: String {
        didSet { defaults.set(currencyCode, forKey: Keys.currencyCode); report(Keys.currencyCode, currencyCode, changed: currencyCode != oldValue); applyCurrency() }
    }
    var currencyRate: Double {
        didSet { defaults.set(currencyRate, forKey: Keys.currencyRate); report(Keys.currencyRate, currencyRate, changed: currencyRate != oldValue); applyCurrency() }
    }
    /// Converts at the ECB's reference rate, fetched once a day (ReferenceRateFetcher), instead of the typed one.
    /// Off by default: the typed rate and no request at all is how the app has always converted, and a request
    /// the user did not ask for is one the privacy page would have to explain away.
    var fetchCurrencyRate: Bool {
        didSet { defaults.set(fetchCurrencyRate, forKey: Keys.fetchCurrencyRate); report(Keys.fetchCurrencyRate, fetchCurrencyRate, changed: fetchCurrencyRate != oldValue); applyCurrency() }
    }
    /// The rate `Money` converts at and where it came from, resolved from the three settings above and the cached
    /// rates. Not a preference: derived, never written, and re-resolved whenever one of its inputs moves.
    private(set) var currencyConversion: CurrencyConversion
    /// The last ECB rates read and when a request was last made, kept in these defaults beside the switch.
    private(set) var referenceRateCache: ReferenceRateCache
    /// The spend budgets for the calendar month and the week, each as it was typed: an amount in the currency
    /// shown then, at the rate then in use (`Budget`), so the figure typed is the figure shown back whatever the
    /// day's rate does. What the spend is measured against is the dollar figure, `monthlyBudgetUSD` and
    /// `weeklyBudgetUSD`, derived at the rate in use.
    var monthlyBudget: Budget? {
        didSet { storeCodable(monthlyBudget, forKey: Keys.monthlyBudget); report(Keys.monthlyBudget, monthlyBudget?.oracleFields as Any, changed: monthlyBudget != oldValue) }
    }
    var weeklyBudget: Budget? {
        didSet { storeCodable(weeklyBudget, forKey: Keys.weeklyBudget); report(Keys.weeklyBudget, weeklyBudget?.oracleFields as Any, changed: weeklyBudget != oldValue) }
    }
    var monthlyBudgetUSD: Double? { monthlyBudget?.usd(at: currencyConversion) }
    var weeklyBudgetUSD: Double? { weeklyBudget?.usd(at: currencyConversion) }
    var costCardMode: CostCardMode {
        didSet { defaults.set(costCardMode.rawValue, forKey: Keys.costCardMode); report(Keys.costCardMode, costCardMode.rawValue, changed: costCardMode != oldValue) }
    }
    /// Per tool, the ids of the windows the outer and inner rings show; empty means the reading's first two.
    var ringWindows: [ToolID: [String]] {
        didSet {
            defaults.set(ringWindows.reduce(into: [String: [String]]()) { $0[$1.key.rawValue] = $1.value }, forKey: Keys.ringWindows)
            report(Keys.ringWindows, ringWindows.map { "\($0.key.rawValue):\($0.value.joined(separator: ","))" }.sorted(), changed: ringWindows != oldValue)
        }
    }
    /// Per tool, the window ids left out of the card and the rings.
    var hiddenWindows: [ToolID: Set<String>] {
        didSet {
            defaults.set(hiddenWindows.reduce(into: [String: [String]]()) { $0[$1.key.rawValue] = $1.value.sorted() }, forKey: Keys.hiddenWindows)
            report(Keys.hiddenWindows, hiddenWindows.map { "\($0.key.rawValue):\($0.value.sorted().joined(separator: ","))" }.sorted(), changed: hiddenWindows != oldValue)
        }
    }
    /// Per tool, the window ids the user revealed although they are hidden by default (LimitWindow.hiddenByDefault).
    var revealedWindows: [ToolID: Set<String>] {
        didSet {
            defaults.set(revealedWindows.reduce(into: [String: [String]]()) { $0[$1.key.rawValue] = $1.value.sorted() }, forKey: Keys.revealedWindows)
            report(Keys.revealedWindows, revealedWindows.map { "\($0.key.rawValue):\($0.value.sorted().joined(separator: ","))" }.sorted(), changed: revealedWindows != oldValue)
        }
    }
    /// Pace-crossing notifications (NotificationScheduler.swift); on by default, asked for on first use.
    var notificationsEnabled: Bool {
        didSet {
            defaults.set(notificationsEnabled, forKey: Keys.notificationsEnabled)
            report(Keys.notificationsEnabled, notificationsEnabled, changed: notificationsEnabled != oldValue)
        }
    }
    var notifyOnTrack: Bool {
        didSet { defaults.set(notifyOnTrack, forKey: Keys.notifyOnTrack); report(Keys.notifyOnTrack, notifyOnTrack, changed: notifyOnTrack != oldValue) }
    }
    var notifyBehind: Bool {
        didSet { defaults.set(notifyBehind, forKey: Keys.notifyBehind); report(Keys.notifyBehind, notifyBehind, changed: notifyBehind != oldValue) }
    }
    var notifyRunningOut: Bool {
        didSet { defaults.set(notifyRunningOut, forKey: Keys.notifyRunningOut); report(Keys.notifyRunningOut, notifyRunningOut, changed: notifyRunningOut != oldValue) }
    }
    /// Once, when a window that was at least 80 % used or behind pace passes its reset.
    var notifyOnReset: Bool {
        didSet { defaults.set(notifyOnReset, forKey: Keys.notifyOnReset); report(Keys.notifyOnReset, notifyOnReset, changed: notifyOnReset != oldValue) }
    }
    var resetReminder: ResetReminder {
        didSet { defaults.set(resetReminder.rawValue, forKey: Keys.resetReminder); report(Keys.resetReminder, resetReminder.rawValue, changed: resetReminder != oldValue) }
    }
    var notifyWaiting: Bool {
        didSet { defaults.set(notifyWaiting, forKey: Keys.notifyWaiting); report(Keys.notifyWaiting, notifyWaiting, changed: notifyWaiting != oldValue) }
    }
    var notifyFinished: Bool {
        didSet { defaults.set(notifyFinished, forKey: Keys.notifyFinished); report(Keys.notifyFinished, notifyFinished, changed: notifyFinished != oldValue) }
    }
    /// A notice when a Claude Code session runs into something without stopping for it (SessionTrouble): it starts
    /// compacting its context by itself, `SessionTracker.stuckAfter` tool calls fail in a row, or auto mode refuses a
    /// tool for the first time in a turn. Off by default like the two above: the row and the word beside the notch
    /// say all three without a banner, which is the interruption this opts into.
    var notifySessionTrouble: Bool {
        didSet { defaults.set(notifySessionTrouble, forKey: Keys.notifySessionTrouble); report(Keys.notifySessionTrouble, notifySessionTrouble, changed: notifySessionTrouble != oldValue) }
    }
    /// Whether a terminal or editor in front holds a session notice back. On, because for the person with one
    /// terminal and one session it is right; off for the person whose session is in some other tab, where the
    /// app cannot tell the two apart without reading window titles, which it will not do (MenuBarExtent.swift).
    /// A wait the session has stopped for ignores this, but only once per session per ten minutes — see
    /// Notifier.shouldSuppress.
    var quietWhileTerminalFrontmost: Bool {
        didSet {
            defaults.set(quietWhileTerminalFrontmost, forKey: Keys.quietWhileTerminal)
            report(Keys.quietWhileTerminal, quietWhileTerminalFrontmost, changed: quietWhileTerminalFrontmost != oldValue)
        }
    }
    /// A turn that ran at least this long is worth a notification when it finishes.
    var finishedAfterMinutes: Int {
        didSet {
            // Written back only when the clamp changes it. This class is @Observable, so the assignment goes
            // through the generated setter and lands in this observer again; an unconditional write re-entered it
            // without end, and the stack overflowed on the first press of the stepper in Settings. The in-range
            // re-entry persists and reports the value, and this outer pass has nothing left to do.
            let clamped = min(60, max(1, finishedAfterMinutes))
            if clamped != finishedAfterMinutes { finishedAfterMinutes = clamped; return }
            defaults.set(finishedAfterMinutes, forKey: Keys.finishedAfter)
            report(Keys.finishedAfter, finishedAfterMinutes, changed: finishedAfterMinutes != oldValue)
        }
    }
    /// The first time extra-usage credits rise in a month, and louder when the plan still has room.
    var notifyExtraUsage: Bool {
        didSet { defaults.set(notifyExtraUsage, forKey: Keys.notifyExtraUsage); report(Keys.notifyExtraUsage, notifyExtraUsage, changed: notifyExtraUsage != oldValue) }
    }
    /// When today's cache writes moved to the 5-minute tier against the 30-day norm.
    var notifyCacheShift: Bool {
        didSet { defaults.set(notifyCacheShift, forKey: Keys.notifyCacheShift); report(Keys.notifyCacheShift, notifyCacheShift, changed: notifyCacheShift != oldValue) }
    }
    /// When Claude Code's prompt cache kept missing in the current session block (Advisor.promptCache), once a day.
    var notifyPromptCache: Bool {
        didSet { defaults.set(notifyPromptCache, forKey: Keys.notifyPromptCache); report(Keys.notifyPromptCache, notifyPromptCache, changed: notifyPromptCache != oldValue) }
    }
    /// What the notch itself does when an assistant waits or a long turn finishes.
    var sessionAttention: SessionAttention {
        didSet { defaults.set(sessionAttention.rawValue, forKey: Keys.sessionAttention); report(Keys.sessionAttention, sessionAttention.rawValue, changed: sessionAttention != oldValue) }
    }
    /// Whether the compact rings take the state colour while an assistant waits or has just finished (ToolSignal).
    /// On by default: the strip has no other channel for something the user has to act on, and a ring in a tool's
    /// own colour cannot say that its agent has stopped. Off, the rings keep their identity colour and every mark
    /// stays where it was — the waiting dot the hook has always drawn and the tick beside it — so the setting
    /// withdraws the colour and not the fact, which is what `SessionAttention.nothing` already means by off.
    /// Deliberately not tied to the two notification settings above: those decide whether a banner interrupts the
    /// reader, and a banner and a colour beside the notch are not the same imposition.
    var signalRings: Bool {
        didSet { defaults.set(signalRings, forKey: Keys.signalRings); report(Keys.signalRings, signalRings, changed: signalRings != oldValue) }
    }
    /// The collapsed strip names the session and the reason for a few seconds when one starts waiting or finishes
    /// a turn (NotchNews): the rings say that something happened, and this says where and what, without opening
    /// the panel. On by default for the reason `signalRings` is: the strip has no other channel for it. Not tied to
    /// the notification settings either — a banner interrupts, a few words beside the notch do not.
    var notchNews: Bool {
        didSet { defaults.set(notchNews, forKey: Keys.notchNews); report(Keys.notchNews, notchNews, changed: notchNews != oldValue) }
    }
    /// A soft light under the notch for the same news (NotchGlow): blue for a wait, white for a finish, fading after
    /// a few seconds, with a faint blue kept while anything still waits. Separate from `notchNews` because the two
    /// cost different things: the words cover the menu bar for four seconds, the light covers nothing.
    var notchGlow: Bool {
        didSet { defaults.set(notchGlow, forKey: Keys.notchGlow); report(Keys.notchGlow, notchGlow, changed: notchGlow != oldValue) }
    }
    /// Every notification sound at once: off, nothing plays whatever the six rows below it say.
    var notificationSound: Bool {
        didSet { defaults.set(notificationSound, forKey: Keys.notificationSound); report(Keys.notificationSound, notificationSound, changed: notificationSound != oldValue) }
    }
    /// The sound each category (SoundCategory) plays when it is not silenced, as NotificationSound stores a
    /// choice; never "none", which is what `silencedSounds` is for. Every category has an entry from `init` on.
    /// Only a category whose choice changed is written, under its own key (`soundKey(for:)`).
    ///
    /// Some of what `init` read was read off another category's key (`storedSound`): the waiting reminder off
    /// the permission sound, and any Silence box off a None an earlier build stored. So before a key is
    /// overwritten, every category that key was answering for is pinned under its own keys to what it reads now.
    /// Without that, picking a permission sound on a fresh install would hand the same sound to the waiting
    /// reminder at the next launch, and picking a sound on a row silenced by an old None would quietly clear its
    /// box. The pin is the value on screen, so nothing anyone can see changes.
    var soundChoices: [SoundCategory: String] {
        didSet {
            for category in SoundCategory.allCases where soundChoices[category] != oldValue[category] {
                let key = Self.soundKey(for: category)
                for reader in SoundCategory.allCases where Self.soundKeys(for: reader).contains(key) {
                    let own = Self.soundKey(for: reader)
                    if reader != category, defaults.object(forKey: own) == nil, let held = oldValue[reader] {
                        defaults.set(held, forKey: own)
                    }
                    let silence = Self.silenceKey(for: reader)
                    if defaults.object(forKey: silence) == nil { defaults.set(silencedSounds.contains(reader), forKey: silence) }
                }
                defaults.set(soundChoices[category], forKey: key)
                report(key, soundChoices[category] ?? "", changed: true)
            }
        }
    }
    /// The categories whose Silence box is ticked. Kept apart from the choice so that bringing a category back
    /// returns the sound it had; each category's box is its own key (`silenceKey(for:)`), written once it has
    /// been touched.
    var silencedSounds: Set<SoundCategory> {
        didSet {
            for category in SoundCategory.allCases where silencedSounds.contains(category) != oldValue.contains(category) {
                let key = Self.silenceKey(for: category)
                defaults.set(silencedSounds.contains(category), forKey: key)
                report(key, silencedSounds.contains(category), changed: true)
            }
        }
    }
    var quietHoursEnabled: Bool {
        didSet { defaults.set(quietHoursEnabled, forKey: Keys.quietHours); report(Keys.quietHours, quietHoursEnabled, changed: quietHoursEnabled != oldValue) }
    }
    /// Minutes after midnight, local time; a window that crosses midnight is fine (22:00 to 08:00).
    var quietHoursStart: Int {
        didSet { defaults.set(quietHoursStart, forKey: Keys.quietStart); report(Keys.quietStart, quietHoursStart, changed: quietHoursStart != oldValue) }
    }
    var quietHoursEnd: Int {
        didSet { defaults.set(quietHoursEnd, forKey: Keys.quietEnd); report(Keys.quietEnd, quietHoursEnd, changed: quietHoursEnd != oldValue) }
    }
    /// Anthropic's weekday peak window, editable; applied to the tools in `peakHoursTools`.
    var peakHours: PeakHours {
        didSet { storeCodable(peakHours, forKey: Keys.peakHours); report(Keys.peakHours, "\(peakHours.startMinute)-\(peakHours.endMinute) \(peakHours.timeZoneID)", changed: peakHours != oldValue) }
    }
    var peakHoursTools: Set<ToolID> {
        didSet {
            defaults.set(peakHoursTools.map(\.rawValue).sorted(), forKey: Keys.peakHoursTools)
            report(Keys.peakHoursTools, peakHoursTools.map(\.rawValue).sorted(), changed: peakHoursTools != oldValue)
        }
    }
    /// Folders beyond Claude Code's own config directory whose transcripts are priced (synced logs, other machines).
    var extraTranscriptRoots: [String] {
        didSet { defaults.set(extraTranscriptRoots, forKey: Keys.extraRoots); report(Keys.extraRoots, extraTranscriptRoots, changed: extraTranscriptRoots != oldValue) }
    }
    /// GET /v1/limits on 127.0.0.1 for scripts and widgets; off because it widens the surface of a local-only app.
    var localAPIEnabled: Bool {
        didSet { defaults.set(localAPIEnabled, forKey: Keys.localAPI); report(Keys.localAPI, localAPIEnabled, changed: localAPIEnabled != oldValue) }
    }
    /// Web origins the local API may answer; empty means none (a request carrying an Origin header is refused).
    var localAPIOrigins: [String] {
        didSet { defaults.set(localAPIOrigins, forKey: Keys.localAPIOrigins); report(Keys.localAPIOrigins, localAPIOrigins, changed: localAPIOrigins != oldValue) }
    }
    /// A second Codex endpoint (rate-limit reset credits), opt-in under the one-request-per-token rule.
    var codexResetCredits: Bool {
        didSet { defaults.set(codexResetCredits, forKey: Keys.codexCredits); report(Keys.codexCredits, codexResetCredits, changed: codexResetCredits != oldValue) }
    }
    /// Cursor's usage-events export on the same cookie, for the daily history; opt-in.
    var cursorUsageEvents: Bool {
        didSet { defaults.set(cursorUsageEvents, forKey: Keys.cursorEvents); report(Keys.cursorEvents, cursorUsageEvents, changed: cursorUsageEvents != oldValue) }
    }
    /// Copilot organisation billing on the same token; opt-in.
    var copilotOrgBilling: Bool {
        didSet { defaults.set(copilotOrgBilling, forKey: Keys.copilotOrg); report(Keys.copilotOrg, copilotOrgBilling, changed: copilotOrgBilling != oldValue) }
    }
    /// Whether Anthropic's usage endpoint is read at all for Claude Code. Off leaves the status line, the channel
    /// Anthropic documents, as the only Claude source; the status line is preferred whenever it is fresh either way.
    var pollClaudeEndpoint: Bool {
        didSet { defaults.set(pollClaudeEndpoint, forKey: Keys.pollClaude); report(Keys.pollClaude, pollClaudeEndpoint, changed: pollClaudeEndpoint != oldValue) }
    }
    /// Whether Notchmeter's published price catalog is fetched once a day and applied over the build's tables
    /// (PricingCatalog). On unless switched off: public data, and nothing about the user in the request
    /// (docs/privacy.md). The command-line tool reads the same key through `PricingCatalog.isEnabled`.
    var pricingCatalog: Bool {
        didSet { defaults.set(pricingCatalog, forKey: Keys.pricingCatalog); report(Keys.pricingCatalog, pricingCatalog, changed: pricingCatalog != oldValue) }
    }
    /// When the Keychain dialog for Claude Code's login may appear.
    var keychainPrompts: KeychainPromptPolicy {
        didSet {
            defaults.set(keychainPrompts.rawValue, forKey: Keys.keychainPrompts)
            report(Keys.keychainPrompts, keychainPrompts.rawValue, changed: keychainPrompts != oldValue)
            Keychain.setPolicy(keychainPrompts)
        }
    }
    /// A power assertion while an assistant session (any assistant's, per its hook, or a Claude Cowork task, per its
    /// log) is working; mains power only unless the override is on.
    var keepAwake: Bool {
        didSet { defaults.set(keepAwake, forKey: Keys.keepAwake); report(Keys.keepAwake, keepAwake, changed: keepAwake != oldValue) }
    }
    var keepAwakeOnBattery: Bool {
        didSet { defaults.set(keepAwakeOnBattery, forKey: Keys.keepAwakeBattery); report(Keys.keepAwakeBattery, keepAwakeOnBattery, changed: keepAwakeOnBattery != oldValue) }
    }
    /// A hook or status line that names an old copy of this app is rewritten at launch, after the usual backup.
    var autoRepairHooks: Bool {
        didSet { defaults.set(autoRepairHooks, forKey: Keys.autoRepair); report(Keys.autoRepair, autoRepairHooks, changed: autoRepairHooks != oldValue) }
    }
    /// The Sessions card on the panel: one row per session, the hooks' and the ones found without them
    /// (`detectSessions`).
    var sessionsCard: Bool {
        didSet { defaults.set(sessionsCard, forKey: Keys.sessionsCard); report(Keys.sessionsCard, sessionsCard, changed: sessionsCard != oldValue) }
    }
    /// Whether running sessions are found without the hook (SessionDetection): the assistants' processes in a
    /// terminal, Claude Code's own session files and the end of its transcripts, read and never written. On by
    /// default, so the Sessions card has rows on the first launch; off, the scan stops and its rows go.
    var detectSessions: Bool {
        didSet { defaults.set(detectSessions, forKey: Keys.detectSessions); report(Keys.detectSessions, detectSessions, changed: detectSessions != oldValue) }
    }
    /// Whether Claude Cowork's tasks are read from the Claude app's own files and listed as sessions
    /// (CoworkSessions). On by default: it needs no hook and writes nothing, and the files are the ones the cost
    /// scan already reads. Off, the watch stops and every Cowork row goes at once.
    var coworkSessions: Bool {
        didSet { defaults.set(coworkSessions, forKey: Keys.coworkSessions); report(Keys.coworkSessions, coworkSessions, changed: coworkSessions != oldValue) }
    }
    /// How many rows the Sessions card draws before it counts the rest as "+N more": one of `sessionRowChoices`,
    /// six by default, which is the cap the card had before it was a setting (SessionsCard.rowCap).
    var sessionRows: Int {
        didSet {
            // Same shape as finishedAfterMinutes below: the snap writes back only when it changes the value.
            let snapped = Self.sessionRowChoice(sessionRows)
            if snapped != sessionRows { sessionRows = snapped; return }
            defaults.set(sessionRows, forKey: Keys.sessionRows)
            report(Keys.sessionRows, sessionRows, changed: sessionRows != oldValue)
        }
    }
    nonisolated static let sessionRowChoices = [4, 6, 8, 10]
    /// A stored count that is not one of the choices (a hand-edited default) reads as the nearest one, the lower
    /// on a tie, so the card never draws a count the picker cannot show.
    nonisolated static func sessionRowChoice(_ count: Int) -> Int {
        sessionRowChoices.min { abs($0 - count) < abs($1 - count) } ?? 6
    }
    /// What a session row leads with (SessionRowLead).
    var sessionRowLead: SessionRowLead {
        didSet { defaults.set(sessionRowLead.rawValue, forKey: Keys.sessionRowLead); report(Keys.sessionRowLead, sessionRowLead.rawValue, changed: sessionRowLead != oldValue) }
    }
    /// Whether a prompt's first line is kept as the session's title. Off, the store drops the title before it
    /// reaches the tracker (UsageStore.hookReceived), so nothing of the prompt is held anywhere in the app.
    var sessionTitles: Bool {
        didSet { defaults.set(sessionTitles, forKey: Keys.sessionTitles); report(Keys.sessionTitles, sessionTitles, changed: sessionTitles != oldValue) }
    }
    /// Whether OpenCode's sessions are read from its own database while its plugin is not reporting
    /// (OpenCodeSessions). On by default: it is a local, read-only reading that needs nothing installed, and each
    /// row it makes says where it came from. Off, OpenCode's sessions appear only once the plugin reports them.
    var openCodeStorageSessions: Bool {
        didSet {
            defaults.set(openCodeStorageSessions, forKey: Keys.openCodeStorageSessions)
            report(Keys.openCodeStorageSessions, openCodeStorageSessions, changed: openCodeStorageSessions != oldValue)
        }
    }
    /// Where Send Feedback last sent (Feedback.Destination), so a person without a GitHub account picks Email once
    /// rather than every time.
    var feedbackDestination: Feedback.Destination {
        didSet {
            defaults.set(feedbackDestination.rawValue, forKey: Keys.feedbackDestination)
            report(Keys.feedbackDestination, feedbackDestination.rawValue, changed: feedbackDestination != oldValue)
        }
    }
    /// Whether Send Feedback's *Include diagnostics* is ticked. On until unticked: the report is shown whole, and
    /// already scrubbed, before it can leave, and a bug report without it is usually answered by asking for it.
    var feedbackDiagnostics: Bool {
        didSet { defaults.set(feedbackDiagnostics, forKey: Keys.feedbackDiagnostics); report(Keys.feedbackDiagnostics, feedbackDiagnostics, changed: feedbackDiagnostics != oldValue) }
    }
    /// Whether a permission request or a question is answered from the notch. Off, the store answers the hook
    /// nothing at once, so the terminal asks as it always has, and the panel shows only the wait.
    var answerFromNotch: Bool {
        didSet { defaults.set(answerFromNotch, forKey: Keys.answerFromNotch); report(Keys.answerFromNotch, answerFromNotch, changed: answerFromNotch != oldValue) }
    }
    /// The four switches on each assistant's own Settings page (SettingsPane.agent), each kept as the set of
    /// assistants it is off for rather than on for. An assistant a later version adds is then on from its first
    /// launch like every one before it, with no migration, and an install that never touched a page stores
    /// nothing at all. They sit under the app-wide switches above rather than replacing them: *Answer from the
    /// notch*, *Notify when a window is on pace to run out* and the two session notices still decide for every
    /// assistant, and a page can only take its own assistant out of what they allow.
    ///
    /// Sessions read from this assistant's hook. Off, the store drops its events before the session tracker sees
    /// them (UsageStore.hookReceived): no row, no wait or finish on its ring, no news, no notice, no request on
    /// the panel and no keep-awake, and nothing of the event is held. The event still refreshes its meter.
    var sessionReadingOff: Set<ToolID> {
        didSet {
            defaults.set(sessionReadingOff.map(\.rawValue).sorted(), forKey: Keys.sessionReadingOff)
            report(Keys.sessionReadingOff, sessionReadingOff.map(\.rawValue).sorted(), changed: sessionReadingOff != oldValue)
        }
    }
    /// Requests from this assistant answered from the notch, under `answerFromNotch`. Off, its hook is answered
    /// nothing at once and its terminal asks, as with the app-wide switch off.
    var notchAnswersOff: Set<ToolID> {
        didSet {
            defaults.set(notchAnswersOff.map(\.rawValue).sorted(), forKey: Keys.notchAnswersOff)
            report(Keys.notchAnswersOff, notchAnswersOff.map(\.rawValue).sorted(), changed: notchAnswersOff != oldValue)
        }
    }
    /// This assistant's pace, run-out, limit-hit, reset and reminder notices, under `notificationsEnabled`.
    var limitNoticesOff: Set<ToolID> {
        didSet {
            defaults.set(limitNoticesOff.map(\.rawValue).sorted(), forKey: Keys.limitNoticesOff)
            report(Keys.limitNoticesOff, limitNoticesOff.map(\.rawValue).sorted(), changed: limitNoticesOff != oldValue)
        }
    }
    /// This assistant's waiting and finished-turn notices, and the glance or panel `sessionAttention` opens for
    /// them, under `notifyWaiting` and `notifyFinished`.
    var sessionNoticesOff: Set<ToolID> {
        didSet {
            defaults.set(sessionNoticesOff.map(\.rawValue).sorted(), forKey: Keys.sessionNoticesOff)
            report(Keys.sessionNoticesOff, sessionNoticesOff.map(\.rawValue).sorted(), changed: sessionNoticesOff != oldValue)
        }
    }
    /// Whether clicking a session row activates the terminal it runs in (TerminalJump).
    var jumpToTerminal: Bool {
        didSet { defaults.set(jumpToTerminal, forKey: Keys.jumpToTerminal); report(Keys.jumpToTerminal, jumpToTerminal, changed: jumpToTerminal != oldValue) }
    }
    /// How long the app holds a request before handing it back to the terminal, 15 s to 9 min. The socket's own
    /// cap (HookSocket.Listener.holdCap), the command's wait and the entries' timeouts are all ten minutes, and
    /// the vendor's clock starts before the command has even connected, so the range stops a minute short of
    /// them: the app's hold is what ends a request, never a vendor killing the command under a card still
    /// showing (HookDecisionTests pins the order).
    var promptHoldSeconds: Int {
        didSet {
            // Same shape as finishedAfterMinutes above: the clamp writes back only when it changes the value.
            let clamped = min(Self.promptHoldRange.upperBound, max(Self.promptHoldRange.lowerBound, promptHoldSeconds))
            if clamped != promptHoldSeconds { promptHoldSeconds = clamped; return }
            defaults.set(promptHoldSeconds, forKey: Keys.promptHold)
            report(Keys.promptHold, promptHoldSeconds, changed: promptHoldSeconds != oldValue)
        }
    }
    static let promptHoldRange = 15...540
    static let promptHoldDefault = 120
    /// "http://host:port" or "socks5://host:port"; empty follows the system proxy.
    var proxyURL: String {
        didSet {
            defaults.set(proxyURL, forKey: Keys.proxy)
            report(Keys.proxy, proxyURL, changed: proxyURL != oldValue)
            NetworkSession.configure(proxy: proxyURL)
        }
    }
    /// The providers' request outcomes in the unified log at info level.
    var debugLogging: Bool {
        didSet {
            defaults.set(debugLogging, forKey: Keys.debugLogging)
            report(Keys.debugLogging, debugLogging, changed: debugLogging != oldValue)
            DiagnosticLog.verbose = debugLogging
        }
    }
    /// Sparkle's beta channel; the feed carries a `sparkle:channel` on such items (scripts/release.sh --channel beta).
    var betaUpdates: Bool {
        didSet { defaults.set(betaUpdates, forKey: Keys.betaUpdates); report(Keys.betaUpdates, betaUpdates, changed: betaUpdates != oldValue) }
    }
    /// The language the app runs in: nil follows macOS, else a shipped code written to AppleLanguages at relaunch.
    var language: String? {
        didSet {
            if let language { defaults.set(language, forKey: Keys.language) } else { defaults.removeObject(forKey: Keys.language) }
            Localization.applyPreferred(language: language, defaults: defaults)
            report(Keys.language, language as Any, changed: language != oldValue)
        }
    }
    var togglePanelHotkey: Hotkey? {
        didSet { storeCodable(togglePanelHotkey, forKey: Keys.hotkeyToggle); report(Keys.hotkeyToggle, togglePanelHotkey?.description as Any, changed: togglePanelHotkey != oldValue) }
    }
    var openSettingsHotkey: Hotkey? {
        didSet { storeCodable(openSettingsHotkey, forKey: Keys.hotkeySettings); report(Keys.hotkeySettings, openSettingsHotkey?.description as Any, changed: openSettingsHotkey != oldValue) }
    }
    /// Flips the readouts over the full-screen app on screen right now, whichever way the preference points.
    var showOverFullScreenHotkey: Hotkey? {
        didSet { storeCodable(showOverFullScreenHotkey, forKey: Keys.hotkeyFullScreen); report(Keys.hotkeyFullScreen, showOverFullScreenHotkey?.description as Any, changed: showOverFullScreenHotkey != oldValue) }
    }
    /// Apps the readouts stay over in full screen whatever `showOverFullScreenApps` says, by the name the window
    /// list gives them ("zoom.us"). For a meeting you want the meters beside, where a video is the case the
    /// preference is off for. It cannot tell two uses of one app apart, a call and a film both in a browser
    /// being the case in point; `showOverFullScreenNow` is the answer to that one.
    var fullScreenExceptions: [String] {
        didSet { defaults.set(fullScreenExceptions, forKey: Keys.fullScreenExceptions); report(Keys.fullScreenExceptions, fullScreenExceptions, changed: fullScreenExceptions != oldValue) }
    }
    /// The shortcut's and the menu item's answer for one full-screen app, either way round, and the apps it was
    /// given for. It is not written down, and it is dropped the moment those apps stop being the ones covering
    /// the screen, so it cannot outlive the meeting it was meant for or answer for whatever goes full-screen
    /// next. Nil is the ordinary rules.
    struct FullScreenOverride: Equatable {
        var show: Bool
        var apps: [String]
    }
    var showOverFullScreenNow: FullScreenOverride?

    /// Whether the readouts stay on screen over these full-screen apps: what the person just asked for about
    /// these very apps, then the preference, then whether one of the apps covering the screen is an exception.
    func showsOverFullScreen(_ apps: [String]) -> Bool {
        if let now = showOverFullScreenNow, now.apps == apps { return now.show }
        if showOverFullScreenApps { return true }
        // The name is typed by hand in Settings as well as taken from the window list by the menu, so a typed
        // "Zoom.us" has to match the list's "zoom.us".
        return apps.contains { app in
            fullScreenExceptions.contains { $0.compare(app, options: .caseInsensitive) == .orderedSame }
        }
    }
    /// The one-time first-launch offer to install the Claude Code hook has been shown.
    var hookOfferShown: Bool {
        didSet { defaults.set(hookOfferShown, forKey: Keys.hookOffer); report(Keys.hookOffer, hookOfferShown, changed: hookOfferShown != oldValue) }
    }
    /// The first-launch Welcome window has been shown, or a copy set up before it existed was found; either way it
    /// is never shown again (WelcomeWindow).
    var welcomed: Bool {
        didSet { defaults.set(welcomed, forKey: Keys.welcomed); report(Keys.welcomed, welcomed, changed: welcomed != oldValue) }
    }
    /// The code signature Accessibility was last seen granted under (CodeSignature.runningIdentity). macOS ties the
    /// grant to the copy it was given to and leaves the switch on when that copy is replaced, so this is the only
    /// way to tell a permission that was never given from one the running copy has been quietly refused.
    var accessibilityGrantedTo: String? {
        didSet {
            defaults.set(accessibilityGrantedTo, forKey: Keys.accessibilityGrant)
            report(Keys.accessibilityGrant, accessibilityGrantedTo ?? "none", changed: accessibilityGrantedTo != oldValue)
        }
    }
    /// The code signature the Accessibility prompt was last shown under (CodeSignature.runningIdentity), whether
    /// the user picked Auto or a launch found Auto chosen and refused. The prompt is the system's and says nothing
    /// back, so this is the only way not to show it on every launch to a user who dismissed it; a new signature is
    /// a new copy to macOS and asks once more. Cleared with the grant when the entry is reset, so the relaunch can
    /// ask for what was just cleared.
    var accessibilityAskedFor: String? {
        didSet {
            defaults.set(accessibilityAskedFor, forKey: Keys.accessibilityAsked)
            report(Keys.accessibilityAsked, accessibilityAskedFor ?? "none", changed: accessibilityAskedFor != oldValue)
        }
    }
    /// The usage card's choices (ShareCard.swift), kept so the card opens as it was last made.
    var shareCardMetric: ShareCardMetric {
        didSet { defaults.set(shareCardMetric.rawValue, forKey: Keys.shareCardMetric); report(Keys.shareCardMetric, shareCardMetric.rawValue, changed: shareCardMetric != oldValue) }
    }
    var shareCardRange: ShareCardRange {
        didSet { defaults.set(shareCardRange.rawValue, forKey: Keys.shareCardRange); report(Keys.shareCardRange, shareCardRange.rawValue, changed: shareCardRange != oldValue) }
    }
    var shareCardFormat: ShareCardFormat {
        didSet { defaults.set(shareCardFormat.rawValue, forKey: Keys.shareCardFormat); report(Keys.shareCardFormat, shareCardFormat.rawValue, changed: shareCardFormat != oldValue) }
    }
    /// The theme the reader picked; nil follows the metric (ShareCardMetric.defaultTheme), so a card switched from
    /// dollars to tokens changes ground with it until a theme is chosen by hand.
    var shareCardTheme: ShareCardTheme? {
        didSet {
            if let shareCardTheme { defaults.set(shareCardTheme.rawValue, forKey: Keys.shareCardTheme) } else { defaults.removeObject(forKey: Keys.shareCardTheme) }
            report(Keys.shareCardTheme, shareCardTheme?.rawValue ?? "auto", changed: shareCardTheme != oldValue)
        }
    }
    /// The theme a card is drawn in now.
    var shareCardThemeShown: ShareCardTheme { shareCardTheme ?? shareCardMetric.defaultTheme }
    /// The optional line under the card's figures. The oracle hears only whether one is set, not what it says,
    /// and only when that changes, rather than a line per keystroke.
    var shareCardSignature: String {
        didSet {
            defaults.set(shareCardSignature, forKey: Keys.shareCardSignature)
            report(Keys.shareCardSignature, !shareCardSignature.isEmpty, changed: shareCardSignature.isEmpty != oldValue.isEmpty)
        }
    }
    /// The assistants left off the card. Kept as the ones left off rather than the ones carried, so an assistant
    /// that starts reporting after the choice was made is on the next card rather than silently missing from it.
    var shareCardHidden: Set<ToolID> {
        didSet {
            defaults.set(shareCardHidden.map(\.rawValue).sorted(), forKey: Keys.shareCardHidden)
            report(Keys.shareCardHidden, shareCardHidden.map(\.rawValue).sorted(), changed: shareCardHidden != oldValue)
        }
    }
    /// The card offered by itself once after an update (ShareCardOffer); off for good from Settings or from the
    /// offer's own "Don't offer after updates".
    var offerShareCardAfterUpdate: Bool {
        didSet {
            defaults.set(offerShareCardAfterUpdate, forKey: Keys.offerShareCard)
            report(Keys.offerShareCard, offerShareCardAfterUpdate, changed: offerShareCardAfterUpdate != oldValue)
        }
    }
    /// The version an update left the offer waiting for; nil once it has been shown or dropped, which is what makes
    /// it once per version.
    var shareCardOfferPending: String? {
        didSet {
            defaults.set(shareCardOfferPending, forKey: Keys.shareCardOfferPending)
            report(Keys.shareCardOfferPending, shareCardOfferPending ?? "none", changed: shareCardOfferPending != oldValue)
        }
    }
    /// The version the last launch ran, so the next one can tell an update from a relaunch.
    var lastLaunchedVersion: String? {
        didSet {
            defaults.set(lastLaunchedVersion, forKey: Keys.lastLaunchedVersion)
            report(Keys.lastLaunchedVersion, lastLaunchedVersion ?? "none", changed: lastLaunchedVersion != oldValue)
        }
    }
    private(set) var launchAtLogin: Bool
    private(set) var launchAtLoginStatus: SMAppService.Status

    private enum Keys {
        static let enabledTools = "enabledTools"
        static let toolOrder = "toolOrder"
        static let settingsExpanded = "settingsExpandedTools"
        static let visibility = "notchVisibility"
        static let hoverDelay = "hoverDelay"
        static let edge = "panelEdge"
        static let display = "display"
        static let displaySwitches = "displaySwitches"
        static let closedWhileWorking = "closedNotchWhileWorking"
        static let closedWhenQuiet = "closedNotchWhenQuiet"
        static let sessionRows = "sessionRows"
        static let sessionRowLead = "sessionRowLead"
        static let fullScreen = "showOverFullScreenApps"
        static let fullScreenExceptions = "fullScreenExceptions"
        static let hotkeyFullScreen = "hotkeyShowOverFullScreen"
        static let compactStyle = "compactStyle"
        static let resetCountdown = "showResetCountdown"
        static let compactPrimary = "compactPrimary"
        static let ringSymbols = "ringSymbols"
        static let hideEmptyTools = "hideEmptyTools"
        static let showSpend = "showSpend"
        static let showDetails = "showDetails"
        static let compactSide = "compactSide"
        static let compactKeep = "compactKeep"
        static let appearance = "appearance"
        static let panelTheme = "panelTheme"
        static let panelMaterial = "panelMaterial"
        static let panelAccent = "panelAccent"
        static let usageStyle = "usageStyle"
        static let hourClock = "hourClock"
        static let usageDisplay = "usageDisplay"
        static let resetDisplay = "resetDisplay"
        static let timeFormat = "timeFormat"
        static let density = "density"
        static let panelWidth = "panelWidth"
        static let panelMode = "panelMode"
        static let gestures = "gesturesEnabled"
        static let reduceAnimations = "reduceAnimations"
        static let menuBarItem = "showMenuBarItem"
        static let menuBarPin = "menuBarPin"
        static let menuBarPinnedTools = "menuBarPinnedTools"
        static let menuBarStyle = "menuBarStyle"
        static let menuBarTint = "menuBarTint"
        static let menuBarTintHex = "menuBarTintHex"
        static let screenShare = "hideFromScreenShare"
        static let currencyCode = "currencyCode"
        static let currencyRate = "currencyRate"
        static let fetchCurrencyRate = "fetchCurrencyRate"
        static let monthlyBudget = "monthlyBudget"
        static let weeklyBudget = "weeklyBudget"
        /// The dollar figures builds before 0.9.0 kept, read once and re-expressed in the currency (`budget(_:key:legacy:at:)`).
        static let legacyMonthlyBudget = "monthlyBudgetUSD"
        static let legacyWeeklyBudget = "weeklyBudgetUSD"
        static let costCardMode = "costCardMode"
        static let costCardTools = "costCardTools"
        static let ringWindows = "ringWindows"
        static let hiddenWindows = "hiddenWindows"
        static let revealedWindows = "revealedWindows"
        static let notificationsEnabled = "notificationsEnabled"
        static let notifyOnTrack = "notifyOnTrack"
        static let notifyBehind = "notifyBehind"
        static let notifyRunningOut = "notifyRunningOut"
        static let notifyOnReset = "notifyOnReset"
        static let resetReminder = "resetReminder"
        static let notifyWaiting = "notifyWaiting"
        static let notifyFinished = "notifyFinished"
        static let notifySessionTrouble = "notifySessionTrouble"
        static let quietWhileTerminal = "quietWhileTerminalFrontmost"
        static let finishedAfter = "finishedAfterMinutes"
        static let notifyExtraUsage = "notifyExtraUsage"
        static let notifyCacheShift = "notifyCacheShift"
        static let notifyPromptCache = "notifyPromptCache"
        static let sessionAttention = "sessionAttention"
        static let signalRings = "signalRings"
        static let notchNews = "notchNews"
        static let notchGlow = "notchGlow"
        static let notificationSound = "notificationSound"
        /// The limit category's sound. The name is from before the category was widened from pace crossings to
        /// every limit notice, kept so the choice made under it is simply still there.
        static let soundPace = "soundPace"
        /// The one waiting sound through 0.7.9. Read, never written: `storedSound` falls back to it, and it is
        /// left in place so an earlier build run again still finds the choice it made.
        static let soundWaiting = "soundWaiting"
        static let soundPermission = "soundPermission"
        static let soundQuestion = "soundQuestion"
        static let soundPlan = "soundPlan"
        /// The completion category's sound, named for the Turn finished row it has always sat on.
        static let soundFinished = "soundFinished"
        /// The waiting reminder's own sound, new in 0.9.0. Not `soundWaiting`, which is 0.7.9's shared sound for
        /// every wait and which the three stopped kinds still fall back to: writing this category's pick there
        /// would move theirs too.
        static let soundWaitingReminder = "soundWaitingReminder"
        static let silenceCompletion = "silenceCompletion"
        static let silenceWaiting = "silenceWaiting"
        static let silencePermission = "silencePermission"
        static let silenceQuestion = "silenceQuestion"
        static let silencePlan = "silencePlan"
        static let silenceLimit = "silenceLimit"
        static let quietHours = "quietHoursEnabled"
        static let quietStart = "quietHoursStart"
        static let quietEnd = "quietHoursEnd"
        static let peakHours = "peakHours"
        static let peakHoursTools = "peakHoursTools"
        static let extraRoots = "extraTranscriptRoots"
        static let localAPI = "localAPIEnabled"
        static let localAPIOrigins = "localAPIOrigins"
        static let codexCredits = ProviderOptIn.codexResetCredits.key
        static let cursorEvents = ProviderOptIn.cursorUsageEvents.key
        static let copilotOrg = ProviderOptIn.copilotOrgBilling.key
        static let keychainPrompts = "keychainPrompts"
        static let pollClaude = "pollClaudeEndpoint"
        static let pricingCatalog = PricingCatalog.preferenceKey
        static let keepAwake = "keepAwake"
        static let keepAwakeBattery = "keepAwakeOnBattery"
        static let autoRepair = "autoRepairHooks"
        static let sessionsCard = "sessionsCard"
        static let detectSessions = "detectSessions"
        static let coworkSessions = "coworkSessions"
        static let sessionTitles = "sessionTitles"
        static let openCodeStorageSessions = "openCodeStorageSessions"
        static let answerFromNotch = "answerFromNotch"
        static let sessionReadingOff = "sessionReadingOffTools"
        static let notchAnswersOff = "answerFromNotchOffTools"
        static let limitNoticesOff = "limitNoticesOffTools"
        static let sessionNoticesOff = "sessionNoticesOffTools"
        static let feedbackDestination = "feedbackDestination"
        static let feedbackDiagnostics = "feedbackDiagnostics"
        static let jumpToTerminal = "jumpToTerminal"
        static let promptHold = "promptHoldSeconds"
        static let proxy = "proxyURL"
        static let debugLogging = "debugLogging"
        static let betaUpdates = "betaUpdates"
        static let language = "language"
        static let hotkeyToggle = "hotkeyTogglePanel"
        static let hotkeySettings = "hotkeyOpenSettings"
        static let hookOffer = "hookOfferShown"
        static let welcomed = "welcomed"
        static let accessibilityGrant = "accessibilityGrantedTo"
        static let accessibilityAsked = "accessibilityAskedFor"
        static let shareCardMetric = "shareCardMetric"
        static let shareCardRange = "shareCardRange"
        static let shareCardFormat = "shareCardFormat"
        static let shareCardTheme = "shareCardTheme"
        static let shareCardSignature = "shareCardSignature"
        static let shareCardHidden = "shareCardHidden"
        static let offerShareCard = "offerShareCardAfterUpdate"
        static let shareCardOfferPending = "shareCardOfferPending"
        static let lastLaunchedVersion = "lastLaunchedVersion"
        static let launchAtLogin = "launchAtLogin"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Before anything tool-keyed is read, so the new rows start from the settings they inherit.
        let migrated = ToolMigration.migrate(defaults)
        if !migrated.added.isEmpty {
            Oracle.shared.emit("toolMigration", ["added": migrated.added.map(\.rawValue),
                                                 "inherited": migrated.inherited.reduce(into: [String: String]()) { $0[$1.key.rawValue] = $1.value.rawValue }])
        }
        // A tool met for the first time, minus one that took another's row (ToolMigration decides that one), joins
        // the lists below the way a new install has every tool on.
        let introduced = Set(migrated.added).subtracting(migrated.inherited.keys)
        if let raw = defaults.array(forKey: Keys.enabledTools) as? [String] {
            enabledTools = Set(raw.compactMap(ToolID.init(rawValue:))).union(introduced)
        } else {
            enabledTools = Set(ToolID.allCases)
        }
        toolOrder = ToolOrder.normalize(defaults.array(forKey: Keys.toolOrder) as? [String])
        settingsExpandedTools = Set((defaults.array(forKey: Keys.settingsExpanded) as? [String] ?? []).compactMap(ToolID.init(rawValue:)))
        visibility = NotchVisibility(rawValue: defaults.string(forKey: Keys.visibility) ?? "") ?? .onHover
        hoverDelay = defaults.object(forKey: Keys.hoverDelay) as? Double ?? HoverIntent.expandDwell
        edge = PanelEdge(rawValue: defaults.string(forKey: Keys.edge) ?? "") ?? .top
        display = DisplayChoice(rawValue: defaults.string(forKey: Keys.display) ?? "") ?? .builtIn
        displaySwitches = defaults.dictionary(forKey: Keys.displaySwitches) as? [String: Bool] ?? [:]
        closedWhileWorking = ClosedNotchMode(rawValue: defaults.string(forKey: Keys.closedWhileWorking) ?? "") ?? .readouts
        closedWhenQuiet = ClosedNotchMode(rawValue: defaults.string(forKey: Keys.closedWhenQuiet) ?? "") ?? .readouts
        showOverFullScreenApps = defaults.object(forKey: Keys.fullScreen) as? Bool ?? false
        fullScreenExceptions = defaults.stringArray(forKey: Keys.fullScreenExceptions) ?? []
        compactStyle = CompactStyle(rawValue: defaults.string(forKey: Keys.compactStyle) ?? "") ?? .rings
        showResetCountdown = defaults.bool(forKey: Keys.resetCountdown)
        compactPrimary = defaults.object(forKey: Keys.compactPrimary) as? Bool ?? true
        ringSymbols = defaults.bool(forKey: Keys.ringSymbols)
        hideEmptyTools = defaults.object(forKey: Keys.hideEmptyTools) as? Bool ?? true
        showSpend = defaults.object(forKey: Keys.showSpend) as? Bool ?? true
        showDetails = defaults.object(forKey: Keys.showDetails) as? Bool ?? false
        compactSide = CompactSide(rawValue: defaults.string(forKey: Keys.compactSide) ?? "") ?? .split
        compactKeep = CompactKeep(rawValue: defaults.string(forKey: Keys.compactKeep) ?? "") ?? .tools
        appearance = AppearanceChoice(rawValue: defaults.string(forKey: Keys.appearance) ?? "") ?? .system
        panelTheme = PanelTheme(rawValue: defaults.string(forKey: Keys.panelTheme) ?? "") ?? .black
        panelMaterial = PanelMaterial(rawValue: defaults.string(forKey: Keys.panelMaterial) ?? "")
        panelAccent = PanelAccent(rawValue: defaults.string(forKey: Keys.panelAccent) ?? "") ?? .terracotta
        usageStyle = UsageStyle(rawValue: defaults.string(forKey: Keys.usageStyle) ?? "") ?? .bars
        hourClock = defaults.bool(forKey: Keys.hourClock)
        usageDisplay = UsageDisplay(rawValue: defaults.string(forKey: Keys.usageDisplay) ?? "") ?? .used
        resetDisplay = ResetDisplay(rawValue: defaults.string(forKey: Keys.resetDisplay) ?? "") ?? .exact
        timeFormat = TimeFormatPreference(rawValue: defaults.string(forKey: Keys.timeFormat) ?? "") ?? .auto
        density = Density(rawValue: defaults.string(forKey: Keys.density) ?? "") ?? .comfortable
        panelWidth = PanelWidth(rawValue: defaults.string(forKey: Keys.panelWidth) ?? "") ?? .standard
        panelMode = PanelMode(rawValue: defaults.string(forKey: Keys.panelMode) ?? "") ?? .simple
        gesturesEnabled = defaults.object(forKey: Keys.gestures) as? Bool ?? true
        reduceAnimations = defaults.bool(forKey: Keys.reduceAnimations)
        showMenuBarItem = defaults.object(forKey: Keys.menuBarItem) as? Bool
        menuBarPin = defaults.bool(forKey: Keys.menuBarPin)
        menuBarPinnedTools = Set((defaults.array(forKey: Keys.menuBarPinnedTools) as? [String] ?? []).compactMap(ToolID.init(rawValue:)))
        menuBarStyle = MenuBarStyle(rawValue: defaults.string(forKey: Keys.menuBarStyle) ?? "") ?? .text
        menuBarTint = MenuBarTint(rawValue: defaults.string(forKey: Keys.menuBarTint) ?? "") ?? .pace
        menuBarTintHex = defaults.string(forKey: Keys.menuBarTintHex) ?? "0072B2"
        hideFromScreenShare = defaults.bool(forKey: Keys.screenShare)
        currencyCode = defaults.string(forKey: Keys.currencyCode) ?? "USD"
        currencyRate = defaults.object(forKey: Keys.currencyRate) as? Double ?? 1
        fetchCurrencyRate = defaults.bool(forKey: Keys.fetchCurrencyRate)
        referenceRateCache = ReferenceRateCache.load(defaults)
        let conversion = Self.currencyConversion(defaults, now: Date())
        currencyConversion = conversion
        monthlyBudget = Self.budget(defaults, key: Keys.monthlyBudget, legacy: Keys.legacyMonthlyBudget, at: conversion)
        weeklyBudget = Self.budget(defaults, key: Keys.weeklyBudget, legacy: Keys.legacyWeeklyBudget, at: conversion)
        costCardMode = CostCardMode(rawValue: defaults.string(forKey: Keys.costCardMode) ?? "") ?? .cost
        costCardTools = (defaults.array(forKey: Keys.costCardTools) as? [String])
            .map { Set($0.compactMap(ToolID.init(rawValue:)).filter(\.reportsCost)).union(introduced.filter(\.reportsCost)) }
            ?? Set(ToolID.allCases.filter(\.reportsCost))
        ringWindows = (defaults.dictionary(forKey: Keys.ringWindows) as? [String: [String]] ?? [:])
            .reduce(into: [:]) { if let tool = ToolID(rawValue: $1.key) { $0[tool] = $1.value } }
        hiddenWindows = (defaults.dictionary(forKey: Keys.hiddenWindows) as? [String: [String]] ?? [:])
            .reduce(into: [:]) { if let tool = ToolID(rawValue: $1.key) { $0[tool] = Set($1.value) } }
        revealedWindows = (defaults.dictionary(forKey: Keys.revealedWindows) as? [String: [String]] ?? [:])
            .reduce(into: [:]) { if let tool = ToolID(rawValue: $1.key) { $0[tool] = Set($1.value) } }
        notificationsEnabled = defaults.object(forKey: Keys.notificationsEnabled) as? Bool ?? true
        notifyOnTrack = defaults.object(forKey: Keys.notifyOnTrack) as? Bool ?? true
        notifyBehind = defaults.object(forKey: Keys.notifyBehind) as? Bool ?? true
        notifyRunningOut = defaults.object(forKey: Keys.notifyRunningOut) as? Bool ?? true
        notifyOnReset = defaults.object(forKey: Keys.notifyOnReset) as? Bool ?? true
        resetReminder = ResetReminder(rawValue: defaults.string(forKey: Keys.resetReminder) ?? "") ?? .off
        notifyWaiting = defaults.bool(forKey: Keys.notifyWaiting)
        notifyFinished = defaults.bool(forKey: Keys.notifyFinished)
        notifySessionTrouble = defaults.bool(forKey: Keys.notifySessionTrouble)
        quietWhileTerminalFrontmost = defaults.object(forKey: Keys.quietWhileTerminal) as? Bool ?? true
        finishedAfterMinutes = defaults.object(forKey: Keys.finishedAfter) as? Int ?? 2
        notifyExtraUsage = defaults.object(forKey: Keys.notifyExtraUsage) as? Bool ?? true
        notifyCacheShift = defaults.bool(forKey: Keys.notifyCacheShift)
        notifyPromptCache = defaults.object(forKey: Keys.notifyPromptCache) as? Bool ?? true
        sessionAttention = SessionAttention.stored(defaults.string(forKey: Keys.sessionAttention))
        signalRings = defaults.object(forKey: Keys.signalRings) as? Bool ?? true
        notchNews = defaults.object(forKey: Keys.notchNews) as? Bool ?? true
        notchGlow = defaults.object(forKey: Keys.notchGlow) as? Bool ?? true
        notificationSound = defaults.object(forKey: Keys.notificationSound) as? Bool ?? true
        let installedSounds = NotificationSound.systemSounds()
        let storedSounds = SoundCategory.allCases.map { ($0, Self.storedSound($0, defaults: defaults, installed: installedSounds)) }
        soundChoices = Dictionary(uniqueKeysWithValues: storedSounds.map { ($0.0, $0.1.choice) })
        silencedSounds = Set(storedSounds.filter(\.1.silenced).map(\.0))
        quietHoursEnabled = defaults.bool(forKey: Keys.quietHours)
        quietHoursStart = defaults.object(forKey: Keys.quietStart) as? Int ?? 22 * 60
        quietHoursEnd = defaults.object(forKey: Keys.quietEnd) as? Int ?? 8 * 60
        peakHours = Self.codable(defaults, Keys.peakHours) ?? .anthropic
        peakHoursTools = (defaults.array(forKey: Keys.peakHoursTools) as? [String]).map { Set($0.compactMap(ToolID.init(rawValue:))) } ?? [.claude]
        extraTranscriptRoots = defaults.stringArray(forKey: Keys.extraRoots) ?? []
        localAPIEnabled = defaults.bool(forKey: Keys.localAPI)
        localAPIOrigins = defaults.stringArray(forKey: Keys.localAPIOrigins) ?? []
        codexResetCredits = ProviderOptIn.codexResetCredits.value(defaults)
        // On by default: the events come from the same account over the same session cookie the usage summary
        // already uses, so hiding a tool's own spend behind a switch cost more than it protected.
        // A build that defaulted this off wrote false into every existing install, so the new default alone
        // would never reach them; turn it on once, and leave a later deliberate switch-off alone.
        if defaults.object(forKey: "cursorUsageEventsDefaulted") == nil {
            defaults.set(true, forKey: "cursorUsageEventsDefaulted")
            defaults.set(true, forKey: Keys.cursorEvents)
        }
        cursorUsageEvents = ProviderOptIn.cursorUsageEvents.value(defaults)
        copilotOrgBilling = ProviderOptIn.copilotOrgBilling.value(defaults)
        keychainPrompts = KeychainPromptPolicy(rawValue: defaults.string(forKey: Keys.keychainPrompts) ?? "") ?? .refreshOnly
        pollClaudeEndpoint = defaults.object(forKey: Keys.pollClaude) as? Bool ?? true
        pricingCatalog = PricingCatalog.isEnabled(defaults)
        keepAwake = defaults.bool(forKey: Keys.keepAwake)
        keepAwakeOnBattery = defaults.bool(forKey: Keys.keepAwakeBattery)
        autoRepairHooks = defaults.object(forKey: Keys.autoRepair) as? Bool ?? true
        sessionsCard = defaults.object(forKey: Keys.sessionsCard) as? Bool ?? true
        detectSessions = defaults.object(forKey: Keys.detectSessions) as? Bool ?? true
        coworkSessions = defaults.object(forKey: Keys.coworkSessions) as? Bool ?? true
        sessionRows = Self.sessionRowChoice(defaults.object(forKey: Keys.sessionRows) as? Int ?? SessionsCard.rowCap)
        sessionRowLead = SessionRowLead(rawValue: defaults.string(forKey: Keys.sessionRowLead) ?? "") ?? .title
        sessionTitles = defaults.object(forKey: Keys.sessionTitles) as? Bool ?? true
        openCodeStorageSessions = defaults.object(forKey: Keys.openCodeStorageSessions) as? Bool ?? true
        answerFromNotch = defaults.object(forKey: Keys.answerFromNotch) as? Bool ?? true
        sessionReadingOff = Self.tools(defaults, Keys.sessionReadingOff)
        notchAnswersOff = Self.tools(defaults, Keys.notchAnswersOff)
        limitNoticesOff = Self.tools(defaults, Keys.limitNoticesOff)
        sessionNoticesOff = Self.tools(defaults, Keys.sessionNoticesOff)
        feedbackDestination = Feedback.Destination(rawValue: defaults.string(forKey: Keys.feedbackDestination) ?? "") ?? .github
        feedbackDiagnostics = defaults.object(forKey: Keys.feedbackDiagnostics) as? Bool ?? true
        jumpToTerminal = defaults.object(forKey: Keys.jumpToTerminal) as? Bool ?? true
        promptHoldSeconds = min(Self.promptHoldRange.upperBound, max(Self.promptHoldRange.lowerBound, defaults.object(forKey: Keys.promptHold) as? Int ?? Self.promptHoldDefault))
        proxyURL = defaults.string(forKey: Keys.proxy) ?? ""
        debugLogging = defaults.bool(forKey: Keys.debugLogging)
        betaUpdates = defaults.bool(forKey: Keys.betaUpdates)
        language = defaults.string(forKey: Keys.language).flatMap(Localization.canonical)
        togglePanelHotkey = Self.codable(defaults, Keys.hotkeyToggle)
        openSettingsHotkey = Self.codable(defaults, Keys.hotkeySettings)
        showOverFullScreenHotkey = Self.codable(defaults, Keys.hotkeyFullScreen)
        hookOfferShown = defaults.bool(forKey: Keys.hookOffer)
        welcomed = defaults.bool(forKey: Keys.welcomed)
        accessibilityGrantedTo = defaults.string(forKey: Keys.accessibilityGrant)
        accessibilityAskedFor = defaults.string(forKey: Keys.accessibilityAsked)
        shareCardMetric = ShareCardMetric(rawValue: defaults.string(forKey: Keys.shareCardMetric) ?? "") ?? .value
        shareCardRange = ShareCardRange(rawValue: defaults.string(forKey: Keys.shareCardRange) ?? "") ?? .thirtyDays
        shareCardFormat = ShareCardFormat(rawValue: defaults.string(forKey: Keys.shareCardFormat) ?? "") ?? .feed
        shareCardTheme = defaults.string(forKey: Keys.shareCardTheme).flatMap(ShareCardTheme.init(rawValue:))
        shareCardSignature = defaults.string(forKey: Keys.shareCardSignature) ?? ""
        shareCardHidden = Set((defaults.array(forKey: Keys.shareCardHidden) as? [String] ?? []).compactMap(ToolID.init(rawValue:)))
        offerShareCardAfterUpdate = defaults.object(forKey: Keys.offerShareCard) as? Bool ?? true
        shareCardOfferPending = defaults.string(forKey: Keys.shareCardOfferPending)
        lastLaunchedVersion = defaults.string(forKey: Keys.lastLaunchedVersion)
        let status = SMAppService.mainApp.status
        launchAtLoginStatus = status
        launchAtLogin = status == .enabled
        Money.configure(code: currencyConversion.code, rate: currencyConversion.rate)
        Keychain.setPolicy(keychainPrompts)
        NetworkSession.configure(proxy: proxyURL)
        DiagnosticLog.verbose = debugLogging
        // Written here rather than by the observers, which do not run in an initialiser: a tool switched on for this
        // install once is on the stored lists, and ToolMigration's record of the tools met means switching it off
        // afterwards sticks.
        if !introduced.isEmpty {
            if defaults.array(forKey: Keys.enabledTools) != nil { defaults.set(enabledTools.map(\.rawValue).sorted(), forKey: Keys.enabledTools) }
            if defaults.array(forKey: Keys.costCardTools) != nil { defaults.set(costCardTools.map(\.rawValue).sorted(), forKey: Keys.costCardTools) }
        }
    }

    /// A stored set of assistants, names that are no assistant dropped.
    private static func tools(_ defaults: UserDefaults, _ key: String) -> Set<ToolID> {
        Set((defaults.array(forKey: key) as? [String] ?? []).compactMap(ToolID.init(rawValue:)))
    }

    private nonisolated static func codable<T: Decodable>(_ defaults: UserDefaults, _ key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// The rate the costs convert at, from the defaults alone: what `init` resolves, and what the command-line
    /// report resolves without building a Preferences.
    nonisolated static func currencyConversion(_ defaults: UserDefaults, now: Date) -> CurrencyConversion {
        CurrencyConversion.resolve(code: defaults.string(forKey: Keys.currencyCode) ?? "USD",
                                   typed: defaults.object(forKey: Keys.currencyRate) as? Double ?? 1,
                                   fetch: defaults.bool(forKey: Keys.fetchCurrencyRate),
                                   cache: ReferenceRateCache.load(defaults), now: now)
    }

    /// A budget from the defaults: as kept since 0.9.0 or, once, the dollar figure builds before it kept,
    /// re-expressed in the currency shown at the rate in use and written back, so that it goes on being the figure
    /// it was on the day it is first read. The old key is removed with it: a budget cleared later must not come
    /// back from it at the next launch.
    nonisolated static func budget(_ defaults: UserDefaults, key: String, legacy: String, at conversion: CurrencyConversion) -> Budget? {
        if let budget: Budget = codable(defaults, key) { return budget }
        guard let usd = defaults.object(forKey: legacy) as? Double else { return nil }
        defaults.removeObject(forKey: legacy)
        guard usd.isFinite, usd > 0 else { return nil }
        let budget = Budget(amount: usd * conversion.rate, code: conversion.code, rate: conversion.rate)
        if let data = try? JSONEncoder().encode(budget) { defaults.set(data, forKey: key) }
        return budget
    }

    /// The budgets in dollars from the defaults alone, for the command-line report, which builds no Preferences.
    nonisolated static func budgetsUSD(defaults: UserDefaults, now: Date = Date()) -> (monthly: Double?, weekly: Double?) {
        let conversion = currencyConversion(defaults, now: now)
        return (budget(defaults, key: Keys.monthlyBudget, legacy: Keys.legacyMonthlyBudget, at: conversion)?.usd(at: conversion),
                budget(defaults, key: Keys.weeklyBudget, legacy: Keys.legacyWeeklyBudget, at: conversion)?.usd(at: conversion))
    }

    private func storeCodable<T: Encodable>(_ value: T?, forKey key: String) {
        if let value, let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
        refreshLaunchAtLogin()
        report(Keys.launchAtLogin, launchAtLogin, changed: true)
    }

    /// Re-reads the login item's status: the user may have approved it in System Settings meanwhile.
    func refreshLaunchAtLogin() {
        let status = SMAppService.mainApp.status
        launchAtLoginStatus = status
        launchAtLogin = status == .enabled
    }

    /// Moves a tool one place up (-1) or down (+1); nothing happens at the ends.
    func move(_ tool: ToolID, by offset: Int) {
        guard let index = toolOrder.firstIndex(of: tool), toolOrder.indices.contains(index + offset) else { return }
        toolOrder.swapAt(index, index + offset)
    }

    /// Hidden by the user, or hidden by default and not revealed.
    func isHidden(_ window: LimitWindow, of tool: ToolID) -> Bool {
        if window.hiddenByDefault { return !(revealedWindows[tool]?.contains(window.id) ?? false) }
        return hiddenWindows[tool]?.contains(window.id) ?? false
    }

    func setHidden(_ hidden: Bool, window: LimitWindow, of tool: ToolID) {
        if window.hiddenByDefault {
            var set = revealedWindows[tool] ?? []
            if hidden { set.remove(window.id) } else { set.insert(window.id) }
            revealedWindows[tool] = set.isEmpty ? nil : set
        } else {
            var set = hiddenWindows[tool] ?? []
            if hidden { set.insert(window.id) } else { set.remove(window.id) }
            hiddenWindows[tool] = set.isEmpty ? nil : set
        }
    }

    /// The reading's windows in the order the card shows them, hidden ones left out, and never empty while the
    /// reading has a window: a preference that hides every one reads as "show the first" (WindowFloor).
    func shownWindows(of reading: UsageReading) -> [LimitWindow] {
        WindowFloor.shown(reading.windows) { isHidden($0, of: reading.tool) }
    }

    /// The Hide checkbox's write. Before it applies, a window the floor is showing against its stored preference
    /// (every window hidden by a build before 0.6.0) is unhidden in the preference too, so that revealing a second
    /// window does not make the first one vanish: without this the card would show A on the floor's say-so, the
    /// user would reveal B, and A would drop out because the preference still said hidden. The Hide toggles then
    /// say what the card shows, which is the only state a checkbox can honestly hold.
    func setHidden(_ hidden: Bool, window: LimitWindow, in reading: UsageReading) {
        for shown in shownWindows(of: reading) where isHidden(shown, of: reading.tool) { setHidden(false, window: shown, of: reading.tool) }
        setHidden(hidden, window: window, of: reading.tool)
    }

    /// The derived "All models" window, when the windows on show have two or more model-scoped figures to combine
    /// (CombinedWindow). Built from the shown windows only, so it never describes windows the card is hiding.
    func combinedWindow(of reading: UsageReading) -> LimitWindow? {
        CombinedWindow.of(windows: shownWindows(of: reading))
    }

    /// What a ring picker lists: every window, not only the shown ones (hiding them all once left the pickers
    /// empty), and the derived "All models" whenever the reading has model figures to combine, shown or not. Before
    /// 0.7.3 it was offered only while the card showed the model windows, and Cursor hides those by default when
    /// its included total is metered, so the one choice that covers both models was two Hide boxes away.
    func ringChoices(of reading: UsageReading) -> [LimitWindow] {
        reading.windows + [CombinedWindow.of(reading: reading)].compactMap { $0 }
    }

    /// What the panel's window list draws: the shown windows, with the derived combined window at the top when
    /// one exists, so its caption reads onto the windows it was combined from.
    func panelWindows(of reading: UsageReading) -> [LimitWindow] {
        guard let combined = combinedWindow(of: reading) else { return shownWindows(of: reading) }
        return [combined] + shownWindows(of: reading)
    }

    /// The windows the rings show: the chosen ids when they exist in the reading, else the first two shown. The
    /// hidden set is what `shownWindows(of:)` leaves out, floor included, so the rings are never empty for a tool
    /// that has a window.
    func ringWindows(of reading: UsageReading) -> [LimitWindow] {
        let shown = Set(shownWindows(of: reading).map(\.id))
        return RingSelection.windows(of: reading, chosen: ringWindows[reading.tool] ?? [], hidden: Set(reading.windows.map(\.id)).subtracting(shown))
    }

    /// A ring picker's write: `id` for the ring at `index` (outermost first), "" for none. Choosing a window for a
    /// ring asks to see it: a hidden one would be filtered out of the rings and the picker would snap back to what
    /// it showed before, with no word about the Hide box behind it. The reveal goes through the reading like the
    /// Hide checkbox does (`setHidden(_:window:in:)`), not the raw preference: with a pre-0.6.0 dictionary that
    /// hides every window, the floor is showing the first one, and a raw reveal of the pick would leave that
    /// stored "hidden" in force, so the floored window dropped off the card and the outer ring snapped onto the
    /// pick, as if the choice had landed on the wrong ring. Emptying a ring closes the gap: the rings are drawn
    /// outermost first, so a chosen third with no second would otherwise be stored as a second anyway.
    func setRingWindow(at index: Int, to id: String, in reading: UsageReading) {
        if let window = reading.windows.first(where: { $0.id == id }), isHidden(window, of: reading.tool) {
            setHidden(false, window: window, in: reading)
        }
        // "All models" is combined from the shown windows only, so choosing it shows the model windows it stands
        // for: a combined ring over windows the card hides would describe figures the card does not.
        if id == CombinedWindow.id {
            for window in reading.windows where window.model != nil && window.usedFraction != nil && isHidden(window, of: reading.tool) {
                setHidden(false, window: window, in: reading)
            }
        }
        let ring = ringWindows(of: reading)
        var ids = (0..<RingSelection.maximum).map { ring.indices.contains($0) ? ring[$0].id : "" }
        ids[index] = id
        ringWindows[reading.tool] = ids.filter { !$0.isEmpty }
    }

    func resetLine(for window: LimitWindow, stale: Bool = false, now: Date = Date()) -> String {
        ResetText.line(resetsAt: window.resetsAt, hasLimit: window.usedFraction != nil, display: resetDisplay, timeFormat: timeFormat,
                       stale: stale, unused: window.usedFraction == 0, now: now)
    }

    func usageLine(for window: LimitWindow) -> String? {
        guard let used = window.usedFraction else { return nil }
        switch usageDisplay {
        case .used: return L("%ld%% used", Int((used * 100).rounded()))
        case .left: return L("%ld%% left", Int(((1 - used) * 100).rounded()))
        }
    }

    /// Notifications are held between the quiet hours, local time.
    func isQuietHour(at date: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard quietHoursEnabled else { return false }
        return QuietHours.contains(minute: calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date),
                                   start: quietHoursStart, end: quietHoursEnd)
    }

    /// The peak window that applies to a tool, when one does.
    func peakHours(for tool: ToolID) -> PeakHours? {
        peakHours.enabled && peakHoursTools.contains(tool) ? peakHours : nil
    }

    // MARK: - Per-assistant gates

    /// Whether this assistant's hook events reach the session tracker (`sessionReadingOff`).
    func readsSessions(of tool: ToolID) -> Bool {
        !sessionReadingOff.contains(tool)
    }

    /// Whether a request from this assistant is held for an answer in the notch: the app-wide switch, its sessions
    /// read, and its own page's switch. The first two are asked here too so the one call is the whole rule, and a
    /// page's toggle can say it is off without repeating how.
    func answersFromNotch(_ tool: ToolID) -> Bool {
        answerFromNotch && readsSessions(of: tool) && !notchAnswersOff.contains(tool)
    }

    /// Whether this assistant's limit notices may go out. The app-wide switch is asked where it always was
    /// (UsageStore.evaluateAlerts, checkResets), before anything is planned; this is the page's own part.
    func notifiesLimits(of tool: ToolID) -> Bool {
        !limitNoticesOff.contains(tool)
    }

    /// Whether this assistant's waiting and finished-turn notices may go out; the page's own part, as above.
    func notifiesSessions(of tool: ToolID) -> Bool {
        !sessionNoticesOff.contains(tool)
    }

    /// The write behind each page's toggles: one assistant in or out of an off-set, the set left alone when it
    /// already says so, so a redraw that re-sets the same value reports no change.
    static func switching(_ tools: Set<ToolID>, _ tool: ToolID, on: Bool) -> Set<ToolID> {
        var tools = tools
        if on { tools.remove(tool) } else { tools.insert(tool) }
        return tools
    }

    /// What a notice of this category plays: its chosen sound, or "none" while the category is silenced or the
    /// Play sounds switch is off.
    func sound(for category: SoundCategory) -> String {
        guard notificationSound, !silencedSounds.contains(category) else { return NotificationSound.none }
        return soundChoice(for: category)
    }

    /// The category's chosen sound, silenced or not: what its picker shows.
    func soundChoice(for category: SoundCategory) -> String {
        soundChoices[category] ?? NotificationSound.defaultChoice(for: category)
    }

    /// Ticks or clears one category's Silence box.
    func setSilenced(_ silenced: Bool, _ category: SoundCategory) {
        if silenced { silencedSounds.insert(category) } else { silencedSounds.remove(category) }
    }

    /// Every category's sound as a notice would play it now, for the oracle's snapshot.
    var soundFields: [String: String] {
        Dictionary(uniqueKeysWithValues: SoundCategory.allCases.map { ($0.rawValue, sound(for: $0)) })
    }

    /// The key a category's choice is written under: the first of `soundKeys(for:)`.
    static func soundKey(for category: SoundCategory) -> String {
        soundKeys(for: category)[0]
    }

    /// Where a category's choice is read from, its own key first and then the keys of the earlier builds whose
    /// choice it carries on. Completion and limit are the Turn finished and Pace crossing rows under their old
    /// keys. The three stopped kinds of wait fall back to 0.7.9's single waiting sound. The waiting reminder falls
    /// back to the permission sound, and through it to 0.7.9's: through 0.8.0 Claude Code's idle reminder and a
    /// quiet Cursor turn played the permission sound, so someone who picked one hears it there until they pick
    /// the reminder a sound of its own. Only a key the user actually wrote counts; a key never written is absent,
    /// and the chain goes on past it.
    static func soundKeys(for category: SoundCategory) -> [String] {
        switch category {
        case .completion: [Keys.soundFinished]
        case .waiting: [Keys.soundWaitingReminder, Keys.soundPermission, Keys.soundWaiting]
        case .permission: [Keys.soundPermission, Keys.soundWaiting]
        case .question: [Keys.soundQuestion, Keys.soundWaiting]
        case .plan: [Keys.soundPlan, Keys.soundWaiting]
        case .limit: [Keys.soundPace]
        }
    }

    /// The key a category's Silence box is kept under.
    static func silenceKey(for category: SoundCategory) -> String {
        switch category {
        case .completion: Keys.silenceCompletion
        case .waiting: Keys.silenceWaiting
        case .permission: Keys.silencePermission
        case .question: Keys.silenceQuestion
        case .plan: Keys.silencePlan
        case .limit: Keys.silenceLimit
        }
    }

    /// A category's sound and Silence box as stored. The choice is the first key of `soundKeys(for:)` that holds
    /// one, so someone who chose Glass for every wait in 0.7.9 still hears Glass for each kind, and only someone
    /// who never chose at all gets the category's own default (`NotificationSound.defaultChoice(for:)`), which is
    /// where the six first sound different. The old keys are consulted rather than copied, so a pick on one row
    /// changes that row alone.
    ///
    /// A stored None — the only way to quiet a kind before the boxes existed — is read as the box ticked, with the
    /// category's default as the sound it returns to if the box is cleared: someone who silenced waits does not
    /// start hearing them after an update, and the picker never has to show a choice it no longer offers. Once the
    /// box has been touched its own key decides. Nothing here writes: the None stays where an earlier build can
    /// still find it.
    static func storedSound(_ category: SoundCategory, defaults: UserDefaults,
                            installed: [String] = NotificationSound.systemSounds()) -> (choice: String, silenced: Bool) {
        let stored = soundKeys(for: category).lazy.compactMap { defaults.string(forKey: $0) }.first
        let silenced = defaults.object(forKey: silenceKey(for: category)) as? Bool ?? (stored == NotificationSound.none)
        let choice = stored.flatMap { $0 == NotificationSound.none ? nil : $0 }
            ?? NotificationSound.defaultChoice(for: category, installed: installed)
        return (choice, silenced)
    }

    /// Resolves the rate from the settings and the cached rates and hands it to `Money`. Written only on a change,
    /// because every write to an observed property re-draws whatever reads it, and the fetcher calls this on each
    /// of its checks so that a rate past its week gives way without waiting for a request.
    func applyCurrency(now: Date = Date()) {
        let resolved = CurrencyConversion.resolve(code: currencyCode, typed: currencyRate, fetch: fetchCurrencyRate,
                                                  cache: referenceRateCache, now: now)
        Money.configure(code: resolved.code, rate: resolved.rate)
        guard resolved != currencyConversion else { return }
        currencyConversion = resolved
        Oracle.shared.emit("currency", resolved.oracleFields)
    }

    /// A request is about to be made: its time is written first, so one the app never comes back from still
    /// leaves its mark, and nothing is counted as failed until an answer says so (ReferenceRateCache).
    func recordRateRequest(at now: Date) {
        referenceRateCache.lastAttempt = now
        referenceRateCache.save(defaults)
    }

    /// The request came back: new rates replace the old and clear the failures. A request that brought nothing
    /// counts as one more failure in a row and leaves the old rates in place, where they go on being used until
    /// they are a week old.
    func recordRates(_ rates: ReferenceRates?, now: Date = Date()) {
        if let rates {
            referenceRateCache.rates = rates
            referenceRateCache.failures = 0
        } else {
            referenceRateCache.failures += 1
        }
        referenceRateCache.save(defaults)
        applyCurrency(now: now)
    }

    /// Empties this app's defaults domain; the caller relaunches, so nothing here needs to be re-read.
    static func resetAll(defaults: UserDefaults = .standard, bundleIdentifier: String? = Bundle.main.bundleIdentifier) {
        if let bundleIdentifier {
            defaults.removePersistentDomain(forName: bundleIdentifier)
        } else {
            for key in defaults.dictionaryRepresentation().keys { defaults.removeObject(forKey: key) }
        }
        defaults.synchronize()
    }

    /// The oracle hears about changes only; the edge, the order and the compact style have events of their own.
    private func report(_ key: String, _ value: Any, changed: Bool, event: String = "pref") {
        guard changed else { return }
        Oracle.shared.emit(event, event == "pref" ? ["key": key, "value": value] : [key: value])
    }
}

enum QuietHours {
    /// A window that ends before it starts wraps past midnight: 22:00 to 08:00 covers the night.
    static func contains(minute: Int, start: Int, end: Int) -> Bool {
        if start == end { return false }
        if start < end { return minute >= start && minute < end }
        return minute >= start || minute < end
    }
}

/// The windows the compact rings draw: chosen ids first, in the chosen order, filled up to `fallback` from the
/// reading's own order, hidden windows never. The derived combined window is selectable but never fills a ring on
/// its own, so an install that chose nothing keeps the two rings it has always had.
enum RingSelection {
    /// The most rings a readout draws, outermost first.
    static let maximum = 3
    /// How many the rings fall back to when nothing was chosen.
    static let fallback = 2

    static func windows(of reading: UsageReading, chosen: [String], hidden: Set<String>) -> [LimitWindow] {
        let shown = reading.windows.filter { !hidden.contains($0.id) }
        let selectable = shown + [CombinedWindow.of(windows: shown)].compactMap { $0 }
        var result: [LimitWindow] = []
        for id in chosen {
            if let window = selectable.first(where: { $0.id == id }), !result.contains(where: { $0.id == id }) { result.append(window) }
        }
        // Windows that publish a figure come first when nothing was chosen: a plan whose headline window has no
        // limit (Cursor Free's "Included usage") would otherwise fill the rings with a tool that shows nothing.
        //
        // How many to fill to is the number the user chose, not the fallback: a single chosen ring is a choice
        // ("just the session"), and topping it up to two made one ring impossible to have — Settings stored the
        // one id, this put a second window back, and the Inner ring picker snapped from None to that window. The
        // fallback applies only when nothing chosen survives (nothing chosen, or every chosen id gone or hidden),
        // and a choice whose ids are partly gone or repeated is still filled to the count that was asked for.
        // An explicit choice wins even where it draws an empty ring (RingsPreferWindowsWithFigures), with one
        // exception: a choice that would draw only empty rings while a comparison window is on show yields to
        // the data. A comparison window exists only because the vendor meters nothing on the seat, so the choice
        // is of meters that have stopped: Cursor's model meters lose their 0 % behind Today's spend
        // (CursorProvider.withoutDeadSplits) and the rings move to it. The choice is not rewritten; the day a
        // meter counts again it is honoured as before.
        if !result.isEmpty, result.allSatisfy({ $0.usedFraction == nil }), shown.contains(where: { $0.isComparison && $0.usedFraction != nil }) {
            result = []
        }
        let target = result.isEmpty ? fallback : chosen.count
        let byData = shown.filter { $0.usedFraction != nil } + shown.filter { $0.usedFraction == nil }
        for window in byData where result.count < target && !result.contains(where: { $0.id == window.id }) {
            result.append(window)
        }
        return Array(result.prefix(maximum))
    }
}

/// A tool's last shown window cannot be hidden. Until 0.6.0 the Hide checkboxes had no floor: hiding every window
/// of a tool emptied its card and its rings, and until 0.5.0 blanked its menu bar item to a clickable gap
/// (MenuBarItem.glyph). The gauge fallback there treated the symptom; this is the root. Two rules, both pure so
/// they are testable without a Preferences or a view: which windows are shown given the preference, and whether a
/// given window's checkbox may still hide it.
enum WindowFloor {
    /// The windows the preference leaves visible, in the reading's order. When it leaves none and there are
    /// windows, the first one the vendor meant to be seen (not `hiddenByDefault`) is shown anyway, falling back
    /// to the first of all when the reading has only default-hidden windows. A preference written by an older
    /// build with every window hidden therefore reads as "show the first" rather than nothing, whatever way it
    /// got there.
    static func shown(_ windows: [LimitWindow], hidden: (LimitWindow) -> Bool) -> [LimitWindow] {
        let shown = windows.filter { !hidden($0) }
        if !shown.isEmpty || windows.isEmpty { return shown }
        return [windows.first { !$0.hiddenByDefault } ?? windows[0]]
    }

    /// Whether the Hide checkbox for `window` is allowed to hide it: not when it is the one window shown. A window
    /// already hidden can always be revealed, so its checkbox stays live.
    static func canHide(_ window: LimitWindow, shown: [LimitWindow]) -> Bool {
        !(shown.count == 1 && shown[0].id == window.id)
    }
}

/// Names for the virtual key codes a shortcut recorder can show; anything else is "Key N".
enum KeyNames {
    private static let names: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
        16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
        30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "↩", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",",
        44: "/", 45: "N", 46: "M", 47: ".", 48: "⇥", 49: "Space", 50: "`", 51: "⌫", 53: "⎋", 96: "F5", 97: "F6", 98: "F7", 99: "F3",
        100: "F8", 101: "F9", 103: "F11", 109: "F10", 111: "F12", 118: "F4", 120: "F2", 122: "F1", 123: "←", 124: "→", 125: "↓", 126: "↑",
    ]

    static func name(for keyCode: UInt32) -> String {
        names[keyCode] ?? "Key \(keyCode)"
    }
}
