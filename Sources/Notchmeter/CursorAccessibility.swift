import AppKit
import ApplicationServices
import Foundation

/// What a row's plan buttons ask for (SessionsCard, UsageStore.cursorPlanAction).
enum CursorPlanAction: String, Sendable {
    case view, build
}

/// Cursor's own cards — a command waiting for Run, a mode-switch confirmation, a created plan's Build — have no
/// hook event; they exist only in Cursor's window. With *Mirror Cursor's cards* on (Preferences.cursorControl) and
/// the Accessibility permission granted, the app reads Cursor's windows through the Accessibility API, never a
/// screenshot, recognises those cards by their buttons, shows them on the session's row with the options Cursor
/// shows, and presses the one chosen. Nothing is ever pressed without re-reading the same card first, and a
/// press counts only once the card has gone.
struct CursorAXNode: Equatable, Sendable {
    var role: String
    /// A button's title (or its description, or its text children's), a static text's value.
    var label: String?
    var enabled = true
    var children: [CursorAXNode] = []
}

struct CursorCard: Equatable, Sendable, Identifiable {
    enum Kind: String, Sendable, CaseIterable {
        /// A shell command or MCP call waiting for Run.
        case run
        /// "Switch to Plan Mode?": Always ask, Skip, Switch.
        case modeSwitch
        /// A created plan: View Plan, Build.
        case plan
    }

    struct Option: Equatable, Sendable, Hashable {
        /// The button's words as Cursor shows them, its shortcut glyphs dropped.
        let label: String
        /// Child indexes from the window down to the button.
        let path: [Int]
    }

    let kind: Kind
    /// The window's title, which names the workspace (CursorCards.session(for:among:)).
    let window: String
    /// The card's own words: the destination mode, the plan's name, the command; at most `CursorCards.headingLimit`.
    let heading: String?
    let options: [Option]

    /// Stable while the same card is on screen, and different for the next one.
    var id: String { [kind.rawValue, window, heading ?? "", options.map(\.label).joined(separator: "|")].joined(separator: "\u{1F}") }
    /// Whether the card holds the turn until it is answered (a plan card waits for nobody).
    var blocksTurn: Bool { kind != .plan }
}

enum CursorCards {
    static let headingLimit = 160

    /// The buttons that make each kind of card, in Cursor's words, lowercased; and the buttons it may also carry.
    static let signatures: [CursorCard.Kind: (required: [Set<String>], optional: Set<String>)] = [
        .modeSwitch: ([["switch"], ["skip"]], ["always ask"]),
        .plan: ([["build"], ["view plan"]], []),
        .run: ([["run"], ["skip", "reject", "deny", "cancel"]], ["allow", "always allow", "allowlist", "add to allowlist", "run always", "run everything"]),
    ]

    /// A button's words without its keyboard hint ("Switch ⌘⏎" → "Switch").
    static func normalized(_ label: String?) -> String? {
        guard let label else { return nil }
        // Letters and digits by category: CharacterSet.letters also holds marks, among them the variation
        // selector that follows a glyph such as ↩︎.
        let wordy: Set<Unicode.GeneralCategory> = [.uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .otherLetter, .modifierLetter, .decimalNumber]
        let kept = label.unicodeScalars.map { wordy.contains($0.properties.generalCategory) || $0 == " " || $0 == "-" ? Character($0) : " " }
        let words = String(kept).split(separator: " ").joined(separator: " ")
        return words.isEmpty ? nil : words
    }

    /// Every card in one window's tree: for each kind, the smallest container whose buttons carry the kind's
    /// signature. The options are the signature's buttons in the order Cursor lays them out.
    static func detect(in window: CursorAXNode, title: String) -> [CursorCard] {
        var found: [CursorCard] = []
        _ = visit(window, path: [], title: title, found: &found)
        return found
    }

    private struct Gathered {
        var buttons: [(label: String, path: [Int], enabled: Bool)] = []
        var texts: [String] = []
        var kinds: Set<CursorCard.Kind> = []
    }

