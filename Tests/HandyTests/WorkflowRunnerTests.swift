import XCTest
@testable import Handy
import CoreGraphics

@MainActor
final class FakeResolver: WorkflowElementResolving {
    /// Maps step label → rect to return. Nil value means "fail to resolve".
    var resolutions: [String: CGRect?] = [:]
    /// Count of calls per label (for verifying retries).
    private(set) var callCount: [String: Int] = [:]

    func resolve(step: GuidedWorkflowStep, previousRect: CGRect?, fallbackPID: pid_t?) -> ResolvedElement? {
        callCount[step.label, default: 0] += 1
        if let entry = resolutions[step.label], let rect = entry {
            return ResolvedElement(globalRect: rect, role: "axbutton", matchedLabel: step.label.lowercased())
        }
        return nil
    }
}

@MainActor
final class FakePresenter: WorkflowPointerPresenting {
    struct PointCall {
        let rect: CGRect
        let label: String
        let previewMessage: String?
        let isPreview: Bool
        let speak: Bool
    }
    var points: [PointCall] = []
    var cleared: Int = 0

    func pointAtWorkflowStep(globalRect: CGRect, label: String, previewMessage: String?, isPreview: Bool, speak: Bool) {
        points.append(PointCall(rect: globalRect, label: label, previewMessage: previewMessage,
                                isPreview: isPreview, speak: speak))
    }

    func clearWorkflowPointer() { cleared += 1 }
}

@MainActor
final class WorkflowRunnerTests: XCTestCase {

    private func makePlan(
        mode: WorkflowContinuationMode = .immediate,
        stepCount: Int = 3,
        fromVoice: Bool = false
    ) -> GuidedWorkflowPlan {
        let steps = (0..<stepCount).map { i in
            GuidedWorkflowStep(
                label: "Step\(i)",
                hint: "click step \(i)",
                continuationMode: i == 0 ? mode : .immediate,
                previewDelaySeconds: 1.0,
                idleSeconds: 1.0,
                maxPreviewDelaySeconds: 2.0,
                previewMessage: "preview-\(i)"
            )
        }
        return GuidedWorkflowPlan(goal: "test", app: "TestApp", steps: steps, fromVoice: fromVoice)
    }

    // MARK: - Immediate progression

    func test_immediateProgression_advancesThroughAllSteps() async throws {
        let resolver = FakeResolver()
        let presenter = FakePresenter()
        resolver.resolutions = [
            "Step0": CGRect(x: 0, y: 0, width: 40, height: 40),
            "Step1": CGRect(x: 50, y: 50, width: 40, height: 40),
            "Step2": CGRect(x: 100, y: 100, width: 40, height: 40)
        ]

        let runner = WorkflowRunner(resolver: resolver, presenter: presenter)
        runner.attach(presenter: presenter)
        runner.start(plan: makePlan(), currentBundleID: "com.test")

        // After start, state becomes awaitingClick(0)
        try await Task.sleep(nanoseconds: 50_000_000)
        guard case .awaitingClick(let i0) = runner.state else {
            return XCTFail("expected awaitingClick(0), got \(runner.state)")
        }
        XCTAssertEqual(i0, 0)

        // Simulate click on step 0 — should immediately resolve + arm step 1.
        XCTAssertTrue(runner.testOnly_simulateClickOnArmedStep())
        guard case .awaitingClick(let i1) = runner.state else {
            return XCTFail("expected awaitingClick(1), got \(runner.state)")
        }
        XCTAssertEqual(i1, 1)

        // Click step 1 → step 2
        XCTAssertTrue(runner.testOnly_simulateClickOnArmedStep())
        guard case .awaitingClick(let i2) = runner.state else {
            return XCTFail("expected awaitingClick(2), got \(runner.state)")
        }
        XCTAssertEqual(i2, 2)

        // Final click → completed
        XCTAssertTrue(runner.testOnly_simulateClickOnArmedStep())
        XCTAssertEqual(runner.state, .completed)
        XCTAssertEqual(presenter.cleared, 1)
    }

    // MARK: - Fixed delay preview

    func test_fixedDelayPreview_revealsNextWithoutAdvancing() async throws {
        let resolver = FakeResolver()
        let presenter = FakePresenter()
        resolver.resolutions = [
            "Step0": CGRect(x: 0, y: 0, width: 40, height: 40),
            "Step1": CGRect(x: 50, y: 50, width: 40, height: 40),
            "Step2": CGRect(x: 100, y: 100, width: 40, height: 40)
        ]

        let runner = WorkflowRunner(resolver: resolver, presenter: presenter)
        runner.start(plan: makePlan(mode: .fixedDelayPreview), currentBundleID: "com.test")

        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(runner.testOnly_simulateClickOnArmedStep())

        // After click on step 0, we should be waitingToRevealNext(0, 1).
        guard case .waitingToRevealNext(let prev, let next) = runner.state else {
            return XCTFail("expected waitingToRevealNext, got \(runner.state)")
        }
        XCTAssertEqual(prev, 0)
        XCTAssertEqual(next, 1)

        // Wait out the 1s preview delay.
        try await Task.sleep(nanoseconds: 1_400_000_000)

        // Now should be previewingNext(1) — armed but not advanced.
        guard case .previewingNext(let idx) = runner.state else {
            return XCTFail("expected previewingNext(1), got \(runner.state)")
        }
        XCTAssertEqual(idx, 1)
        XCTAssertEqual(resolver.callCount["Step1"], 1)

        // Timer did NOT mark step 1 completed. Only real click advances.
        XCTAssertTrue(runner.testOnly_simulateClickOnArmedStep())
        guard case .awaitingClick(let i2) = runner.state else {
            return XCTFail("expected awaitingClick(2), got \(runner.state)")
        }
        XCTAssertEqual(i2, 2)
    }

