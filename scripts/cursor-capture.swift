// Records how Cursor draws one of its own cards, read-only, so a card Notchmeter does not recognise yet (or a Cursor
// version it has not seen) can be turned into a fixture in Tests/NotchmeterTests/CursorAccessibilityTests.swift.
//
//   swift scripts/cursor-capture.swift <out.jsonl> <seconds> "<word>,<word>;<word>,<word>;…"
//
// Each group of words (groups are separated by `;`) names the labels that mark one card: "apple,banana,cherry" for
// a question whose options you chose yourself, "Skip,Switch" for the mode card, "Skip,Run" for the Run prompt. While
// it runs, whenever the elements labelled with a group's words are on screen it writes the smallest part of the
// window's tree that holds them, two levels up, as one JSON line: roles, subroles, labels, values, enabled and
// selected states and the actions each control takes. Nothing outside that part of the window is written: no
// sidebar, no editor, no other chat. A shape already written for a group is not written again.
//
// It reads Cursor's windows through the Accessibility API and presses nothing. It needs the Accessibility
// permission for the app the terminal runs in (Cursor itself for its integrated terminal), and says so and stops
// when that is missing. While it runs Cursor is asked for its accessibility tree, which shows *Screen Reader
// Optimized* in the editor; it hands the tree back when it ends.
import AppKit
import ApplicationServices

let cursorBundleID = "com.todesktop.230313mzl4w4u92"
let skippedRoles: Set<String> = ["AXTextArea", "AXOutline", "AXScrollBar", "AXMenuBar"]
let nodeBudget = 20_000
let textLimit = 200
let subtreeLimit = 400

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 3, let seconds = Double(arguments[1]) else {
    print("usage: swift scripts/cursor-capture.swift <out.jsonl> <seconds> \"<word>,<word>;<word>,<word>\"")
    exit(2)
}
let outPath = arguments[0]
let groups: [[String]] = arguments[2].split(separator: ";").map { group in
    group.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
}.filter { !$0.isEmpty }

guard AXIsProcessTrusted() else {
    print("cursor-capture: no Accessibility permission. Grant it to the app this terminal runs in (Cursor, Terminal or iTerm) under")
    print("System Settings › Privacy & Security › Accessibility, then run this again.")
    exit(2)
}
guard let cursor = NSRunningApplication.runningApplications(withBundleIdentifier: cursorBundleID).first else {
    print("cursor-capture: Cursor is not running")
    exit(2)
}
let application = AXUIElementCreateApplication(cursor.processIdentifier)
AXUIElementSetMessagingTimeout(application, 1)
AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, kCFBooleanTrue)

final class Node {
    var role = ""
    var subrole: String?
    var title: String?
    var description: String?
    var value: String?
    var number: Double?
    var enabled = true
    var selected: Bool?
    var actions: [String] = []
    var children: [Node] = []
    weak var parent: Node?

