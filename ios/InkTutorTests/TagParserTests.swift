import XCTest
@testable import InkTutor

/// `TagParser` consumes streamed transcript deltas and must never leak a
/// half-formed `[TAG...` fragment into the subtitle, never crash on
/// malformed input, and never lose a tag that happens to straddle two
/// deltas. Cases mirror the plan's Task 8 test list plus the split-across-
/// chunks/malformed/pass-through cases called out in the task brief.
final class TagParserTests: XCTestCase {

    // MARK: - From the plan (Task 8, Step 1) verbatim

    func testTagSplitAcrossChunks() {
        let p = TagParser()
        let r1 = p.feed("so [CIR")
        XCTAssertEqual(r1.tags.count, 0)
        XCTAssertEqual(r1.subtitleText, "so ")
        let r2 = p.feed("CLE:7] right here")
        XCTAssertEqual(r2.tags, [.circle(7)])
        XCTAssertEqual(r2.subtitleText, " right here")
    }

    func testWriteTag() {
        let r = TagParser().feed("[WRITE:x^2+6x+5=0|below:last]")
        XCTAssertEqual(r.tags, [.write(latex: "x^2+6x+5=0", anchor: .belowLast)])
    }

    func testUnknownTagDropped() {
        // model invents [ERASE:3] → stripped from subtitles, no action
        let r = TagParser().feed("[ERASE:3] gone")
        XCTAssertEqual(r.tags, [])
        XCTAssertEqual(r.subtitleText, " gone")
    }

    // MARK: - Split across more than two chunks

    func testTagSplitAcrossThreeChunks() {
        let p = TagParser()
        let r1 = p.feed("look [UND")
        XCTAssertEqual(r1.tags, [])
        XCTAssertEqual(r1.subtitleText, "look ")

        let r2 = p.feed("ERLI")
        XCTAssertEqual(r2.tags, [])
        XCTAssertEqual(r2.subtitleText, "")

        let r3 = p.feed("NE:4] here")
        XCTAssertEqual(r3.tags, [.underline(4)])
        XCTAssertEqual(r3.subtitleText, " here")
    }

    // MARK: - Multiple tags in one delta

    func testTwoTagsInOneDelta() {
        let r = TagParser().feed("[CIRCLE:1] and [UNDERLINE:2] both now")
        XCTAssertEqual(r.tags, [.circle(1), .underline(2)])
        XCTAssertEqual(r.subtitleText, " and  both now")
    }

    // MARK: - Tag at the very start / very end of the stream

    func testTagAtVeryStartOfStream() {
        let r = TagParser().feed("[HIGHLIGHT:9] is the key step")
        XCTAssertEqual(r.tags, [.highlight(9)])
        XCTAssertEqual(r.subtitleText, " is the key step")
    }

    func testTagAtVeryEndOfStream() {
        let r = TagParser().feed("the key step is [HIGHLIGHT:9]")
        XCTAssertEqual(r.tags, [.highlight(9)])
        XCTAssertEqual(r.subtitleText, "the key step is ")
    }

    // MARK: - Malformed tags never crash, never leak into subtitles

    func testMalformedCircleMissingId() {
        let r = TagParser().feed("[CIRCLE:] gone too")
        XCTAssertEqual(r.tags, [])
        XCTAssertEqual(r.subtitleText, " gone too")
    }

    func testMalformedBogusTagName() {
        let r = TagParser().feed("[BOGUS:1] also gone")
        XCTAssertEqual(r.tags, [])
        XCTAssertEqual(r.subtitleText, " also gone")
    }

    func testMalformedCircleNonNumericId() {
        let r = TagParser().feed("[CIRCLE:abc] nope")
        XCTAssertEqual(r.tags, [])
        XCTAssertEqual(r.subtitleText, " nope")
    }

    // MARK: - Text-only stream passes through untouched

    func testTextOnlyStreamPassesThroughUntouched() {
        let text = "Let's check the second term of your expansion — looks solid so far."
        let r = TagParser().feed(text)
        XCTAssertEqual(r.tags, [])
        XCTAssertEqual(r.subtitleText, text)
    }

    // MARK: - ARROW id pair parsing

    func testArrowIdPairParsing() {
        let r = TagParser().feed("[ARROW:3>7] connects those")
        XCTAssertEqual(r.tags, [.arrow(3, 7)])
        XCTAssertEqual(r.subtitleText, " connects those")
    }

    func testArrowMalformedMissingSecondId() {
        let r = TagParser().feed("[ARROW:3>] nope")
        XCTAssertEqual(r.tags, [])
    }

    // MARK: - WRITE latex containing `]`-free pipes

    func testWriteLatexContainingPipes() {
        // The LaTeX body itself contains `|` (absolute value bars); the
        // anchor suffix must still be found from the *last* `|`, not the first.
        let r = TagParser().feed("[WRITE:|x|+1|below:7]")
        XCTAssertEqual(r.tags, [.write(latex: "|x|+1", anchor: .below(7))])
    }