    // MARK: - Blocked on unresolved step

    func test_blockedWhenStepCannotResolve() async throws {
        let resolver = FakeResolver()
        let presenter = FakePresenter()
        resolver.resolutions = [
            "Step0": Optional<CGRect>.none,
            "Step1": Optional<CGRect>.none,
            "Step2": Optional<CGRect>.none
        ]
        // Override so Step0 is not nil on first call — but we can only set via the map above.
        // Easier: start with step0 resolvable, then step1 unresolvable.
        resolver.resolutions["Step0"] = CGRect(x: 0, y: 0, width: 40, height: 40)

        let runner = WorkflowRunner(resolver: resolver, presenter: presenter)
        runner.start(plan: makePlan(), currentBundleID: "com.test")

        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(runner.testOnly_simulateClickOnArmedStep())

        // Retry schedule is [0.3, 0.5, 0.8, 1.2]s intervals; last retry fires ~2.8s after click.
        // Wait for the full budget plus a small buffer.
        try await Task.sleep(nanoseconds: 3_500_000_000)

        // Step 1 should have failed all attempts → state is .blocked.
        guard case .blocked(let i, _) = runner.state else {
            return XCTFail("expected blocked, got \(runner.state)")
        }
        XCTAssertEqual(i, 1)
    }

    // MARK: - Stop on app switch

    func test_stopsOnMaterialAppSwitch() async throws {
        let resolver = FakeResolver()
        let presenter = FakePresenter()
        resolver.resolutions = ["Step0": CGRect(x: 0, y: 0, width: 40, height: 40),
                                "Step1": CGRect(x: 50, y: 50, width: 40, height: 40)]

        let runner = WorkflowRunner(resolver: resolver, presenter: presenter)
        runner.start(plan: makePlan(stepCount: 2), currentBundleID: "com.testapp.a")
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(runner.isActive)

        runner.onAppSwitched(newBundleID: "com.totally.different")
        XCTAssertFalse(runner.isActive)
        if case .cancelled(let reason) = runner.state {
            XCTAssertEqual(reason, .appSwitched)
        } else {
            XCTFail("expected cancelled(.appSwitched), got \(runner.state)")
        }
    }

    // MARK: - Suspend / Resume

    func test_suspendAndResume_preservesStep() async throws {
        let resolver = FakeResolver()
        let presenter = FakePresenter()
        resolver.resolutions = [
            "Step0": CGRect(x: 0, y: 0, width: 40, height: 40),
            "Step1": CGRect(x: 50, y: 50, width: 40, height: 40),
            "Step2": CGRect(x: 100, y: 100, width: 40, height: 40)
        ]
        let runner = WorkflowRunner(resolver: resolver, presenter: presenter)
        runner.start(plan: makePlan(), currentBundleID: "com.test")
        try await Task.sleep(nanoseconds: 50_000_000)

        // Advance to step 1
        XCTAssertTrue(runner.testOnly_simulateClickOnArmedStep())
        guard case .awaitingClick(let i1) = runner.state, i1 == 1 else {
            return XCTFail("expected awaitingClick(1)")
        }

        // Suspend
        XCTAssertTrue(runner.suspendForVoiceInterrupt())
        if case .suspendedForVoiceQuery = runner.state {} else {
            return XCTFail("expected suspendedForVoiceQuery")
        }

        // Resume — should re-arm step 1
        XCTAssertTrue(runner.resumeFromVoiceInterrupt())
        try await Task.sleep(nanoseconds: 50_000_000)
        guard case .awaitingClick(let i1b) = runner.state else {
            return XCTFail("expected awaitingClick after resume, got \(runner.state)")
        }
        XCTAssertEqual(i1b, 1)
    }

    func test_cancelSuspended_endsWorkflow() async throws {
        let resolver = FakeResolver()
        let presenter = FakePresenter()
        resolver.resolutions = ["Step0": CGRect(x: 0, y: 0, width: 40, height: 40),
                                "Step1": CGRect(x: 50, y: 50, width: 40, height: 40)]
        let runner = WorkflowRunner(resolver: resolver, presenter: presenter)
        runner.start(plan: makePlan(stepCount: 2), currentBundleID: "com.test")
        try await Task.sleep(nanoseconds: 50_000_000)

        _ = runner.suspendForVoiceInterrupt()
        runner.cancelSuspended(reason: .userNewQuery)
        if case .cancelled(let r) = runner.state {
            XCTAssertEqual(r, .userNewQuery)
        } else {
            XCTFail("expected cancelled")
        }
    }
}
