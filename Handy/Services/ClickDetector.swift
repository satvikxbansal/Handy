import AppKit

/// Listen-only global mouse-down detector used by the workflow runner.
///
/// Design:
/// - Uses `NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown])`
///   which does NOT require any extra permissions beyond what Handy already has
///   (Accessibility for the hotkey tap is already granted when workflows are enabled).
/// - We ONLY observe — we never synthesize clicks on behalf of the user.
/// - The runner "arms" the detector with a target rect (+ small tolerance) plus a
///   callback. When a mousedown falls inside the armed rect, the callback fires once.
/// - Anti-double-click grace: after firing, we ignore further clicks for
///   `WorkflowContinuationPolicy.antiDoubleClickGraceSeconds`.
@MainActor
final class ClickDetector {

    private var globalMonitor: Any?
    private var armedRect: CGRect?
    private var tolerance: CGFloat = 12
    private var onClickInside: (() -> Void)?
    private var lastFireTime: Date = .distantPast

    deinit {
        // NSEvent monitors need to be removed on main actor — deinit can't await.
        // Best-effort cleanup; in practice the runner always calls stop() before release.
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    /// Arm the detector on the given global AppKit rect. Replaces any previous arm.
    /// `onInside` fires once per distinct click inside the rect (respecting grace window).
    func arm(targetRect: CGRect, tolerance: CGFloat = 12, onInside: @escaping () -> Void) {
        disarm()
        self.armedRect = targetRect
        self.tolerance = tolerance
        self.onClickInside = onInside
        ensureMonitor()
    }

    /// Temporarily disable click matching without tearing down the monitor.
    func disarm() {
        armedRect = nil
        onClickInside = nil
    }

    /// Remove the global monitor entirely (e.g. when workflow fully ends).
    func stop() {
        disarm()
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
    }

    var isArmed: Bool { armedRect != nil }
    var currentArmedRect: CGRect? { armedRect }

    // MARK: - Internal

    private func ensureMonitor() {
        guard globalMonitor == nil else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self else { return }
            // Dispatch to main actor so the callback is safe to mutate @MainActor state.
            let loc = NSEvent.mouseLocation
            Task { @MainActor [weak self] in
                self?.handleMouseDown(at: loc)
            }
        }
    }

    private func handleMouseDown(at globalPoint: CGPoint) {
        guard let rect = armedRect, let callback = onClickInside else { return }
        let expanded = rect.insetBy(dx: -tolerance, dy: -tolerance)
        guard expanded.contains(globalPoint) else { return }

        let now = Date()
        if now.timeIntervalSince(lastFireTime) < WorkflowContinuationPolicy.antiDoubleClickGraceSeconds {
            return
        }
        lastFireTime = now

        // Disarm before firing so the callback can safely re-arm with a new target.
        armedRect = nil
        onClickInside = nil
        callback()
    }
}
