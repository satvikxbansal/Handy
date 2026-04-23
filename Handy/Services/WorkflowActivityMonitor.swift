import AppKit

/// A lightweight, listen-only activity monitor used by the workflow runner during
/// `keyboardIdlePreview` / `fixedDelayPreview` windows.
///
/// Responsibilities:
/// - Track keyDown events globally (no content, just timestamps).
/// - Fire a callback when the keyboard has been idle for >= idleSeconds,
///   OR when maxDelaySeconds has elapsed since activation, whichever comes first.
/// - Stopping disables the monitor and clears state so we don't leak global taps.
///
/// This is completely separate from any tutor-mode idle detection.
@MainActor
final class WorkflowActivityMonitor {

    private var keyDownMonitor: Any?
    private var idleSeconds: Double = 1.5
    private var maxDelaySeconds: Double = 4.0
    private var startTime: Date = .distantPast
    private var lastActivityTime: Date = .distantPast
    private var evaluationTimer: Timer?
    private var onFire: (() -> Void)?

    deinit {
        if let monitor = keyDownMonitor {
            NSEvent.removeMonitor(monitor)
        }
        evaluationTimer?.invalidate()
    }

    /// Begin watching. Fires `onReveal` once when the idle condition OR the max delay is met.
    /// If `waitsForFirstKey` is true, the idle timer only starts counting after the first keyDown;
    /// this prevents an immediate reveal when the user clicks into a field but hasn't typed yet.
    func start(
        idleSeconds: Double,
        maxDelaySeconds: Double,
        waitsForFirstKey: Bool,
        onReveal: @escaping () -> Void
    ) {
        stop()

        self.idleSeconds = idleSeconds
        self.maxDelaySeconds = maxDelaySeconds
        self.onFire = onReveal
        self.startTime = Date()
        self.lastActivityTime = waitsForFirstKey ? .distantFuture : Date()

        keyDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                self?.lastActivityTime = Date()
            }
        }

        evaluationTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }
    }

    func stop() {
        if let monitor = keyDownMonitor {
            NSEvent.removeMonitor(monitor)
            keyDownMonitor = nil
        }
        evaluationTimer?.invalidate()
        evaluationTimer = nil
        onFire = nil
    }

    // MARK: - Internal

    private func tick() {
        guard let fire = onFire else { return }
        let now = Date()
        let elapsed = now.timeIntervalSince(startTime)

        // Max delay takes priority.
        if elapsed >= maxDelaySeconds {
            onFire = nil
            stop()
            fire()
            return
        }

        // Idle check (only after at least one key has been recorded OR waitsForFirstKey == false).
        if lastActivityTime != .distantFuture {
            let idle = now.timeIntervalSince(lastActivityTime)
            if idle >= idleSeconds {
                onFire = nil
                stop()
                fire()
                return
            }
        }
    }
}

/// Simpler fixed-delay monitor used for `.fixedDelayPreview`.
/// Keeping it separate makes the intent explicit in WorkflowRunner code.
@MainActor
final class WorkflowFixedDelayMonitor {
    private var timer: Timer?

    func start(delaySeconds: Double, onFire: @escaping () -> Void) {
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: delaySeconds, repeats: false) { _ in
            Task { @MainActor in onFire() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}