    func testWriteBelowIdAnchor() {
        let r = TagParser().feed("[WRITE:2x=10|below:3]")
        XCTAssertEqual(r.tags, [.write(latex: "2x=10", anchor: .below(3))])
    }

    // MARK: - flush() releases dangling partial-tag text

    func testFlushReleasesDanglingPartialTag() {
        let p = TagParser()
        let r1 = p.feed("hold on [WRI")
        XCTAssertEqual(r1.tags, [])
        XCTAssertEqual(r1.subtitleText, "hold on ")

        let r2 = p.flush()
        XCTAssertEqual(r2.tags, [])
        XCTAssertEqual(r2.subtitleText, "[WRI")
    }

    func testFlushOnCleanStreamIsEmpty() {
        let p = TagParser()
        _ = p.feed("nothing pending here")
        let r = p.flush()
        XCTAssertEqual(r.tags, [])
        XCTAssertEqual(r.subtitleText, "")
    }

    // MARK: - Pending tail gives up past the 400-char budget

    func testPendingTagGivesUpPastBudget() {
        let p = TagParser()
        let overlong = "[" + String(repeating: "x", count: 401)
        let r = p.feed(overlong)
        XCTAssertEqual(r.tags, [])
        XCTAssertEqual(r.subtitleText, overlong)
    }

    // MARK: - PLOT: accepted, never crash (still a stretch tag — no renderer)

    func testPlotTagAcceptedAsUnsupportedPayload() {
        let r = TagParser().feed("[PLOT:y=sin(x)] there")
        XCTAssertEqual(r.tags, [.plot("y=sin(x)")])
        XCTAssertEqual(r.subtitleText, " there")
    }

    // MARK: - SHAPE: `[SHAPE:kind:x,y;x,y;...:label]`, promoted to a real grammar

    func testShapePolygonTriangleWithLabel() {
        let r = TagParser().feed("[SHAPE:polygon:0.1,0.9;0.9,0.9;0.9,0.1:right triangle] there")
        XCTAssertEqual(r.tags, [.shape(
            kind: "polygon",
            points: [CGPoint(x: 0.1, y: 0.9), CGPoint(x: 0.9, y: 0.9), CGPoint(x: 0.9, y: 0.1)],
            label: "right triangle"
        )])
        XCTAssertEqual(r.subtitleText, " there")
    }

    func testShapeCurveThroughThreePoints() {
        let r = TagParser().feed("[SHAPE:curve:0.1,0.5;0.5,0.1;0.9,0.5:arc]")
        XCTAssertEqual(r.tags, [.shape(
            kind: "curve",
            points: [CGPoint(x: 0.1, y: 0.5), CGPoint(x: 0.5, y: 0.1), CGPoint(x: 0.9, y: 0.5)],
            label: "arc"
        )])
    }

    func testShapeMissingLabelDefaultsToEmptyString() {
        let r = TagParser().feed("[SHAPE:line:0.2,0.2;0.8,0.8]")
        XCTAssertEqual(r.tags, [.shape(kind: "line", points: [CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.8, y: 0.8)], label: "")])
    }

    func testShapeMalformedVertexDropsWholeTag() {
        let r = TagParser().feed("[SHAPE:polygon:0.1,0.1;bad;0.5,0.9:x] gone")
        XCTAssertEqual(r.tags, [])
        XCTAssertEqual(r.subtitleText, " gone")
    }

    func testShapeUnknownKindDropped() {
        let r = TagParser().feed("[SHAPE:blob:0.1,0.1;0.2,0.2] gone")
        XCTAssertEqual(r.tags, [])
        XCTAssertEqual(r.subtitleText, " gone")
    }

    func testShapeFewerThanTwoVerticesDropped() {
        let r = TagParser().feed("[SHAPE:line:0.5,0.5] gone")
        XCTAssertEqual(r.tags, [])
        XCTAssertEqual(r.subtitleText, " gone")
    }

    func testShapeOutOfRangeVerticesAreClamped() {
        let r = TagParser().feed("[SHAPE:line:-0.5,0.2;1.5,1.8:edge]")
        XCTAssertEqual(r.tags, [.shape(kind: "line", points: [CGPoint(x: 0, y: 0.2), CGPoint(x: 1, y: 1)], label: "edge")])
    }

    // MARK: - NEWPAGE and WAIT

    func testNewPageTag() {
        let r = TagParser().feed("[NEWPAGE] let's try a fresh one")
        XCTAssertEqual(r.tags, [.newPage])
        XCTAssertEqual(r.subtitleText, " let's try a fresh one")
    }

    func testWaitTag() {
        let r = TagParser().feed("[WAIT:5] thinking")
        XCTAssertEqual(r.tags, [.wait(5)])
        XCTAssertEqual(r.subtitleText, " thinking")
    }
}
