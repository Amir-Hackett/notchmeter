import AppKit

/// `--smoke --hover-sim`: a scripted pointer path through the live controller's HoverDriver, in real time, so the
/// open/close loop can be checked without a hand on the mouse. The driver's monitors, dwell re-sample, tick and
/// settle calls all run for real; only where the pointer is comes from the script. Prints every decision.
@MainActor
final class HoverSimulation {
    private let hover: HoverDriver
    private let started = ProcessInfo.processInfo.systemUptime
    private var location = CGPoint.zero
    private var inside = false
    private var expands = 0
    private var collapses = 0
    private var collapsedWhileInside = false

    init(hover: HoverDriver) {
        self.hover = hover
    }

    /// Enter the compact region and rest 300 ms (expands), stay 3 s through the morph (must not collapse), leave
    /// for 800 ms (collapses once). True when exactly that happened. The driver holds the simulation through
    /// its closures only until this returns.
    func run() async -> Bool {
        let regions = hover.regions
        emit("compact region \(describe(regions.compact)); expanded region \(describe(regions.expanded))")
        let away = CGPoint(x: regions.expanded.midX, y: regions.expanded.minY - 300)
        location = away
        hover.pointerLocation = { self.location }
        hover.log = { line in self.record(line) }
        defer {
            hover.pointerLocation = { NSEvent.mouseLocation }
            hover.log = nil
        }

        move(to: CGPoint(x: regions.compact.minX + 4, y: regions.compact.midY), inside: true, "pointer enters the compact region")
        await sleep(0.3)
        emit("pointer rests inside the open panel for 3 s")
        await sleep(3)
        move(to: away, inside: false, "pointer leaves")
        await sleep(0.8)

        let passed = expands == 1 && collapses == 1 && !collapsedWhileInside
        emit("expands=\(expands) collapses=\(collapses) collapsed while inside=\(collapsedWhileInside) → \(passed ? "OK" : "FAILED")")
        return passed
    }

    private func move(to point: CGPoint, inside: Bool, _ note: String) {
        location = point
        self.inside = inside
        emit(note)
        hover.pointerMoved()
    }

    private func record(_ line: String) {
        switch line {
        case "expand": expands += 1
        case "collapse":
            collapses += 1
            if inside { collapsedWhileInside = true }
        default: break
        }
        emit(line)
    }

    private func sleep(_ seconds: TimeInterval) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    private func emit(_ line: String) {
        Probe.emit(String(format: "hover-sim %6.3f  %@", ProcessInfo.processInfo.systemUptime - started, line))
    }

    private func describe(_ rect: CGRect) -> String {
        String(format: "(%.0f, %.0f, %.0f × %.0f)", rect.minX, rect.minY, rect.width, rect.height)
    }
}
