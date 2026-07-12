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

    func testNormalizeGlyphKeyFoldsFullLatinItalicAlphabetIncludingHException() {
        // z/w — the glyphs-v2 battery's unknown-letter case: glyphStrokes
        // has no strokes for them yet, but normalizeGlyphKey must still
        // fold them to plain ASCII so the CATextLayer fallback gets a
        // renderable character instead of a styled codepoint.
        XCTAssertEqual(TutorWriterLayout.normalizeGlyphKey("\u{1D467}"), "z") // MATHEMATICAL ITALIC SMALL Z
        XCTAssertEqual(TutorWriterLayout.normalizeGlyphKey("\u{1D464}"), "w") // MATHEMATICAL ITALIC SMALL W
        XCTAssertEqual(TutorWriterLayout.normalizeGlyphKey("\u{1D44E}"), "a") // MATHEMATICAL ITALIC SMALL A (block start)
        XCTAssertEqual(TutorWriterLayout.normalizeGlyphKey("\u{1D434}"), "A") // MATHEMATICAL ITALIC CAPITAL A (block start)
        XCTAssertEqual(TutorWriterLayout.normalizeGlyphKey("\u{1D44D}"), "Z") // MATHEMATICAL ITALIC CAPITAL Z (block end)
        // Unicode carves italic lowercase "h" out of the main italic block
        // (it collides with the legacy PLANCK CONSTANT codepoint) — SwiftMath
        // emits U+210E for it instead of a codepoint inside 1D44E...1D467.
        XCTAssertEqual(TutorWriterLayout.normalizeGlyphKey("\u{210E}"), "h")
    }

    func testNormalizeGlyphKeyFoldsGreekItalicLettersIncludingFinalSigmaQuirk() {
        XCTAssertEqual(TutorWriterLayout.normalizeGlyphKey("\u{1D6FC}"), "\u{03B1}") // alpha (block start)
        XCTAssertEqual(TutorWriterLayout.normalizeGlyphKey("\u{1D70B}"), "\u{03C0}") // pi
        XCTAssertEqual(TutorWriterLayout.normalizeGlyphKey("\u{1D703}"), "\u{03B8}") // theta
        XCTAssertEqual(TutorWriterLayout.normalizeGlyphKey("\u{1D714}"), "\u{03C9}") // omega (block end)
        // Both the italic-math and plain Greek blocks insert "final sigma"
        // at the same point (between rho and sigma) — this only holds if
        // that insertion point lines up, so it's asserted explicitly rather
        // than assumed to fall out of the alpha/pi/theta/omega spot checks.
        XCTAssertEqual(TutorWriterLayout.normalizeGlyphKey("\u{1D70D}"), "\u{03C2}") // final sigma
    }

    // MARK: - Fraction layout (\frac{a}{b} -> MTFractionDisplay)

    func testFractionLayoutStacksNumeratorBarDenominatorTopToBottom() throws {
        guard let (placements, bounds) = TutorWriterLayout.layout(
            latex: "\\frac{1}{2}", at: .zero, height: 72
        ) else {
            return XCTFail("expected \\frac{1}{2} to parse")
        }

        let keys = placements.map(\.glyphKey)
        XCTAssertEqual(keys, ["1", "fracbar", "2"], "numerator, then bar, then denominator, in that walk order")

        let numerator = try XCTUnwrap(placements[safe: 0])
        let bar = try XCTUnwrap(placements[safe: 1])
        let denominator = try XCTUnwrap(placements[safe: 2])

        // Canvas space is y-down: numerator sits above the bar, denominator below it.
        XCTAssertLessThan(numerator.frame.maxY, bar.frame.minY + bar.frame.height, "numerator should be above the bar")
        XCTAssertLessThanOrEqual(bar.frame.maxY, denominator.frame.minY + 0.5, "bar should be above (or flush with) the denominator")
        XCTAssertLessThan(numerator.frame.minY, denominator.frame.minY, "numerator should render higher on the page than the denominator")

        // The bar spans the full equation width (Task 11's demo case is
        // single-digit num/denom, so the bar is the widest element).
        XCTAssertEqual(bar.frame.width, bounds.width, accuracy: 0.01)
        XCTAssertGreaterThan(bar.frame.width, 0)
        XCTAssertGreaterThan(bar.frame.height, 0)
    }

    // MARK: - Radical layout (\sqrt{a} -> MTRadicalDisplay)

    func testSqrtLayoutPlacesTickAndBarAroundRadicand() throws {
        guard let (placements, _) = TutorWriterLayout.layout(
            latex: "\\sqrt{16}", at: .zero, height: 72
        ) else {
            return XCTFail("expected \\sqrt{16} to parse")
        }

        let keys = placements.map(\.glyphKey)
        XCTAssertEqual(keys, ["1", "6", "fracbar", "√"], "radicand walked first, then the synthetic overbar/tick entries")

        let one = try XCTUnwrap(placements[safe: 0])
        let six = try XCTUnwrap(placements[safe: 1])
        let overbar = try XCTUnwrap(placements[safe: 2])
        let tick = try XCTUnwrap(placements[safe: 3])

        // The tick sits to the left of the radicand, and the overbar spans
        // (at least) the radicand's width, seamlessly continuing from the
        // tick's own top rather than leaving a visible gap. SwiftMath's own
        // vector-bar convention centers the bar's line-thickness on its
        // reference y (MTTypesetter.makeRadical's `lineStart`/`lineEnd`),
        // while the tick's glyph reaches exactly to that reference y — so a
        // sub-pixel seam of half the (unscaled, ~2pt) line thickness is
        // mathematically expected, not a bug; asserted as "small relative
        // to the tick's own size" rather than "zero," so this doesn't
        // become font-size-fragile.
        XCTAssertLessThanOrEqual(tick.frame.maxX, one.frame.minX + 0.5, "tick should sit left of the radicand")
        XCTAssertGreaterThanOrEqual(overbar.frame.width, six.frame.maxX - one.frame.minX - 0.5, "overbar should span the radicand's width")
        let seam = abs(tick.frame.minY - overbar.frame.minY)
        XCTAssertLessThan(seam, tick.frame.height * 0.1, "tick's top should meet the overbar with no visually distinct gap")

        XCTAssertGreaterThan(tick.frame.width, 0)
        XCTAssertGreaterThan(tick.frame.height, 0)
        XCTAssertGreaterThan(overbar.frame.width, 0)
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