    private static func visit(_ node: CursorAXNode, path: [Int], title: String, found: inout [CursorCard]) -> Gathered {
        var gathered = Gathered()
        if node.role == "AXButton", let label = normalized(node.label) {
            gathered.buttons.append((label, path, node.enabled))
        } else if node.role == "AXStaticText" || node.role == "AXHeading", let text = node.label?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            gathered.texts.append(text)
        }
        // A button's own text children name the button, not the card.
        if node.role != "AXButton" {
            for (index, child) in node.children.enumerated() {
                let sub = visit(child, path: path + [index], title: title, found: &found)
                gathered.buttons += sub.buttons
                gathered.texts += sub.texts
                gathered.kinds.formUnion(sub.kinds)
            }
        }
        var emitted = false
        for kind in CursorCard.Kind.allCases where !gathered.kinds.contains(kind) {
            guard let signature = signatures[kind] else { continue }
            let labels = Set(gathered.buttons.map { $0.label.lowercased() })
            guard signature.required.allSatisfy({ !$0.isDisjoint(with: labels) }) else { continue }
            let wanted = signature.required.reduce(signature.optional) { $0.union($1) }
            var seen = Set<String>()
            let options = gathered.buttons.filter { wanted.contains($0.label.lowercased()) && $0.enabled && seen.insert($0.label.lowercased()).inserted }
                .map { CursorCard.Option(label: $0.label, path: $0.path) }
            found.append(CursorCard(kind: kind, window: title, heading: heading(kind, texts: gathered.texts), options: options))
            gathered.kinds.insert(kind)
            emitted = true
        }
        // A card's buttons and words are its own: an ancestor cannot pair them with another card's.
        if emitted {
            gathered.buttons = []
            gathered.texts = []
        }
        return gathered
    }

    private static func heading(_ kind: CursorCard.Kind, texts: [String]) -> String? {
        let text: String?
        switch kind {
        case .modeSwitch: text = texts.first { $0.hasPrefix("Switch to") } ?? texts.first
        case .plan:
            if let index = texts.firstIndex(where: { $0.caseInsensitiveCompare("Created Plan") == .orderedSame }), texts.indices.contains(index + 1) {
                text = texts[index + 1]
            } else {
                text = texts.first
            }
        case .run: text = texts.first
        }
        guard let text else { return nil }
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return line.count > headingLimit ? String(line.prefix(headingLimit)) + "…" : line
    }

    /// The Cursor session a window belongs to: the one whose project the window's title names (" — " separates
    /// Cursor's title parts), the most recently active when several do; else the only Cursor session there is.
    static func session(for window: String, among sessions: [AgentSession]) -> String? {
        let cursor = sessions.filter { $0.tool == .cursor && $0.host == nil }
        let parts = Set(window.components(separatedBy: " — ").map { $0.trimmingCharacters(in: .whitespaces) })
        let named = cursor.filter { $0.project.map(parts.contains) ?? false }
        if let best = named.max(by: { $0.lastEvent < $1.lastEvent }) { return best.id }
        return cursor.count == 1 ? cursor[0].id : nil
    }

    /// The plan card for a plan named `name`, when exactly one is on screen.
    static func planCard(named name: String?, in cards: [CursorCard]) -> CursorCard? {
        let plans = cards.filter { $0.kind == .plan }
        if let name {
            let matching = plans.filter { $0.heading == name }
            if matching.count == 1 { return matching[0] }
        }
        return plans.count == 1 ? plans[0] : nil
    }
}

enum CursorPressResult: String, Sendable {
    /// Pressed, and the card went.
    case pressed
    /// Pressed, and the card is still there.
    case stillShown
    /// The card or the button was gone, or no longer the same, when re-read: nothing pressed.
    case gone
    /// No Accessibility permission, or Cursor is not running.
    case unavailable
}

/// Reading and pressing Cursor's cards; the live one uses the Accessibility API, tests use a fake.
protocol CursorUIControlling: Sendable {
    var trusted: Bool { get }
    func scan() -> [CursorCard]
    func press(_ card: CursorCard, option: String) -> CursorPressResult
}

final class LiveCursorUI: CursorUIControlling, @unchecked Sendable {
    /// Cursor's tree is a whole editor; the chat's cards sit in the first few thousand nodes of a window, and an
    /// editor's text or a file tree is skipped whole.
    static let nodeBudget = 20_000
    static let depthLimit = 90
    static let skippedRoles: Set<String> = ["AXTextArea", "AXOutline", "AXScrollBar", "AXMenuBar"]

    var trusted: Bool { AXIsProcessTrusted() }

