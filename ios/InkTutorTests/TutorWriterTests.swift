import XCTest
@testable import InkTutor

/// Pure-logic tests for Task 11's handwriting writer (no CoreAnimation —
/// per the plan's hackathon-pace rule, only geometry/timing that can
/// silently be wrong gets unit tests; the actual stroke reveal is verified
/// by watching `TutorWriterPreview` in Xcode's canvas).
final class TutorWriterTests: XCTestCase {

    // MARK: - Latex -> glyph-sequence mapping

    func testLayoutProducesOneGlyphPerCharacterInReadingOrder() {
        guard let (placements, _) = TutorWriterLayout.layout(
            latex: "x^2+8x+12=0", at: .zero, height: 60
        ) else {
            return XCTFail("expected x^2+8x+12=0 to parse")
        }

        // SwiftMath renders the variable as the italic math-alphanumeric
        // codepoint, and normalizeGlyphKey folds it back — this asserts the
        // *normalized* sequence glyphStrokes actually gets looked up with.
        let keys = placements.map(\.glyphKey)
        XCTAssertEqual(keys, ["x", "2", "+", "8", "x", "+", "1", "2", "=", "0"])
    }

    func testLayoutParenExpressionGlyphSequence() {
        guard let (placements, _) = TutorWriterLayout.layout(
            latex: "(x+2)(x+6)=0", at: .zero, height: 60
        ) else {
            return XCTFail("expected (x+2)(x+6)=0 to parse")
        }

        let keys = placements.map(\.glyphKey)
        XCTAssertEqual(keys, ["(", "x", "+", "2", ")", "(", "x", "+", "6", ")", "=", "0"])
    }

    func testLayoutReturnsNilForUnparseableLatex() {
        // A bare unterminated \frac (missing arguments) — SwiftMath surfaces
        // this as a parse error. Never crash on unknown latex (Task 11's
        // stated contract); layout() must fail closed with nil, not trap.
        let result = TutorWriterLayout.layout(latex: "\\notarealcommand{", at: .zero, height: 60)
        XCTAssertNil(result)
    }

    func testLayoutRejectsNonPositiveHeight() {
        XCTAssertNil(TutorWriterLayout.layout(latex: "x=1", at: .zero, height: 0))
        XCTAssertNil(TutorWriterLayout.layout(latex: "x=1", at: .zero, height: -10))
    }

    // MARK: - Exponent placement: smaller frame, higher (smaller canvas y)

    func testExponentFrameIsSmallerAndHigherThanBase() throws {
        guard let (placements, _) = TutorWriterLayout.layout(
            latex: "x^2+8x+12=0", at: .zero, height: 60
        ) else {
            return XCTFail("expected x^2+8x+12=0 to parse")
        }

        // Sequence from testLayoutProducesOneGlyphPerCharacterInReadingOrder:
        // index 0 = base "x", index 1 = exponent "2", index 3 = the "8" that
        // sits on the main baseline row (a same-row reference glyph).
        let base = try XCTUnwrap(placements[safe: 0])
        let exponent = try XCTUnwrap(placements[safe: 1])
        let mainRowDigit = try XCTUnwrap(placements[safe: 3]) // "8"

        XCTAssertEqual(base.glyphKey, "x")
        XCTAssertEqual(exponent.glyphKey, "2")
        XCTAssertEqual(mainRowDigit.glyphKey, "8")

        // Canvas space is y-down (Global Constraint): a smaller minY means
        // higher on the page. The exponent must sit above the base's top.
        XCTAssertLessThan(exponent.frame.minY, base.frame.minY, "exponent should be higher on the page than the base")
        XCTAssertLessThan(exponent.frame.maxY, base.frame.maxY, "exponent should not hang down as low as the base")

        // Smaller: SwiftMath typesets scripts at a reduced style/size.
        XCTAssertLessThan(exponent.frame.height, mainRowDigit.frame.height, "exponent should render smaller than a main-row digit")
        XCTAssertLessThan(exponent.frame.width, mainRowDigit.frame.width, "exponent should render narrower than a main-row digit")

        // The exponent sits to the right of the base it's attached to.
        XCTAssertGreaterThan(exponent.frame.minX, base.frame.minX)
    }

    func testWholeEquationBoundsMatchRequestedOriginAndHeight() {
        let origin = CGPoint(x: 60, y: 140)
        guard let (_, bounds) = TutorWriterLayout.layout(latex: "x^2+8x+12=0", at: origin, height: 60) else {
            return XCTFail("expected x^2+8x+12=0 to parse")
        }
        XCTAssertEqual(bounds.origin, origin)
        XCTAssertEqual(bounds.height, 60, accuracy: 0.001)
        XCTAssertGreaterThan(bounds.width, 0)
    }

    // MARK: - Glyph key normalization

