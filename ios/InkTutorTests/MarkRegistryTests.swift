import XCTest
import PencilKit
@testable import InkTutor

/// Monotonic clock so synthetic strokes get distinct, increasing creation
/// dates in call order — `MarkRegistry.compute` sorts strokes temporally,
/// and `Date()` calls made back-to-back in a test aren't guaranteed to be
/// distinct on every platform.
private enum TestStrokeClock {
    static var counter: TimeInterval = 0
    static func next() -> TimeInterval {
        counter += 1
        return counter
    }
}

/// Builds a `PKStroke` from a bare point array. Shared helper — Task 6's
/// gesture-classifier tests (currently cut, see plan Task 6) were meant to
/// reuse this too, so it's a free function, not a private test-case method.
func stroke(from points: [CGPoint]) -> PKStroke {
    let creationDate = Date(timeIntervalSince1970: TestStrokeClock.next())
    let controlPoints = points.enumerated().map { index, point in
        PKStrokePoint(
            location: point,
            timeOffset: TimeInterval(index) * 0.01,
            size: CGSize(width: 3, height: 3),
            opacity: 1,
            force: 1,
            azimuth: 0,
            altitude: .pi / 2
        )
    }
    let path = PKStrokePath(controlPoints: controlPoints, creationDate: creationDate)
    return PKStroke(ink: PKInk(.pen, color: .black), path: path)
}

final class MarkRegistryTests: XCTestCase {

    /// (a) Two words on one line -> 2 marks, same `line`.
    func testTwoWordsOnOneLineProduceTwoMarksSameLine() {
        let word1 = stroke(from: [CGPoint(x: 100, y: 500), CGPoint(x: 120, y: 510), CGPoint(x: 140, y: 500)])
        // Gap from word1's right edge (140) to word2's left edge (220) is
        // 80pt -- well past the 24pt same-mark threshold and past the 12pt
        // inflate, so these must NOT merge.
        let word2 = stroke(from: [CGPoint(x: 220, y: 500), CGPoint(x: 240, y: 510), CGPoint(x: 260, y: 500)])
        let drawing = PKDrawing(strokes: [word1, word2])

        let marks = MarkRegistry.compute(drawing: drawing)

        XCTAssertEqual(marks.count, 2)
        XCTAssertEqual(marks[0].line, marks[1].line)
    }

    /// (b) Two lines of writing -> different `line` values.
    func testTwoLinesProduceDifferentLineValues() {
        let line1 = stroke(from: [CGPoint(x: 100, y: 100), CGPoint(x: 120, y: 110), CGPoint(x: 140, y: 100)])
        // Directly below line1 (same x range) but 200pt lower -- far past
        // any plausible same-line threshold, and specifically chosen to
        // start at the SAME x as line1 so a naive x-only "gap to the
        // group's right edge" rule (negative gap here) would wrongly weld
        // it onto line1's mark if it didn't also check y-overlap.
        let line2 = stroke(from: [CGPoint(x: 100, y: 300), CGPoint(x: 120, y: 310), CGPoint(x: 140, y: 300)])
        let drawing = PKDrawing(strokes: [line1, line2])

        let marks = MarkRegistry.compute(drawing: drawing)

        XCTAssertEqual(marks.count, 2)
        XCTAssertNotEqual(marks[0].line, marks[1].line)
    }

    /// (c) Regression guard: an exponent (small stroke up-right of a base,
    /// overlapping vertical band) merges into the base's mark -- it must
    /// NOT become its own mark.
    func testExponentMergesIntoBaseMarkNotItsOwn() {
        let base = stroke(from: [CGPoint(x: 100, y: 500), CGPoint(x: 130, y: 530), CGPoint(x: 160, y: 500)])
        // Small, sits up and to the right of the base, x-range overlapping
        // the base's right portion (150...160), y-range just above it.
        let exponent = stroke(from: [CGPoint(x: 150, y: 485), CGPoint(x: 158, y: 490), CGPoint(x: 165, y: 485)])
        let drawing = PKDrawing(strokes: [base, exponent])

        let marks = MarkRegistry.compute(drawing: drawing)

        XCTAssertEqual(marks.count, 1, "exponent must merge into the base's mark, not form its own")
        XCTAssertEqual(marks.first?.strokeIndices.count, 2)
    }

    // MARK: - Stable IDs

    func testStableIDsAcrossRecompute() {
        let word1 = stroke(from: [CGPoint(x: 100, y: 500), CGPoint(x: 120, y: 510), CGPoint(x: 140, y: 500)])
        let word2 = stroke(from: [CGPoint(x: 220, y: 500), CGPoint(x: 240, y: 510), CGPoint(x: 260, y: 500)])
        let first = MarkRegistry.compute(drawing: PKDrawing(strokes: [word1, word2]))
        XCTAssertEqual(first.count, 2)

        // Recompute with an added third stroke far away; the first two
        // groups' bboxes are unchanged, so they must keep their old IDs.
        let word3 = stroke(from: [CGPoint(x: 100, y: 700), CGPoint(x: 120, y: 710), CGPoint(x: 140, y: 700)])
        let second = MarkRegistry.compute(
            drawing: PKDrawing(strokes: [word1, word2, word3]),
            previous: first
        )

        XCTAssertEqual(second.count, 3)
        let firstIDs = Set(first.map(\.id))
        let carriedOverIDs = Set(second.prefix(2).map(\.id))
        XCTAssertEqual(firstIDs, carriedOverIDs, "unchanged marks must keep their previous IDs")
        XCTAssertFalse(firstIDs.contains(second[2].id), "the new mark must get a fresh id, not reuse an old one")
    }

    // MARK: - registryJSON

    func testRegistryJSONFormat() {
        let marks = [Mark(id: 7, bbox: CGRect(x: 10.4, y: 20.6, width: 30.2, height: 5.9), line: 2, strokeIndices: [0])]
        let json = MarkRegistry.registryJSON(page: "student", marks: marks)
        XCTAssertEqual(json, "{\"page\":\"student\",\"marks\":[{\"id\":7,\"bbox\":[10,21,30,6],\"line\":2}]}")
    }
}
