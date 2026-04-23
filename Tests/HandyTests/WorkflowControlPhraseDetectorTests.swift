import XCTest
@testable import Handy

final class WorkflowControlPhraseDetectorTests: XCTestCase {

    func test_stopPhrases() {
        XCTAssertEqual(WorkflowControlPhraseDetector.detect("stop"), .stop)
        XCTAssertEqual(WorkflowControlPhraseDetector.detect("cancel"), .stop)
        XCTAssertEqual(WorkflowControlPhraseDetector.detect("Stop."), .stop)
        XCTAssertEqual(WorkflowControlPhraseDetector.detect("stop the workflow"), .stop)
    }

    func test_retryPhrases() {
        XCTAssertEqual(WorkflowControlPhraseDetector.detect("retry"), .retry)
        XCTAssertEqual(WorkflowControlPhraseDetector.detect("try again"), .retry)
    }

    func test_skipPhrases() {
        XCTAssertEqual(WorkflowControlPhraseDetector.detect("skip"), .skip)
        XCTAssertEqual(WorkflowControlPhraseDetector.detect("skip this step"), .skip)
    }

    func test_nextPhrases() {
        XCTAssertEqual(WorkflowControlPhraseDetector.detect("next"), .next)
        XCTAssertEqual(WorkflowControlPhraseDetector.detect("what's next"), .next)
        XCTAssertEqual(WorkflowControlPhraseDetector.detect("i clicked it"), .next)
        XCTAssertEqual(WorkflowControlPhraseDetector.detect("done"), .next)
    }

    func test_longSentencesAreNotControlPhrases() {
        // Spec: a long sentence that happens to contain "next" is NOT a control phrase.
        XCTAssertNil(WorkflowControlPhraseDetector.detect(
            "can you show me the next page after i click this button and wait for approval"
        ))
        XCTAssertNil(WorkflowControlPhraseDetector.detect(
            "i want to stop working on this file and move to the other one when i am ready to do so"
        ))
    }

    func test_unrelatedInputs_returnNil() {
        XCTAssertNil(WorkflowControlPhraseDetector.detect("how do i export a file"))
        XCTAssertNil(WorkflowControlPhraseDetector.detect("open the settings menu"))
    }
}
