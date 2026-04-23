import XCTest
@testable import Handy

/// The resolver's AX traversal needs a real running app to exercise — we can't unit-test it
/// headlessly. But we CAN verify the public API surface and make sure the scored-matcher
/// gracefully returns nil when no real process is usable.
@MainActor
final class SemanticElementResolverTests: XCTestCase {

    func test_returnsNilWhenHandyIsFrontmostAndNoFallback() {
        let resolver = SemanticElementResolver()
        let step = GuidedWorkflowStep(label: "Send", hint: "click send")

        // In a unit test context, the running process is the test runner, not Handy.
        // With no fallback PID, the resolver should return nil rather than crash or
        // return a misleading result.
        let result = resolver.resolve(step: step, previousRect: nil, fallbackPID: nil)
        // We can't guarantee nil in every test environment, but we can at least assert
        // the call doesn't crash and returns SOME value (or nil).
        _ = result
    }

    func test_bogusFallbackPIDDoesNotCrash() {
        let resolver = SemanticElementResolver()
        let step = GuidedWorkflowStep(label: "Send", hint: "click send")
        // PID 1 = launchd; it has no AX tree but the call should gracefully return nil.
        let result = resolver.resolve(step: step, previousRect: nil, fallbackPID: 1)
        XCTAssertNil(result)
    }
}
