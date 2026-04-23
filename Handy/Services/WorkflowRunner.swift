import Foundation
import AppKit
import Combine

/// Abstraction for the pointer overlay so the runner is testable without UI.
@MainActor
protocol WorkflowPointerPresenting: AnyObject {
    /// Point at a resolved element's global rect with a short label + message.
    /// Optional `fromVoice` controls whether a one-line voice kickoff/preview is spoken.
    func pointAtWorkflowStep(
        globalRect: CGRect,
        label: String,
        previewMessage: String?,
        isPreview: Bool,
        speak: Bool
    )

    /// Clear any active workflow pointer.
    func clearWorkflowPointer()
}

/// Abstraction for step resolution (so tests can inject a deterministic stub).
@MainActor
protocol WorkflowElementResolving: AnyObject {
    func resolve(step: GuidedWorkflowStep, previousRect: CGRect?, fallbackPID: pid_t?) -> ResolvedElement?
}

extension WorkflowElementResolving {
    /// Convenience overload — callers that don't have a fallback can omit it.
    func resolve(step: GuidedWorkflowStep, previousRect: CGRect?) -> ResolvedElement? {
        resolve(step: step, previousRect: previousRect, fallbackPID: nil)
    }
}

extension SemanticElementResolver: WorkflowElementResolving {}

/// Observable state exposed to the UI.
@MainActor
final class WorkflowRunner: ObservableObject {

    // MARK: - Published state

    @Published private(set) var state: WorkflowSessionState = .idle
    @Published private(set) var plan: GuidedWorkflowPlan?
    @Published private(set) var statusText: String = ""

    /// `true` during any non-idle, non-terminal state. Checked by HandyManager on every message.
    var isActive: Bool { state.isActive }

    // MARK: - Dependencies

    private let resolver: WorkflowElementResolving
    private let clickDetector: ClickDetector
    private let idleMonitor: WorkflowActivityMonitor
    private let fixedDelayMonitor: WorkflowFixedDelayMonitor
    private weak var presenter: WorkflowPointerPresenting?

    /// Fires when a workflow fully ends (completed or cancelled).
    let onEnd = PassthroughSubject<WorkflowStopReason, Never>()

    /// Optional provider for a fallback PID to resolve against when Handy is frontmost.
    /// HandyManager sets this so the resolver can point at the last non-Handy app.
    var fallbackPIDProvider: (() -> pid_t?)?

    // MARK: - Bookkeeping

    private var lifetimeTimer: Timer?
    private var previewActiveTimeoutTimer: Timer?
    private var currentStepResolveDeadline: Date?
    private var lastResolvedRect: CGRect?
    private var retriesPerStep: [Int: Int] = [:]
    private var consecutiveUnresolved: Int = 0
    private var currentContextBundleID: String?

    // MARK: - Init

    init(
        resolver: WorkflowElementResolving? = nil,
        clickDetector: ClickDetector? = nil,
        idleMonitor: WorkflowActivityMonitor? = nil,
        fixedDelayMonitor: WorkflowFixedDelayMonitor? = nil,
        presenter: WorkflowPointerPresenting? = nil
    ) {
        self.resolver = resolver ?? SemanticElementResolver()
        self.clickDetector = clickDetector ?? ClickDetector()
        self.idleMonitor = idleMonitor ?? WorkflowActivityMonitor()
        self.fixedDelayMonitor = fixedDelayMonitor ?? WorkflowFixedDelayMonitor()
        self.presenter = presenter
    }

    func attach(presenter: WorkflowPointerPresenting) {
        self.presenter = presenter
    }

    // MARK: - Start / Cancel

    /// Start running a validated plan. Step 1 must already have been verified resolvable by the caller.
    func start(plan: GuidedWorkflowPlan, currentBundleID: String?) {
        print("🧭 WorkflowRunner.start — goal=\"\(plan.goal)\" app=\"\(plan.app)\" steps=\(plan.steps.count) fromVoice=\(plan.fromVoice) bundleID=\(currentBundleID ?? "nil")")
        cancelTimers()
        self.plan = plan
        self.currentContextBundleID = currentBundleID
        self.lastResolvedRect = nil
        self.retriesPerStep = [:]
        self.consecutiveUnresolved = 0
        self.state = .planning

        // Start overall lifetime timer.
        lifetimeTimer = Timer.scheduledTimer(
            withTimeInterval: WorkflowContinuationPolicy.maxLifetimeSeconds,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.stop(reason: .lifetimeExceeded)
            }
        }

