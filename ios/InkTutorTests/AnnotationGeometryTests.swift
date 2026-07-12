import XCTest
import CoreGraphics
@testable import InkTutor

/// Tests for `AnnotationOverlayView.swift`'s pure geometry (`RoughGeometry`)
/// and queue (`AnnotationQueue`) logic. Per the plan's Task 9: "animation
/// itself is verified visually later — do NOT try to unit-test
/// CoreAnimation." Nothing here touches `CAShapeLayer`/`CAKeyframeAnimation`;
/// everything is deterministic math over `CGPath`/`CGPoint`/`CGRect`.
final class AnnotationGeometryTests: XCTestCase {

    // MARK: - Wobble ellipse

    func testWobblePointsStayWithin15PercentOfIdealRadius() {
        let bbox = CGRect(x: 100, y: 200, width: 160, height: 40)
        let inflate: CGFloat = 10
        let jitterFraction: CGFloat = 0.06
        let points = RoughGeometry.wobblePoints(around: bbox, inflate: inflate, jitterFraction: jitterFraction, controlPointCount: 4, seed: 42)
        XCTAssertEqual(points.count, 4)

        let inflated = bbox.insetBy(dx: -inflate, dy: -inflate)
        let center = CGPoint(x: inflated.midX, y: inflated.midY)
        let a = inflated.width / 2
        let b = inflated.height / 2

        for (i, point) in points.enumerated() {
            let theta = (CGFloat(i) / CGFloat(points.count)) * 2 * .pi
            let idealX = a * cos(theta)
            let idealY = b * sin(theta)
            let idealMagnitude = hypot(idealX, idealY)
            let actualMagnitude = hypot(point.x - center.x, point.y - center.y)
            guard idealMagnitude > 0 else { continue }
            XCTAssertEqual(actualMagnitude / idealMagnitude, 1.0, accuracy: 0.15, "point \(i) strayed >15% from its ideal radius")
        }
    }

    func testWobblePointsAreDeterministicUnderSameSeed() {
        let bbox = CGRect(x: 0, y: 0, width: 100, height: 30)
        let a = RoughGeometry.wobblePoints(around: bbox, seed: 7)
        let b = RoughGeometry.wobblePoints(around: bbox, seed: 7)
        XCTAssertEqual(a, b)
    }

    func testWobblePointsDifferAcrossSeeds() {
        let bbox = CGRect(x: 0, y: 0, width: 100, height: 30)
        let a = RoughGeometry.wobblePoints(around: bbox, seed: 1)
        let b = RoughGeometry.wobblePoints(around: bbox, seed: 2)
        XCTAssertNotEqual(a, b)
    }

    func testWobbleEllipsePathClosesItself() {
        let bbox = CGRect(x: 50, y: 50, width: 120, height: 40)
        let path = RoughGeometry.wobbleEllipsePath(around: bbox, seed: 3)
        XCTAssertTrue(RoughGeometry.endsWithCloseSubpath(path), "wobbled ellipse polygon must close")
    }

