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

    /// Sweep straight through the compact region too fast to dwell (must not open), then enter it and rest 300 ms
    /// (expands), stay 3 s through the morph (must not collapse), leave for 800 ms (collapses once). True when
    /// exactly that happened. The driver holds the simulation through its closures only until this returns.
    func run() async -> Bool {
        let regions = hover.regions
        emit("compact region \(describe(regions.compact)); expanded region \(describe(regions.expanded))")
        guard hover.mode == .onHover else {
            emit("visibility is \(hover.mode == .onClick ? "Open on click" : "Always open"), so the pointer opens nothing: nothing to simulate. "
                 + "Run --smoke --visibility onHover --hover-sim for a verdict")
            return true
        }
        let away = CGPoint(x: regions.expanded.midX, y: regions.expanded.minY - 300)
        location = away
        hover.pointerLocation = { self.location }
        hover.log = { line in self.record(line) }
        defer {
            hover.pointerLocation = { NSEvent.mouseLocation }
            hover.log = nil
        }

        let sweepPassed = await sweep(across: regions.compact)

        move(to: CGPoint(x: regions.compact.minX + 4, y: regions.compact.midY), inside: true, "pointer enters the compact region")
        await sleep(0.3)
        emit("pointer rests inside the open panel for 3 s")
        await sleep(3)
        move(to: away, inside: false, "pointer leaves")
        await sleep(0.8)

        let passed = sweepPassed && expands == 1 && collapses == 1 && !collapsedWhileInside
        emit("expands=\(expands) collapses=\(collapses) collapsed while inside=\(collapsedWhileInside) → \(passed ? "OK" : "FAILED")")
        return passed
    }

    /// A pointer crossing the rings on its way somewhere else: samples at a plausible rate along a path three
    /// region-widths long, timed so the third of it that lies inside the region takes a third of the Hover delay.
    /// Nothing should open, and the dwell re-sample the driver schedules on the way in has to find the pointer
    /// gone. Scheduling can stretch the sweep past the delay on a loaded machine; that is reported as inconclusive
    /// rather than failed, because a slow sweep is a dwell and dwelling is supposed to open the panel.
    private func sweep(across compact: CGRect) async -> Bool {
        let steps = 18
        let step = hover.dwell / TimeInterval(steps)
        let width = compact.width
        emit(String(format: "fast sweep through the compact region: %d samples %.0f ms apart, a third of the path inside, Hover delay %.0f ms",
                    steps + 1, step * 1000, hover.dwell * 1000))
        var insideFrom: TimeInterval?
        var insideFor: TimeInterval = 0
        for index in 0...steps {
            let x = compact.minX - width + (3 * width) * CGFloat(index) / CGFloat(steps)
            let point = CGPoint(x: x, y: compact.midY)
            location = point
            inside = compact.contains(point)
            let at = ProcessInfo.processInfo.systemUptime
            if inside, insideFrom == nil { insideFrom = at }
            if !inside, let from = insideFrom {
                insideFor += at - from
                insideFrom = nil
            }
            hover.pointerMoved()
            await sleep(step)
        }
        move(to: CGPoint(x: compact.maxX + width, y: compact.midY), inside: false, "sweep leaves the far side")
        await sleep(hover.dwell + 0.3)
        if insideFor >= hover.dwell {
            emit(String(format: "sweep spent %.0f ms inside, past the %.0f ms delay: too slow to be a sweep, not a verdict", insideFor * 1000, hover.dwell * 1000))
            return true
        }
        let passed = expands == 0
        emit(String(format: "sweep spent %.0f ms inside and opened the panel %d time(s) → %@", insideFor * 1000, expands, passed ? "OK" : "FAILED"))
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
        try? await Task.sleep(for: .seconds(seconds), tolerance: .zero)
    }

    private func emit(_ line: String) {
        Probe.emit(String(format: "hover-sim %6.3f  %@", ProcessInfo.processInfo.systemUptime - started, line))
    }

    private func describe(_ rect: CGRect) -> String {
        String(format: "(%.0f, %.0f, %.0f × %.0f)", rect.minX, rect.minY, rect.width, rect.height)
    }
}
