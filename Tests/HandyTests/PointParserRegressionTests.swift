import XCTest
@testable import Handy
import CoreGraphics

/// Ensures the existing [POINT:x,y:label] contract is untouched by the workflow changes.
final class PointParserRegressionTests: XCTestCase {

    func test_endAnchoredPointTag_parses() {
        let text = "click this to continue [POINT:120,40:share button]"
        let result = PointParser.parse(from: text)
        XCTAssertEqual(result.coordinate, CGPoint(x: 120, y: 40))
        XCTAssertEqual(result.label, "share button")
        XCTAssertNil(result.screenNumber)
    }

    func test_pointNoneParses() {
        let text = "great question — here's the answer. [POINT:none]"
        let result = PointParser.parse(from: text)
        XCTAssertNil(result.coordinate)
        XCTAssertNil(result.label)
    }

    func test_stripPointTags_removesTagCleanly() {
        let text = "here is the answer [POINT:100,200:save]"
        XCTAssertEqual(PointParser.stripPointTags(from: text), "here is the answer")
    }

    func test_extractSpokenPart() {
        let text = "[SPOKEN]click the share button.[/SPOKEN] then pick export. [POINT:120,40:share]"
        let parts = PointParser.extractSpokenPart(from: text)
        XCTAssertEqual(parts.spoken, "click the share button.")
        XCTAssertTrue(parts.display.contains("click the share button"))
        XCTAssertTrue(parts.display.contains("then pick export"))
    }
}
