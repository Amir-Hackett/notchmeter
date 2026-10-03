// Presses one of Notchmeter's own panel buttons through the Accessibility API, for scripts/e2e-cursor.sh: the one
// part of answering from the notch that a hook command and the oracle cannot do between them is the click.
//
//   notch-press --trusted            exit 0 when this process may use Accessibility (the terminal's grant)
//   notch-press --list               the labels of the buttons on Notchmeter's windows, one a line
//   notch-press --click <x> <y>      one click at a point in AppKit screen points (origin bottom left), to open the
//                                    panel; refused unless the frontmost window at that point is Notchmeter's own
//   notch-press <label> [seconds]    waits up to `seconds` (default 10) for a button labelled exactly so, and presses it
//
// It reads and presses Notchmeter's windows only, never another app's.
import AppKit
import ApplicationServices

let bundleID = "com.amirhackett.notchmeter"
let arguments = Array(CommandLine.arguments.dropFirst())

func attribute(_ element: AXUIElement, _ name: String) -> Any? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

/// Every button on the running app's windows with its label: the accessibility label a view sets, else its title.
func buttons() -> [(label: String, element: AXUIElement)] {
    var found: [(String, AXUIElement)] = []
    func walk(_ element: AXUIElement, _ depth: Int) {
        guard depth < 60 else { return }
        if attribute(element, kAXRoleAttribute) as? String == "AXButton" {
            let label = [attribute(element, kAXDescriptionAttribute) as? String, attribute(element, kAXTitleAttribute) as? String]
                .compactMap { $0 }.first { !$0.isEmpty }
            if let label { found.append((label, element)) }
        }
        for child in (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { walk(child, depth + 1) }
    }
    for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 1)
        for window in (attribute(root, kAXWindowsAttribute) as? [AXUIElement]) ?? [] { walk(window, 0) }
    }
    return found
}

guard let first = arguments.first else {
    print("usage: notch-press --trusted | --list | --click <x> <y> | <label> [seconds]")
    exit(2)
}
switch first {
case "--trusted":
    exit(AXIsProcessTrusted() ? 0 : 1)
case "--list":
    guard AXIsProcessTrusted() else { print("no Accessibility permission"); exit(2) }
    buttons().forEach { print($0.label) }
case "--click":
    guard arguments.count == 3, let x = Double(arguments[1]), let y = Double(arguments[2]), let screen = NSScreen.screens.first else { exit(2) }
    let point = CGPoint(x: x, y: screen.frame.height - y)
    // A click is desktop-wide, so it is posted only where the window in front at that point is Notchmeter's: a notch
    // that has moved, or is not there, must not turn this into a click on whatever else is.
    let own = Set(NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).map { Int($0.processIdentifier) })
    let onScreen = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
    let front = onScreen.first { window in
        guard let bounds = window[kCGWindowBounds as String] as? [String: CGFloat] else { return false }
        return CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0).contains(point)
    }
    guard let owner = front?[kCGWindowOwnerPID as String] as? Int, own.contains(owner) else {
        print("no Notchmeter window at \(Int(x)), \(Int(y)): not clicking")
        exit(1)
    }
    let source = CGEventSource(stateID: .hidSystemState)
    CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    usleep(150_000)
    CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    usleep(60_000)
    CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
default:
    guard AXIsProcessTrusted() else { print("no Accessibility permission"); exit(2) }
    let deadline = Date().addingTimeInterval(arguments.count > 1 ? Double(arguments[1]) ?? 10 : 10)
    repeat {
        if let button = buttons().first(where: { $0.label == first }) {
            let result = AXUIElementPerformAction(button.element, kAXPressAction as CFString)
            print(result == .success ? "pressed \(first)" : "press failed (\(result.rawValue)): \(first)")
            exit(result == .success ? 0 : 1)
        }
        Thread.sleep(forTimeInterval: 0.25)
    } while Date() < deadline
    print("no button labelled \(first)")
    exit(1)
}