    func testNormalizeGlyphKeyFoldsMathItalicLettersAndMinusSign() {
        XCTAssertEqual(TutorWriterLayout.normalizeGlyphKey("\u{1D465}"), "x") // MATHEMATICAL ITALIC SMALL X
        XCTAssertEqual(TutorWriterLayout.normalizeGlyphKey("\u{1D466}"), "y") // MATHEMATICAL ITALIC SMALL Y
        XCTAssertEqual(TutorWriterLayout.normalizeGlyphKey("\u{2212}"), "-")  // MINUS SIGN
        XCTAssertEqual(TutorWriterLayout.normalizeGlyphKey("7"), "7")
        XCTAssertEqual(TutorWriterLayout.normalizeGlyphKey("+"), "+")
        XCTAssertEqual(TutorWriterLayout.normalizeGlyphKey("("), "(")
    }

    // MARK: - Stroke scaling: unit box -> target frame

    func testScalePointMapsUnitBoxCornersToFrameCorners() {
        let frame = CGRect(x: 100, y: 50, width: 40, height: 20)
        XCTAssertEqual(TutorWriterLayout.scalePoint(CGPoint(x: 0, y: 0), into: frame), CGPoint(x: 100, y: 50))
        XCTAssertEqual(TutorWriterLayout.scalePoint(CGPoint(x: 1, y: 1), into: frame), CGPoint(x: 140, y: 70))
        XCTAssertEqual(TutorWriterLayout.scalePoint(CGPoint(x: 0.5, y: 0.5), into: frame), CGPoint(x: 120, y: 60))
    }

    func testScaleStrokePreservesPointCountAndOrder() {
        let unitStroke = [CGPoint(x: 0, y: 0), CGPoint(x: 0.5, y: 1), CGPoint(x: 1, y: 0.25)]
        let frame = CGRect(x: 10, y: 20, width: 8, height: 4)
        let scaled = TutorWriterLayout.scaleStroke(unitStroke, into: frame)

        XCTAssertEqual(scaled.count, unitStroke.count)
        XCTAssertEqual(scaled[0], CGPoint(x: 10, y: 20))
        XCTAssertEqual(scaled[1], CGPoint(x: 14, y: 24))
        XCTAssertEqual(scaled[2], CGPoint(x: 18, y: 21))
    }

    func testScaleStrokeIntoZeroSizedFrameCollapsesToOrigin() {
        // The "." special case from the plan: trust whatever (possibly
        // tiny) frame the typesetter gives — this only asserts the scaling
        // math degrades gracefully (no NaN/inf) at the zero-size extreme.
        let unitStroke = [CGPoint(x: 0.2, y: 0.8), CGPoint(x: 0.9, y: 0.1)]
        let frame = CGRect(x: 5, y: 5, width: 0, height: 0)
        let scaled = TutorWriterLayout.scaleStroke(unitStroke, into: frame)
        for point in scaled {
            XCTAssertEqual(point, CGPoint(x: 5, y: 5))
        }
    }

    // MARK: - Duration from arc length

    func testStrokeDurationScalesWithArcLength() {
        let short = TutorWriterLayout.strokeDuration(forArcLength: 45, speed: 450)
        let long = TutorWriterLayout.strokeDuration(forArcLength: 450, speed: 450)
        XCTAssertEqual(short, 0.1, accuracy: 0.001)
        XCTAssertEqual(long, 1.0, accuracy: 0.001)
        XCTAssertLessThan(short, long)
    }

    func testStrokeDurationHasAFloorForTinyStrokes() {
        let nearZero = TutorWriterLayout.strokeDuration(forArcLength: 0.001, speed: 450)
        XCTAssertEqual(nearZero, TutorWriterLayout.minimumStrokeDuration, accuracy: 0.0001)

        let zero = TutorWriterLayout.strokeDuration(forArcLength: 0, speed: 450)
        XCTAssertEqual(zero, TutorWriterLayout.minimumStrokeDuration, accuracy: 0.0001)
    }

    func testStrokeDurationStaysWithinNaturalWritingSpeedBand() {
        // The plan's band is ~300-600 pt/s; at the default speed a 300pt
        // stroke should land inside [300/600, 300/300] = [0.5, 1.0]s.
        let duration = TutorWriterLayout.strokeDuration(forArcLength: 300)
        XCTAssertGreaterThanOrEqual(duration, 300.0 / 600.0)
        XCTAssertLessThanOrEqual(duration, 300.0 / 300.0)
    }

    // MARK: - Polyline arc length (feeds the duration function)

    func testPolylineLengthOfStraightSegment() {
        let points = [CGPoint(x: 0, y: 0), CGPoint(x: 3, y: 4)]
        XCTAssertEqual(TutorWriterLayout.polylineLength(points), 5, accuracy: 0.0001)
    }

    func testPolylineLengthSumsMultipleSegments() {
        let points = [CGPoint(x: 0, y: 0), CGPoint(x: 3, y: 4), CGPoint(x: 3, y: 8)]
        XCTAssertEqual(TutorWriterLayout.polylineLength(points), 9, accuracy: 0.0001)
    }

    func testPolylineLengthOfSinglePointIsZero() {
        XCTAssertEqual(TutorWriterLayout.polylineLength([CGPoint(x: 5, y: 5)]), 0)
        XCTAssertEqual(TutorWriterLayout.polylineLength([]), 0)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
