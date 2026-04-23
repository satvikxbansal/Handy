import XCTest
@testable import Handy

final class WorkflowContinuationPolicyTests: XCTestCase {

    func test_clampPreviewDelay() {
        XCTAssertEqual(WorkflowContinuationPolicy.clampPreviewDelay(0.0), 1.0)
        XCTAssertEqual(WorkflowContinuationPolicy.clampPreviewDelay(nil), 2.5)
        XCTAssertEqual(WorkflowContinuationPolicy.clampPreviewDelay(10.0), 5.0)
        XCTAssertEqual(WorkflowContinuationPolicy.clampPreviewDelay(2.0), 2.0)
    }

    func test_clampIdleSeconds() {
        XCTAssertEqual(WorkflowContinuationPolicy.clampIdleSeconds(0.1), 1.0)
        XCTAssertEqual(WorkflowContinuationPolicy.clampIdleSeconds(nil), 1.5)
        XCTAssertEqual(WorkflowContinuationPolicy.clampIdleSeconds(5.0), 3.0)
    }

    func test_clampMaxPreviewDelay() {
        XCTAssertEqual(WorkflowContinuationPolicy.clampMaxPreviewDelay(0.5), 2.0)
        XCTAssertEqual(WorkflowContinuationPolicy.clampMaxPreviewDelay(nil), 4.0)
        XCTAssertEqual(WorkflowContinuationPolicy.clampMaxPreviewDelay(10.0), 5.0)
    }

    func test_inferMode_typingCues() {
        XCTAssertEqual(WorkflowContinuationPolicy.inferMode(hint: "type your message"), .keyboardIdlePreview)
        XCTAssertEqual(WorkflowContinuationPolicy.inferMode(hint: "enter the recipient"), .keyboardIdlePreview)
        XCTAssertEqual(WorkflowContinuationPolicy.inferMode(hint: "paste your code"), .keyboardIdlePreview)
        XCTAssertEqual(WorkflowContinuationPolicy.inferMode(hint: "write a description"), .keyboardIdlePreview)
    }

    func test_inferMode_watchCues() {
        XCTAssertEqual(WorkflowContinuationPolicy.inferMode(hint: "wait for the upload to complete"), .fixedDelayPreview)
        XCTAssertEqual(WorkflowContinuationPolicy.inferMode(hint: "watch the progress bar"), .fixedDelayPreview)
        XCTAssertEqual(WorkflowContinuationPolicy.inferMode(hint: "review the preview that generates"), .fixedDelayPreview)
    }

    func test_inferMode_default() {
        XCTAssertEqual(WorkflowContinuationPolicy.inferMode(hint: "click send"), .immediate)
        XCTAssertEqual(WorkflowContinuationPolicy.inferMode(hint: "open the menu"), .immediate)
    }
}