    /// Shows macOS's own prompt for the permission; called only when the user turns the setting on.
    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    private func application() -> AXUIElement? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: TerminalJump.BundleID.cursor).first else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.5)
        // Chromium builds its web content's tree only for a client that asks for it this way.
        AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        return element
    }

    private func windows(of app: AXUIElement) -> [AXUIElement] {
        (attribute(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
    }

    func scan() -> [CursorCard] {
        guard trusted, let app = application() else { return [] }
        var cards: [CursorCard] = []
        for window in windows(of: app) {
            var budget = Self.nodeBudget
            let title = attribute(window, kAXTitleAttribute) as? String ?? ""
            let tree = snapshot(window, depth: 0, budget: &budget)
            cards += CursorCards.detect(in: tree, title: title)
        }
        return cards
    }

    func press(_ card: CursorCard, option: String) -> CursorPressResult {
        guard trusted, let app = application() else { return .unavailable }
        // The same card, read again: same window, same words, same buttons.
        guard let window = windows(of: app).first(where: { (attribute($0, kAXTitleAttribute) as? String ?? "") == card.window }) else { return .gone }
        var budget = Self.nodeBudget
        let current = CursorCards.detect(in: snapshot(window, depth: 0, budget: &budget), title: card.window)
        guard let same = current.first(where: { $0.id == card.id }), let target = same.options.first(where: { $0.label == option }),
              let element = element(at: target.path, from: window),
              CursorCards.normalized(label(of: element)) == option else { return .gone }
        guard AXUIElementPerformAction(element, kAXPressAction as CFString) == .success else { return .gone }
        for _ in 0..<10 {
            Thread.sleep(forTimeInterval: 0.25)
            var again = Self.nodeBudget
            let after = CursorCards.detect(in: snapshot(window, depth: 0, budget: &again), title: card.window)
            if !after.contains(where: { $0.id == card.id }) { return .pressed }
        }
        return .stillShown
    }

    private func snapshot(_ element: AXUIElement, depth: Int, budget: inout Int) -> CursorAXNode {
        budget -= 1
        let role = attribute(element, kAXRoleAttribute) as? String ?? ""
        var node = CursorAXNode(role: role, label: nil, enabled: attribute(element, kAXEnabledAttribute) as? Bool ?? true)
        guard depth < Self.depthLimit, budget > 0, !Self.skippedRoles.contains(role) else { return node }
        let children = (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
        for child in children {
            guard budget > 0 else { break }
            node.children.append(snapshot(child, depth: depth + 1, budget: &budget))
        }
        node.label = label(of: element) ?? (role == "AXButton" ? Self.text(in: node) : nil)
        return node
    }

    private func label(of element: AXUIElement) -> String? {
        let role = attribute(element, kAXRoleAttribute) as? String ?? ""
        if role == "AXStaticText" || role == "AXHeading" {
            return (attribute(element, kAXValueAttribute) as? String) ?? (attribute(element, kAXTitleAttribute) as? String)
        }
        for key in [kAXTitleAttribute, kAXDescriptionAttribute] {
            if let text = attribute(element, key) as? String, !text.isEmpty { return text }
        }
        return nil
    }

    private static func text(in node: CursorAXNode) -> String? {
        let words = node.children.compactMap { child in child.role == "AXStaticText" ? child.label : text(in: child) }.joined(separator: " ")
        return words.isEmpty ? nil : words
    }

    private func element(at path: [Int], from root: AXUIElement) -> AXUIElement? {
        var current = root
        for index in path {
            guard let children = attribute(current, kAXChildrenAttribute) as? [AXUIElement], children.indices.contains(index) else { return nil }
            current = children[index]
        }
        return current
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> Any? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
}

/// View Plan: the plan file, opened in Cursor itself (its editor shows the plan with its own Build button).
enum CursorPlanOpener {
    @MainActor static func open(_ path: String) -> Bool {
        guard let url = CursorPlanFiles.allowed(path) else { return false }
        let workspace = NSWorkspace.shared
        guard let app = workspace.urlForApplication(withBundleIdentifier: TerminalJump.BundleID.cursor) else {
            return workspace.open(url)
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        workspace.open([url], withApplicationAt: app, configuration: configuration)
        return true
    }

    @MainActor static func activateCursor() {
        NSRunningApplication.runningApplications(withBundleIdentifier: TerminalJump.BundleID.cursor).first?.activate()
    }
}