    /// The words a control or a run of text is known by.
    var label: String {
        if role == "AXStaticText" || role == "AXHeading" { return value ?? title ?? "" }
        if let title, !title.isEmpty { return title }
        if let description, !description.isEmpty { return description }
        return children.map { $0.role == "AXStaticText" ? ($0.value ?? "") : "" }.joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    var json: [String: Any] {
        var out: [String: Any] = ["role": role]
        if let subrole { out["subrole"] = subrole }
        if let title, !title.isEmpty { out["title"] = String(title.prefix(textLimit)) }
        if let description, !description.isEmpty { out["description"] = String(description.prefix(textLimit)) }
        if let value, !value.isEmpty { out["value"] = String(value.prefix(textLimit)) }
        if let number { out["number"] = number }
        if !enabled { out["enabled"] = false }
        if let selected { out["selected"] = selected }
        if !actions.isEmpty { out["actions"] = actions }
        if !children.isEmpty { out["children"] = children.map(\.json) }
        return out
    }

    var count: Int { 1 + children.reduce(0) { $0 + $1.count } }
}

func attribute(_ element: AXUIElement, _ name: String) -> Any? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

let interactive: Set<String> = ["AXButton", "AXPopUpButton", "AXRadioButton", "AXCheckBox", "AXMenuItem", "AXMenuButton", "AXLink", "AXTextField", "AXComboBox"]

func read(_ element: AXUIElement, depth: Int, budget: inout Int) -> Node {
    budget -= 1
    let node = Node()
    node.role = attribute(element, kAXRoleAttribute) as? String ?? ""
    node.subrole = attribute(element, kAXSubroleAttribute) as? String
    node.title = attribute(element, kAXTitleAttribute) as? String
    node.description = attribute(element, kAXDescriptionAttribute) as? String
    let value = attribute(element, kAXValueAttribute)
    node.value = value as? String
    node.number = (value as? NSNumber)?.doubleValue
    node.enabled = attribute(element, kAXEnabledAttribute) as? Bool ?? true
    node.selected = attribute(element, kAXSelectedAttribute) as? Bool
    if interactive.contains(node.role) {
        var names: CFArray?
        AXUIElementCopyActionNames(element, &names)
        node.actions = (names as? [String]) ?? []
    }
    guard depth < 90, budget > 0, !skippedRoles.contains(node.role) else { return node }
    for child in (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
        guard budget > 0 else { break }
        let read = read(child, depth: depth + 1, budget: &budget)
        read.parent = node
        node.children.append(read)
    }
    return node
}

/// A label without its keyboard hint ("Switch ⌘⏎" → "switch"), as Notchmeter's CursorCards.normalized reads it.
func words(_ label: String) -> String {
    let wordy: Set<Unicode.GeneralCategory> = [.uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .otherLetter, .modifierLetter, .decimalNumber]
    let kept = label.unicodeScalars.map { wordy.contains($0.properties.generalCategory) || $0 == " " || $0 == "-" ? Character($0) : " " }
    return String(kept).split(separator: " ").joined(separator: " ").lowercased()
}

func all(_ node: Node, _ visit: (Node) -> Void) {
    visit(node)
    node.children.forEach { all($0, visit) }
}

func ancestors(_ node: Node) -> [Node] {
    var chain: [Node] = [node]
    var current = node
    while let parent = current.parent {
        chain.append(parent)
        current = parent
    }
    return chain.reversed()
}

/// The lowest node above every one of `nodes`.
func commonAncestor(_ nodes: [Node]) -> Node? {
    let chains = nodes.map(ancestors)
    guard var common = chains.first else { return nil }
    for chain in chains.dropFirst() {
        var shared: [Node] = []
        for (a, b) in zip(common, chain) where a === b { shared.append(a) }
        common = shared
    }
    return common.last
}

let handle: FileHandle
FileManager.default.createFile(atPath: outPath, contents: nil)
guard let opened = FileHandle(forWritingAtPath: outPath) else {
    print("cursor-capture: cannot write \(outPath)")
    exit(2)
}
handle = opened
let stamp = ISO8601DateFormatter()
var written: [Int: Set<String>] = [:]
var lines = 0
let version = Bundle(url: cursor.bundleURL ?? URL(fileURLWithPath: "/Applications/Cursor.app"))?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String

print("cursor-capture: watching Cursor \(version ?? "?") for \(Int(seconds)) s; groups: \(groups.map { $0.joined(separator: ",") }.joined(separator: " ; "))")
let deadline = Date().addingTimeInterval(seconds)
while Date() < deadline {
    for window in (attribute(application, kAXWindowsAttribute) as? [AXUIElement]) ?? [] {
        var budget = nodeBudget
        let root = read(window, depth: 0, budget: &budget)
        let isAgents = (attribute(window, kAXTitleAttribute) as? String) == "Cursor Agents"
        for (index, group) in groups.enumerated() {
            var anchors: [Node] = []
            var found: Set<String> = []
            all(root) { node in
                guard interactive.contains(node.role) || node.role == "AXStaticText" else { return }
                let label = words(node.label)
                if group.contains(label) {
                    anchors.append(node)
                    found.insert(label)
                }
            }
            // A card is there when every word of a short group is, or at least two of a longer one.
            guard found.count >= min(group.count, 2), var top = commonAncestor(anchors) else { continue }
            for _ in 0..<2 { if let parent = top.parent, parent.count <= subtreeLimit { top = parent } }
            guard top.count <= subtreeLimit else { continue }
            let tree = top.json
            guard let shape = try? JSONSerialization.data(withJSONObject: tree, options: [.sortedKeys]),
                  written[index, default: []].insert(String(decoding: shape, as: UTF8.self)).inserted else { continue }
            let line: [String: Any] = ["at": stamp.string(from: Date()), "cursor": version ?? "", "window": isAgents ? "agents" : "editor",
                                       "group": group.joined(separator: ","), "found": found.sorted(), "tree": tree]
            if let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) {
                handle.write(data)
                handle.write(Data("\n".utf8))
                lines += 1
                print("cursor-capture: \(group.joined(separator: ",")) seen in the \(isAgents ? "Agents" : "editor") window (\(top.count) elements)")
            }
        }
    }
    Thread.sleep(forTimeInterval: 0.7)
}
AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, kCFBooleanFalse)
try? handle.close()
print("cursor-capture: wrote \(lines) shapes to \(outPath)")