    func testCatmullRomClosedIsClosedForAnyValidPolygon() {
        let points = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 10), CGPoint(x: 0, y: 10)]
        let path = RoughGeometry.catmullRomClosed(points)
        XCTAssertTrue(RoughGeometry.endsWithCloseSubpath(path))
        XCTAssertFalse(path.isEmpty)
    }

    // MARK: - Underline

    func testUnderlinePathOvershootsBothEnds() {
        let bbox = CGRect(x: 100, y: 100, width: 80, height: 20)
        let path = RoughGeometry.underlinePath(under: bbox, overshoot: 6, gap: 4, seed: 5)
        let start = RoughGeometry.startPoint(of: path)
        let end = RoughGeometry.endPoint(of: path)
        XCTAssertLessThan(start.x, bbox.minX, "underline should overshoot the left edge")
        XCTAssertGreaterThan(end.x, bbox.maxX, "underline should overshoot the right edge")
        XCTAssertGreaterThan(start.y, bbox.maxY, "underline should sit below the bbox")
    }

    func testUnderlinePathDeterministicUnderSameSeed() {
        let bbox = CGRect(x: 0, y: 0, width: 80, height: 20)
        let p1 = RoughGeometry.startPoint(of: RoughGeometry.underlinePath(under: bbox, seed: 9))
        let p2 = RoughGeometry.startPoint(of: RoughGeometry.underlinePath(under: bbox, seed: 9))
        XCTAssertEqual(p1, p2)
    }

    // MARK: - Highlight

    func testHighlightPathSweepsFullBboxWidth() {
        let bbox = CGRect(x: 20, y: 20, width: 100, height: 30)
        let path = RoughGeometry.highlightPath(over: bbox, inset: 4)
        let start = RoughGeometry.startPoint(of: path)
        let end = RoughGeometry.endPoint(of: path)
        XCTAssertEqual(start.x, bbox.minX - 4, accuracy: 0.001)
        XCTAssertEqual(end.x, bbox.maxX + 4, accuracy: 0.001)
        XCTAssertEqual(start.y, bbox.midY, accuracy: 0.001)
        XCTAssertEqual(end.y, bbox.midY, accuracy: 0.001)
    }

    // MARK: - Arrow control-point math (ported from OverlayWindow.animateBezierFlightArc)

    func testArcControlPointMatchesClickyClampFormula() {
        // Horizontal line, distance 100 -> offset should be min(100*0.2, 80) = 20,
        // perpendicular to a horizontal line is vertical.
        let a = CGPoint(x: 0, y: 0)
        let b = CGPoint(x: 100, y: 0)
        let control = RoughGeometry.arcControlPoint(from: a, to: b)
        XCTAssertEqual(control.x, 50, accuracy: 0.001)
        XCTAssertEqual(abs(control.y), 20, accuracy: 0.001)
    }

    func testArcControlPointOffsetClampsAt80() {
        // Distance 1000 -> uncapped 1000*0.2 = 200, must clamp to 80.
        let a = CGPoint(x: 0, y: 0)
        let b = CGPoint(x: 1000, y: 0)
        let control = RoughGeometry.arcControlPoint(from: a, to: b)
        XCTAssertEqual(abs(control.y), 80, accuracy: 0.001)
    }

    func testArcControlPointDegenerateWhenPointsCoincide() {
        let p = CGPoint(x: 5, y: 5)
        let control = RoughGeometry.arcControlPoint(from: p, to: p)
        XCTAssertEqual(control, p)
    }

    func testQuadraticTangentMatchesClickyFormula() {
        // B'(t) = 2(1-t)(P1-P0) + 2t(P2-P1); at t=0 this reduces to 2(P1-P0).
        let p0 = CGPoint(x: 0, y: 0)
        let p1 = CGPoint(x: 10, y: 0)
        let p2 = CGPoint(x: 20, y: 10)
        let tangentAtStart = RoughGeometry.quadraticTangent(at: 0, p0: p0, p1: p1, p2: p2)
        XCTAssertEqual(tangentAtStart.x, 20, accuracy: 0.001)
        XCTAssertEqual(tangentAtStart.y, 0, accuracy: 0.001)
    }

    func testPointOnEdgeReturnsBoundaryPointTowardTarget() {
        let rect = CGRect(x: -10, y: -10, width: 20, height: 20) // centered at origin
        let edge = RoughGeometry.pointOnEdge(of: rect, towards: CGPoint(x: 1000, y: 0))
        XCTAssertEqual(edge.x, 10, accuracy: 0.001)
        XCTAssertEqual(edge.y, 0, accuracy: 0.001)
    }

    func testArrowPathStartsAndEndsNearMarkEdgesNotCenters() {
        // Genuinely different-line pair (dy well past isSameLine's dx*0.5
        // threshold) so this exercises the generic pointOnEdge/
        // arcControlPoint path, not the same-line distribution-arc path
        // below — also doubles as the "different-line arrows unchanged"
        // regression test from Hugh's 2026-07-12 arc-up addendum.
        let from = CGRect(x: 0, y: 0, width: 40, height: 20)
        let to = CGRect(x: 60, y: 300, width: 40, height: 20)
        XCTAssertFalse(RoughGeometry.isSameLine(from, to))
        let result = RoughGeometry.arrowPath(from: from, to: to, seed: 1)
        let start = RoughGeometry.startPoint(of: result.path)
        XCTAssertFalse(from.insetBy(dx: 0.001, dy: 0.001).contains(start), "arrow should start at from's edge, not inside its ink")
    }

    // MARK: - Same-line distribution arcs (Hugh, 2026-07-12: "make sure we
    // can correctly render arc circles underneath" — rainbow arcs must bow
    // UP, never down through the written line)

    func testSameLineArrowControlPointBowsAboveBothBoxes() {
        let from = CGRect(x: 0, y: 500, width: 30, height: 30) // e.g. the "2"
        let to = CGRect(x: 200, y: 500, width: 40, height: 30) // e.g. "(x+5)"
        XCTAssertTrue(RoughGeometry.isSameLine(from, to))
        let result = RoughGeometry.arrowPath(from: from, to: to, seed: 1)
        XCTAssertLessThan(result.controlPoint.y, from.minY, "control point must be above the source glyph")
        XCTAssertLessThan(result.controlPoint.y, to.minY, "control point must be above the target glyph")

        // The quad curve's own destination (not `RoughGeometry.endPoint`,
        // which walks to the LAST element — the arrowhead's second flank
        // line — not the tip) lands right at the target's top edge, not
        // its buried center.
        var quadCurveEnd: CGPoint = .zero
        result.path.applyWithBlock { elementPointer in
            if elementPointer.pointee.type == .addQuadCurveToPoint {
                quadCurveEnd = elementPointer.pointee.points[1]
            }
        }
        XCTAssertEqual(quadCurveEnd.x, to.midX, accuracy: 0.001)
        XCTAssertEqual(quadCurveEnd.y, to.minY, accuracy: 0.001)
    }

    func testSameLineArrowArcHeightScalesWithDistanceAndClamps() {
        let near = RoughGeometry.arrowPath(from: CGRect(x: 0, y: 0, width: 20, height: 20), to: CGRect(x: 20, y: 0, width: 20, height: 20))
        XCTAssertEqual(near.controlPoint.y, -12, accuracy: 0.001, "short hop clamps to the 12pt floor")

        let far = RoughGeometry.arrowPath(from: CGRect(x: 0, y: 0, width: 20, height: 20), to: CGRect(x: 1000, y: 0, width: 20, height: 20))
        XCTAssertEqual(far.controlPoint.y, -60, accuracy: 0.001, "long hop clamps to the 60pt ceiling")
    }

    // MARK: - Minimum circle size (Hugh, 2026-07-12 addendum: single
    // written glyphs are ~20-40pt, circle them at the same reading size)

    func testMinimumCircleBBoxLeavesLargeBoxesUntouched() {
        let bbox = CGRect(x: 10, y: 10, width: 100, height: 40)
        XCTAssertEqual(RoughGeometry.minimumCircleBBox(bbox), bbox)
    }

    func testMinimumCircleBBoxGrowsTinyGlyphSymmetricallyAroundCenter() {
        let bbox = CGRect(x: 100, y: 100, width: 18, height: 22) // a single "2"
        let grown = RoughGeometry.minimumCircleBBox(bbox, minDimension: 34)
        XCTAssertEqual(grown.width, 34, accuracy: 0.001)
        XCTAssertEqual(grown.height, 34, accuracy: 0.001)
        XCTAssertEqual(grown.midX, bbox.midX, accuracy: 0.001, "grows around the same center, doesn't shift the circle off the glyph")
        XCTAssertEqual(grown.midY, bbox.midY, accuracy: 0.001)
    }

    // MARK: - Flight timing (ported from OverlayWindow.animateBezierFlightArc)

    func testFlightDurationClampsLowForShortHops() {
        XCTAssertEqual(RoughGeometry.flightDuration(distance: 1), 0.35, accuracy: 0.001)
    }

    func testFlightDurationClampsHighForLongHops() {
        XCTAssertEqual(RoughGeometry.flightDuration(distance: 10_000), 0.9, accuracy: 0.001)
    }

    func testFlightDurationScalesWithDistanceInBetween() {
        // 400 / 800 = 0.5, within the 0.35...0.9 band, so it should pass through unclamped.
        XCTAssertEqual(RoughGeometry.flightDuration(distance: 400), 0.5, accuracy: 0.001)
    }

    func testSmoothstepEndpointsAndMidpoint() {
        XCTAssertEqual(RoughGeometry.smoothstep(0), 0, accuracy: 0.0001)
        XCTAssertEqual(RoughGeometry.smoothstep(1), 1, accuracy: 0.0001)
        XCTAssertEqual(RoughGeometry.smoothstep(0.5), 0.5, accuracy: 0.0001)
    }

    func testQuadraticBezierPointAtEndpoints() {
        let p0 = CGPoint(x: 0, y: 0)
        let p1 = CGPoint(x: 50, y: -80)
        let p2 = CGPoint(x: 100, y: 0)
        XCTAssertEqual(RoughGeometry.quadraticBezierPoint(0, p0: p0, p1: p1, p2: p2), p0)
        XCTAssertEqual(RoughGeometry.quadraticBezierPoint(1, p0: p0, p1: p1, p2: p2), p2)
    }

    // MARK: - Path introspection helpers

    func testApproximateLengthOfStraightLine() {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: 30, y: 40)) // 3-4-5 triangle, length 50
        XCTAssertEqual(RoughGeometry.approximateLength(of: path), 50, accuracy: 0.001)
    }

    func testStartAndEndPointOfSimplePath() {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 5, y: 5))
        path.addLine(to: CGPoint(x: 15, y: 25))
        XCTAssertEqual(RoughGeometry.startPoint(of: path), CGPoint(x: 5, y: 5))
        XCTAssertEqual(RoughGeometry.endPoint(of: path), CGPoint(x: 15, y: 25))
    }

    // MARK: - AnnotationQueue

    func testEnqueueOnIdleQueueStartsImmediately() {
        let queue = AnnotationQueue()
        let mark = Mark(id: 1, bbox: .zero, line: 0, strokeIndices: [])
        XCTAssertTrue(queue.enqueue(.circle(mark)))
        XCTAssertEqual(queue.current, .circle(mark))
    }

    func testEnqueueWhileRunningWaitsItsTurn() {
        let queue = AnnotationQueue()
        let first = Mark(id: 1, bbox: .zero, line: 0, strokeIndices: [])
        let second = Mark(id: 2, bbox: .zero, line: 0, strokeIndices: [])

        XCTAssertTrue(queue.enqueue(.circle(first)))
        XCTAssertFalse(queue.enqueue(.underline(second)), "second annotation must wait behind the first")
        XCTAssertEqual(queue.current, .circle(first), "the first annotation is still the one playing")
    }

    func testFinishCurrentAdvancesToNextInFIFOOrder() {
        let queue = AnnotationQueue()
        let first = Mark(id: 1, bbox: .zero, line: 0, strokeIndices: [])
        let second = Mark(id: 2, bbox: .zero, line: 0, strokeIndices: [])
        let third = Mark(id: 3, bbox: .zero, line: 0, strokeIndices: [])

        queue.enqueue(.circle(first))
        queue.enqueue(.underline(second))
        queue.enqueue(.highlight(third))

        queue.finishCurrent()
        XCTAssertEqual(queue.current, .underline(second))
        XCTAssertTrue(queue.isRunning)

        queue.finishCurrent()
        XCTAssertEqual(queue.current, .highlight(third))

        queue.finishCurrent()
        XCTAssertNil(queue.current)
        XCTAssertFalse(queue.isRunning)
    }

    func testFinishCurrentOnEmptyQueueIsSafe() {
        let queue = AnnotationQueue()
        queue.finishCurrent() // no-op, must not crash
        XCTAssertFalse(queue.isRunning)
        XCTAssertNil(queue.current)
    }

    // MARK: - SHAPE geometry: normalized -> page-space scaling

    func testScaleNormalizedPointsMapsUnitSquareCorners() {
        let rect = CGRect(x: 100, y: 200, width: 400, height: 800)
        let unitSquare = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)]
        let scaled = RoughGeometry.scaleNormalizedPoints(unitSquare, into: rect)
        XCTAssertEqual(scaled, [
            CGPoint(x: 100, y: 200),
            CGPoint(x: 500, y: 200),
            CGPoint(x: 500, y: 1000),
            CGPoint(x: 100, y: 1000),
        ])
    }

    func testScaleNormalizedPointsMapsMidpointToRectCenter() {
        let rect = CGRect(x: 0, y: 0, width: 200, height: 100)
        let scaled = RoughGeometry.scaleNormalizedPoints([CGPoint(x: 0.5, y: 0.5)], into: rect)
        XCTAssertEqual(scaled, [CGPoint(x: 100, y: 50)])
    }

    func testShapeContentBoxIsInsetFromRightHalfOfPage() {
        // Post-pivot: SHAPE lands in the right half of the shared page, not
        // the full page — same rule WRITE follows (Hugh, 2026-07-12: no
        // separate tutor page, diagrams land beside the student's ink).
        let pageSize = CGSize(width: 1000, height: 500)
        let box = RoughGeometry.shapeContentBox(pageSize: pageSize, insetFraction: 0.1)
        XCTAssertEqual(box, CGRect(x: 550, y: 50, width: 400, height: 400))
    }

    // MARK: - SHAPE geometry: centroid / bounding box

    func testCentroidOfSquareIsItsCenter() {
        let square = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 10), CGPoint(x: 0, y: 10)]
        XCTAssertEqual(RoughGeometry.centroid(of: square), CGPoint(x: 5, y: 5))
    }

    func testBoundingBoxOfPoints() {
        let points = [CGPoint(x: 3, y: 7), CGPoint(x: -2, y: 1), CGPoint(x: 5, y: -4)]
        let box = RoughGeometry.boundingBox(of: points)
        XCTAssertEqual(box, CGRect(x: -2, y: -4, width: 7, height: 11))
    }

    // MARK: - SHAPE geometry: vertex jitter

    func testJitterVerticesDeterministicUnderSameSeed() {
        let points = [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 50, y: 100)]
        let a = RoughGeometry.jitterVertices(points, seed: 11)
        let b = RoughGeometry.jitterVertices(points, seed: 11)
        XCTAssertEqual(a, b)
    }

    func testJitterVerticesStaysNearOriginalVertex() {
        let points = [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 50, y: 100)]
        let jittered = RoughGeometry.jitterVertices(points, jitterFraction: 0.02, seed: 3)
        let diagonal = hypot(RoughGeometry.boundingBox(of: points).width, RoughGeometry.boundingBox(of: points).height)
        for (original, moved) in zip(points, jittered) {
            let distance = hypot(moved.x - original.x, moved.y - original.y)
            XCTAssertLessThanOrEqual(distance, diagonal * 0.02 + 0.001)
        }
    }

    // MARK: - SHAPE geometry: polygon closure

    func testWobblePolygonPathClosesForTriangle() {
        let triangle = [CGPoint(x: 0, y: 100), CGPoint(x: 100, y: 100), CGPoint(x: 50, y: 0)]
        let path = RoughGeometry.wobblePolygonPath(through: triangle, seed: 4)
        XCTAssertTrue(RoughGeometry.endsWithCloseSubpath(path), "shape polygon must close")
        XCTAssertFalse(path.isEmpty)
    }

    // MARK: - SHAPE geometry: line

    func testWobblyLinePathStartsAndEndsAtGivenPoints() {
        let start = CGPoint(x: 10, y: 10)
        let end = CGPoint(x: 200, y: 150)
        let path = RoughGeometry.wobblyLinePath(from: start, to: end, seed: 6)
        XCTAssertEqual(RoughGeometry.startPoint(of: path), start)
        XCTAssertEqual(RoughGeometry.endPoint(of: path), end)
    }

    // MARK: - SHAPE geometry: curve

    func testQuadraticCurvePathThreePointsStartsAndEndsAtFirstAndLast() {
        let points = [CGPoint(x: 0, y: 50), CGPoint(x: 50, y: 0), CGPoint(x: 100, y: 50)]
        let path = RoughGeometry.quadraticCurvePath(through: points)
        XCTAssertEqual(RoughGeometry.startPoint(of: path), points[0])
        XCTAssertEqual(RoughGeometry.endPoint(of: path), points[2])
    }

    func testQuadraticCurvePathTwoPointsIsStraightLine() {
        let points = [CGPoint(x: 0, y: 0), CGPoint(x: 40, y: 30)]
        let path = RoughGeometry.quadraticCurvePath(through: points)
        XCTAssertEqual(RoughGeometry.startPoint(of: path), points[0])
        XCTAssertEqual(RoughGeometry.endPoint(of: path), points[1])
        XCTAssertEqual(RoughGeometry.approximateLength(of: path), 50, accuracy: 0.001) // 3-4-5 triangle * 10
    }

    func testQuadraticCurvePathFourPointsStartsAndEndsAtFirstAndLast() {
        let points = [CGPoint(x: 0, y: 0), CGPoint(x: 30, y: 60), CGPoint(x: 70, y: 60), CGPoint(x: 100, y: 0)]
        let path = RoughGeometry.quadraticCurvePath(through: points)
        XCTAssertEqual(RoughGeometry.startPoint(of: path), points[0])
        XCTAssertEqual(RoughGeometry.endPoint(of: path), points[3])
    }
}