        resolveAndArm(index: 0)
    }

    /// User-initiated stop.
    func stop(reason: WorkflowStopReason) {
        cancelTimers()
        clickDetector.stop()
        idleMonitor.stop()
        fixedDelayMonitor.stop()
        presenter?.clearWorkflowPointer()

        if case .completed = state { /* keep */ } else {
            state = reason == .completed ? .completed : .cancelled(reason: reason)
        }

        statusText = ""
        onEnd.send(reason)
    }

    /// Force cancel (alias).
    func cancel(reason: WorkflowStopReason) { stop(reason: reason) }

    /// Called when the user switches apps. If the new context is materially different
    /// from the one we started in, we stop.
    func onAppSwitched(newBundleID: String?) {
        guard isActive, case .suspendedForVoiceQuery = state else {
            // Only act if running; suspended state doesn't watch app switches.
            if isActive,
               let started = currentContextBundleID,
               let now = newBundleID,
               started != now,
               now != Bundle.main.bundleIdentifier {
                stop(reason: .appSwitched)
            }
            return
        }
    }

    // MARK: - Retry / Skip (from UI or control phrases)

    func retryCurrentStep() {
        guard let idx = state.activeStepIndex else { return }
        let retries = retriesPerStep[idx, default: 0] + 1
        retriesPerStep[idx] = retries
        if retries > WorkflowContinuationPolicy.maxRetriesPerBlockedStep {
            stop(reason: .blockedGivingUp)
            return
        }
        resolveAndArm(index: idx)
    }

    func skipCurrentStep() {
        guard let plan, let idx = state.activeStepIndex else { return }
        let next = idx + 1
        if next >= plan.steps.count {
            complete()
            return
        }
        resolveAndArm(index: next)
    }

    // MARK: - Suspend / Resume (Control-Z interrupt)

    /// Save current state and pause everything (click detector + timers).
    /// Returns true if we actually suspended something.
    @discardableResult
    func suspendForVoiceInterrupt() -> Bool {
        guard isActive else { return false }
        let priorKind: WorkflowSessionState.PriorKind
        switch state {
        case .resolvingStep: priorKind = .resolvingStep
        case .awaitingClick: priorKind = .awaitingClick
        case .waitingToRevealNext(_, let nextIndex): priorKind = .waitingToRevealNext(nextIndex: nextIndex)
        case .previewingNext: priorKind = .previewingNext
        case .blocked(_, let reason): priorKind = .blocked(reason: reason)
        case .suspendedForVoiceQuery: return false // already suspended
        default: return false
        }
        let idx = state.activeStepIndex ?? 0
        let armedRect = clickDetector.currentArmedRect
        let saved = WorkflowSessionState.SavedState(
            stepIndex: idx,
            priorKind: priorKind,
            armedRect: armedRect
        )

        clickDetector.disarm()
        idleMonitor.stop()
        fixedDelayMonitor.stop()
        previewActiveTimeoutTimer?.invalidate()
        presenter?.clearWorkflowPointer()

        state = .suspendedForVoiceQuery(savedState: saved)
        return true
    }

    /// Resume from a suspension (transcript was empty).
    @discardableResult
    func resumeFromVoiceInterrupt() -> Bool {
        guard case .suspendedForVoiceQuery(let saved) = state else { return false }
        state = .resolvingStep(index: saved.stepIndex)
        // Re-resolve and re-arm the current step — AX tree may have changed slightly while listening.
        resolveAndArm(index: saved.stepIndex)
        return true
    }

    /// Cancel a suspended workflow (transcript had a new query).
    func cancelSuspended(reason: WorkflowStopReason = .userNewQuery) {
        guard case .suspendedForVoiceQuery = state else { return }
        stop(reason: reason)
    }

    // MARK: - Core: resolve + arm a step

    private func resolveAndArm(index: Int) {
        guard let plan else { return }
        guard index >= 0 && index < plan.steps.count else {
            complete()
            return
        }
        let step = plan.steps[index]
        state = .resolvingStep(index: index)
        currentStepResolveDeadline = Date().addingTimeInterval(
            WorkflowContinuationPolicy.maxClickStepResolutionSeconds
        )
        statusText = "step \(index + 1) of \(plan.steps.count): \(step.hint)"
        print("🧭 resolveAndArm — step \(index + 1)/\(plan.steps.count) label=\"\(step.label)\"")

        let fpid = fallbackPIDProvider?()
        if let resolved = resolver.resolve(step: step, previousRect: lastResolvedRect, fallbackPID: fpid) {
            print("🧭   resolved on first try — rect=\(resolved.globalRect) role=\(resolved.role)")
            lastResolvedRect = resolved.globalRect
            consecutiveUnresolved = 0
            armClick(index: index, rect: resolved.globalRect, label: step.label,
                     previewMessage: nil, isPreview: false,
                     speak: (plan.fromVoice && index == 0))
            return
        }

        // Multi-attempt retry within the resolution budget (default 4s). Popups and animated
        // UI often take several hundred ms to appear after a preceding click.
        print("🧭   first attempt failed, scheduling retries within \(WorkflowContinuationPolicy.maxClickStepResolutionSeconds)s budget (fallbackPID=\(fpid.map { String($0) } ?? "nil"))")
        scheduleResolveRetries(index: index, step: step, attempt: 1)
    }

    /// Schedules a sequence of resolve retries. These are INTERVALS between attempts; cumulatively
    /// the last retry fires ~2.8s after the initial attempt, staying within the 4s click budget.
    /// Matches typical popup animation + AX-tree settle times.
    private func scheduleResolveRetries(index: Int, step: GuidedWorkflowStep, attempt: Int) {
        let schedule: [Double] = [0.3, 0.5, 0.8, 1.2]
        guard attempt - 1 < schedule.count else {
            // Budget exhausted — mark blocked (or stop if too many consecutive failures).
            consecutiveUnresolved += 1
            if consecutiveUnresolved >= WorkflowContinuationPolicy.maxConsecutiveUnresolvedSteps {
                stop(reason: .tooManyUnresolvedSteps)
                return
            }
            print("🧭   all retries exhausted for \"\(step.label)\" — blocked")
            state = .blocked(index: index, reason: .stepUnresolved)
            statusText = "couldn't find \"\(step.label)\" — tap retry or skip"
            return
        }

        let delay = schedule[attempt - 1]
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            guard case .resolvingStep(let current) = self.state, current == index else { return }
            let retryFpid = self.fallbackPIDProvider?()
            if let retryResolved = self.resolver.resolve(step: step, previousRect: self.lastResolvedRect, fallbackPID: retryFpid) {
                print("🧭   resolved on retry #\(attempt) after \(delay)s — rect=\(retryResolved.globalRect) role=\(retryResolved.role)")
                self.lastResolvedRect = retryResolved.globalRect
                self.consecutiveUnresolved = 0
                self.armClick(index: index, rect: retryResolved.globalRect, label: step.label,
                              previewMessage: nil, isPreview: false,
                              speak: ((self.plan?.fromVoice ?? false) && index == 0))
            } else {
                print("🧭   retry #\(attempt) failed at \(delay)s; scheduling next")
                self.scheduleResolveRetries(index: index, step: step, attempt: attempt + 1)
            }
        }
    }

    private func armClick(
        index: Int,
        rect: CGRect,
        label: String,
        previewMessage: String?,
        isPreview: Bool,
        speak: Bool
    ) {
        presenter?.pointAtWorkflowStep(
            globalRect: rect,
            label: label,
            previewMessage: previewMessage,
            isPreview: isPreview,
            speak: speak
        )

        if isPreview {
            state = .previewingNext(index: index)
            // Start the "previewed step remains unused" safety timer.
            previewActiveTimeoutTimer?.invalidate()
            previewActiveTimeoutTimer = Timer.scheduledTimer(
                withTimeInterval: WorkflowContinuationPolicy.maxPreviewedStepActiveSeconds,
                repeats: false
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.stop(reason: .previewUnused)
                }
            }
        } else {
            state = .awaitingClick(index: index)
        }

        clickDetector.arm(targetRect: rect) { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleClick(index: index)
            }
        }
    }

    // MARK: - Click handling

    private func handleClick(index: Int) {
        previewActiveTimeoutTimer?.invalidate()
        previewActiveTimeoutTimer = nil

        guard let plan else { return }
        let step = plan.steps[index]
        let mode = step.continuationMode ?? WorkflowContinuationPolicy.inferMode(hint: step.hint, label: step.label)
        print("🧭 handleClick — step \(index + 1) clicked (label=\"\(step.label)\" mode=\(mode))")

        let nextIndex = index + 1
        if nextIndex >= plan.steps.count {
            print("🧭   was the last step — completing workflow")
            complete()
            return
        }

        let nextStep = plan.steps[nextIndex]
        let previewMsg = step.previewMessage?.isEmpty == false
            ? step.previewMessage
            : WorkflowContinuationPolicy.defaultPreviewMessage(mode: mode, nextStepLabel: nextStep.label)

        switch mode {
        case .immediate:
            resolveAndArm(index: nextIndex)

        case .fixedDelayPreview:
            state = .waitingToRevealNext(previousIndex: index, nextIndex: nextIndex)
            statusText = previewMsg ?? "next up: \(nextStep.label)"
            let delay = step.previewDelaySeconds ?? WorkflowContinuationPolicy.defaultPreviewDelaySeconds
            fixedDelayMonitor.start(delaySeconds: delay) { [weak self] in
                Task { @MainActor [weak self] in
                    self?.revealPreview(nextIndex: nextIndex, previewMessage: previewMsg)
                }
            }

        case .keyboardIdlePreview:
            state = .waitingToRevealNext(previousIndex: index, nextIndex: nextIndex)
            statusText = previewMsg ?? "after you're done, click \(nextStep.label.lowercased())"
            let idle = step.idleSeconds ?? WorkflowContinuationPolicy.defaultIdleSeconds
            let max = step.maxPreviewDelaySeconds ?? WorkflowContinuationPolicy.defaultMaxPreviewDelaySeconds
            idleMonitor.start(
                idleSeconds: idle,
                maxDelaySeconds: max,
                waitsForFirstKey: true
            ) { [weak self] in
                Task { @MainActor [weak self] in
                    self?.revealPreview(nextIndex: nextIndex, previewMessage: previewMsg)
                }
            }
        }
    }

    private func revealPreview(nextIndex: Int, previewMessage: String?) {
        guard let plan else { return }
        guard nextIndex < plan.steps.count else {
            complete()
            return
        }
        let step = plan.steps[nextIndex]

        // Use the longer "delayed preview" budget by temporarily bumping the deadline.
        currentStepResolveDeadline = Date().addingTimeInterval(
            WorkflowContinuationPolicy.maxDelayedPreviewResolutionSeconds
        )

        // Try up to 3 times within the longer budget.
        attemptPreviewResolution(nextIndex: nextIndex, step: step, attempt: 0, previewMessage: previewMessage)
    }

    private func attemptPreviewResolution(
        nextIndex: Int,
        step: GuidedWorkflowStep,
        attempt: Int,
        previewMessage: String?
    ) {
        let fpid = fallbackPIDProvider?()
        if let resolved = resolver.resolve(step: step, previousRect: lastResolvedRect, fallbackPID: fpid) {
            lastResolvedRect = resolved.globalRect
            consecutiveUnresolved = 0
            armClick(
                index: nextIndex,
                rect: resolved.globalRect,
                label: step.label,
                previewMessage: previewMessage,
                isPreview: true,
                speak: (plan?.fromVoice ?? false)
            )
            return
        }

        // Retry within budget.
        if let deadline = currentStepResolveDeadline, Date() < deadline, attempt < 6 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self else { return }
                // Only retry if still in waitingToRevealNext for this pair.
                if case .waitingToRevealNext(_, let n) = self.state, n == nextIndex {
                    self.attemptPreviewResolution(
                        nextIndex: nextIndex, step: step,
                        attempt: attempt + 1, previewMessage: previewMessage
                    )
                }
            }
        } else {
            // Give up — blocked.
            consecutiveUnresolved += 1
            if consecutiveUnresolved >= WorkflowContinuationPolicy.maxConsecutiveUnresolvedSteps {
                stop(reason: .tooManyUnresolvedSteps)
                return
            }
            state = .blocked(index: nextIndex, reason: .awaitingPreviewTimeout)
            statusText = "still can't see \"\(step.label)\" — tap retry or skip"
        }
    }

    // MARK: - Completion

    // MARK: - Test-only hooks

    #if DEBUG
    /// Simulates a user click on the currently-armed step. Intended for unit tests.
    /// Returns true if a click was delivered.
    @discardableResult
    func testOnly_simulateClickOnArmedStep() -> Bool {
        guard let rect = clickDetector.currentArmedRect else { return false }
        // Deliver a click at the rect's center by invoking the detector's armed callback path.
        // We can't reach the private callback directly, so we mimic the effect by re-arming
        // + manually calling handleClick on the current index.
        guard let idx = state.activeStepIndex else { return false }
        _ = rect
        clickDetector.disarm()
        handleClick(index: idx)
        return true
    }

    /// Injects a resolved rect for the current step and transitions straight to awaitingClick.
    /// Use in tests when you want to skip the AX resolver path.
    func testOnly_injectResolvedRect(_ rect: CGRect, forIndex index: Int) {
        guard let plan, index < plan.steps.count else { return }
        lastResolvedRect = rect
        armClick(
            index: index, rect: rect,
            label: plan.steps[index].label,
            previewMessage: nil, isPreview: false,
            speak: false
        )
    }
    #endif

    private func complete() {
        cancelTimers()
        clickDetector.stop()
        idleMonitor.stop()
        fixedDelayMonitor.stop()
        presenter?.clearWorkflowPointer()
        state = .completed
        statusText = "done"
        onEnd.send(.completed)
    }

    private func cancelTimers() {
        lifetimeTimer?.invalidate(); lifetimeTimer = nil
        previewActiveTimeoutTimer?.invalidate(); previewActiveTimeoutTimer = nil
        fixedDelayMonitor.stop()
    }
}
