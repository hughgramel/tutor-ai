import UIKit
import SwiftUI

/// The tutor's visual actions that reference existing ink by mark ID
/// (Global Constraint: "the model never emits coordinates for existing
/// content — mark IDs only"). This is `Task 8`'s `TutorTag` narrowed to the
/// four annotate-only primitives Task 9 renders; `WRITE`/`NEWPAGE`/`WAIT`
/// live elsewhere (`TagParser.swift`, `HandwritingWriter.swift`).
enum Annotation: Equatable {
    case circle(Mark)
    case underline(Mark)
    /// Killed (Hugh, 2026-07-12: "remove the highlighting tool it looks
    /// ugly, pointing is better"). `TutorCoordinator.dispatch(_:)` drops
    /// every `[HIGHLIGHT:id]` tag before it ever reaches `perform(_:)`, so
    /// this case — and `style(for:)`'s `.highlight` arm below,
    /// `RoughGeometry.highlightPath` — are dead code kept dormant rather
    /// than ripped out: cheap to leave, and it means a stray `.highlight`
    /// reaching this file some other way (a future caller, a test) still
    /// renders something sane instead of hitting an exhaustiveness gap.
    case highlight(Mark)
    case arrow(from: Mark, to: Mark)

    /// The tutor's own drawn diagram (`[SHAPE:...]`). Unlike the three
    /// cases above, this isn't anchored to existing ink via a `Mark` —
    /// `points` are normalized `0...1` vertices (see `TutorTag.shape`'s doc
    /// for why that's the one sanctioned exception to "the model never
    /// emits coordinates"), scaled by `performShape` into `box`. `box` is
    /// computed by `TutorCoordinator` (`nextShapeBox()`), not by this file —
    /// same placement law as `[WRITE:...]` (Hugh, 2026-07-12: "on the
    /// user's actual canvas... below the student's most recent work"),
    /// falling back to `RoughGeometry.shapeContentBox`'s fixed right-half
    /// box only when there's no room left below the work. This type just
    /// scales `points` into whatever `box` it's handed. Also unlike the
    /// three cases above, a shape does NOT flow through `AnnotationQueue`/
    /// `performAnimated`'s hold-then-fade lifecycle — `perform(_:)` routes
    /// it straight to `performShape`, and it stays on screen until
    /// `clearShapes()` removes it (it's the tutor's diagram, not a
    /// transient pointer gesture).
    case shape(kind: String, points: [CGPoint], label: String?, box: CGRect)
}

// MARK: - Queue

/// FIFO queue enforcing "one visual action at a time" (G8 in the plan's
/// guardrail spec) — pure state machine, no CoreAnimation, so it's testable
/// without a run loop. `AnnotationOverlayView` owns one instance.
final class AnnotationQueue {
    private var items: [Annotation] = []

    /// True while an annotation is enqueued and not yet finished (either
    /// mid-flight/mid-draw/holding/fading, or waiting its turn).
    private(set) var isRunning = false

    /// The annotation that should currently be playing (or about to start).
    var current: Annotation? { items.first }

    var isEmpty: Bool { items.isEmpty }

    /// Appends `annotation`. Returns `true` if the caller should start
    /// playing it now (the queue was idle) — `false` if it's now waiting
    /// behind one already in flight.
    @discardableResult
    func enqueue(_ annotation: Annotation) -> Bool {
        items.append(annotation)
        if !isRunning {
            isRunning = true
            return true
        }
        return false
    }

    /// Call when the in-flight annotation's full sequence (fly → draw →
    /// hold → fade) completes. Advances the queue; `current` now points at
    /// the next annotation to play, if any.
    func finishCurrent() {
        guard !items.isEmpty else {
            isRunning = false
            return
        }
        items.removeFirst()
        isRunning = !items.isEmpty
    }
}

// MARK: - Pure geometry

/// Hand-wobble path generation and flight-arc math — the geometry
/// `AnnotationOverlayView` animates. Pure functions over `CGRect`/`CGPoint`
/// (never `Mark`, so this stays reusable and trivially testable). Ported
/// from `reference/clicky/OverlayWindow.swift`'s bezier-flight code where
/// noted; the plan's Global Constraints call out the Clicky-first rule for
/// this task.
enum RoughGeometry {

    // MARK: Seeded RNG

    /// Deterministic linear-congruential generator so wobble paths are
    /// reproducible under a fixed seed (required for
    /// `AnnotationGeometryTests`) while still looking hand-varied run to
    /// run when seeded from e.g. the current time.
    struct SeededGenerator: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) {
            state = seed == 0 ? 0xdeadbeef : seed
        }
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    // MARK: Closed Catmull-Rom (hand-wobble ellipse)

    /// The 4 jittered control points a wobbly circle is built from: an
    /// ellipse (`bbox` inflated by `inflate`) sampled at 4 angles, each
    /// radius scaled by `1 ± jitterFraction`. Exposed separately from the
    /// spline so geometry tests can check the jitter bound directly instead
    /// of reverse-engineering it from a flattened curve.
    static func wobblePoints(
        around bbox: CGRect,
        inflate: CGFloat = 10,
        jitterFraction: CGFloat = 0.06,
        controlPointCount: Int = 4,
        seed: UInt64 = 1
    ) -> [CGPoint] {
        var rng = SeededGenerator(seed: seed)
        let inflated = bbox.insetBy(dx: -inflate, dy: -inflate)
        let center = CGPoint(x: inflated.midX, y: inflated.midY)
        let a = inflated.width / 2
        let b = inflated.height / 2
        var points: [CGPoint] = []
        points.reserveCapacity(controlPointCount)
        for i in 0..<controlPointCount {
            let theta = (CGFloat(i) / CGFloat(controlPointCount)) * 2 * .pi
            let jitter = 1 + CGFloat.random(in: -jitterFraction...jitterFraction, using: &rng)
            let x = center.x + a * cos(theta) * jitter
            let y = center.y + b * sin(theta) * jitter
            points.append(CGPoint(x: x, y: y))
        }
        return points
    }

    /// Closes `points` into a smooth loop via Catmull-Rom → cubic Bezier
    /// conversion (uniform, alpha=0). Pure geometry — no dependency on the
    /// ellipse case above, so it's independently testable and reusable.
    static func catmullRomClosed(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard points.count >= 3 else {
            if let first = points.first { path.move(to: first) }
            return path
        }
        let n = points.count
        path.move(to: points[0])
        for i in 0..<n {
            let p0 = points[(i - 1 + n) % n]
            let p1 = points[i]
            let p2 = points[(i + 1) % n]
            let p3 = points[(i + 2) % n]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        path.closeSubpath()
        return path
    }

    /// Grows `bbox` symmetrically around its center so neither dimension is
    /// smaller than `minDimension`. A written-mark bbox is a single glyph
    /// (~20-40pt) — circling it at its raw size reads as a scribble on top
    /// of the character, not a deliberate circle around it (Hugh,
    /// 2026-07-12 addendum).
    static func minimumCircleBBox(_ bbox: CGRect, minDimension: CGFloat = 34) -> CGRect {
        guard bbox.width < minDimension || bbox.height < minDimension else { return bbox }
        let width = max(bbox.width, minDimension)
        let height = max(bbox.height, minDimension)
        return CGRect(x: bbox.midX - width / 2, y: bbox.midY - height / 2, width: width, height: height)
    }

    /// The full wobbly-circle path around `bbox` — 4 jittered control
    /// points, closed Catmull-Rom.
    static func wobbleEllipsePath(
        around bbox: CGRect,
        inflate: CGFloat = 10,
        jitterFraction: CGFloat = 0.06,
        seed: UInt64 = 1
    ) -> CGPath {
        catmullRomClosed(wobblePoints(around: bbox, inflate: inflate, jitterFraction: jitterFraction, seed: seed))
    }

    // MARK: Underline

    /// A wobbly underline: slight downward sag at the midpoint, small
    /// overshoot past both ends of `bbox` — how an underline actually reads
    /// as hand-drawn instead of a ruled line.
    static func underlinePath(under bbox: CGRect, overshoot: CGFloat = 6, gap: CGFloat = 4, seed: UInt64 = 1) -> CGPath {
        var rng = SeededGenerator(seed: seed)
        let baseY = bbox.maxY + gap
        let start = CGPoint(x: bbox.minX - overshoot, y: baseY + CGFloat.random(in: -1...1, using: &rng))
        let end = CGPoint(x: bbox.maxX + overshoot, y: baseY + CGFloat.random(in: -1...1, using: &rng))
        let sagY = baseY + 3 + CGFloat.random(in: -1...1, using: &rng)
        let control = CGPoint(x: (start.x + end.x) / 2, y: sagY)

        let path = CGMutablePath()
        path.move(to: start)
        path.addQuadCurve(to: end, control: control)
        return path
    }

    // MARK: Highlight

    /// A single left→right sweep at `bbox`'s vertical center. Drawn with a
    /// thick, translucent, round-capped stroke by the caller (not a fill
    /// that appears) so `strokeEnd` animation reads as a marker swipe.
    static func highlightPath(over bbox: CGRect, inset: CGFloat = 4) -> CGPath {
        let y = bbox.midY
        let path = CGMutablePath()
        path.move(to: CGPoint(x: bbox.minX - inset, y: y))
        path.addLine(to: CGPoint(x: bbox.maxX + inset, y: y))
        return path
    }

    // MARK: Arrow

    /// Where a line from `rect`'s center toward `point` crosses `rect`'s
    /// boundary — used to start/end an arrow just outside each mark's ink
    /// rather than at its (possibly buried) center.
    static func pointOnEdge(of rect: CGRect, towards point: CGPoint) -> CGPoint {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let dx = point.x - center.x
        let dy = point.y - center.y
        if dx == 0 && dy == 0 { return CGPoint(x: rect.maxX, y: center.y) }
        let halfW = rect.width / 2
        let halfH = rect.height / 2
        let scaleX = dx != 0 ? halfW / abs(dx) : .greatestFiniteMagnitude
        let scaleY = dy != 0 ? halfH / abs(dy) : .greatestFiniteMagnitude
        let scale = min(scaleX, scaleY)
        return CGPoint(x: center.x + dx * scale, y: center.y + dy * scale)
    }

    /// Ported verbatim from `OverlayWindow.animateBezierFlightArc`'s control
    /// point: `arcHeight = min(distance * 0.2, 80.0)`, offset off the
    /// midpoint. Clicky always offsets "up" (screen space, cursor mostly
    /// travels horizontally); a page-space arrow can connect marks in any
    /// direction, so this generalizes Clicky's fixed vertical offset to the
    /// perpendicular of the A→B line — same magnitude formula, correct
    /// direction for any arrow.
    static func arcControlPoint(from a: CGPoint, to b: CGPoint, curvature: CGFloat = 0.2, maxOffset: CGFloat = 80) -> CGPoint {
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        let dx = b.x - a.x
        let dy = b.y - a.y
        let dist = hypot(dx, dy)
        guard dist > 0 else { return mid }
        let perp = CGPoint(x: -dy / dist, y: dx / dist)
        let offset = min(dist * curvature, maxOffset)
        return CGPoint(x: mid.x + perp.x * offset, y: mid.y + perp.y * offset)
    }

    /// Tangent of a quadratic bezier at `t`. Ported verbatim from
    /// `OverlayWindow.animateBezierFlightArc`'s rotation calc:
    /// `B'(t) = 2(1-t)(P1-P0) + 2t(P2-P1)`.
    static func quadraticTangent(at t: CGFloat, p0: CGPoint, p1: CGPoint, p2: CGPoint) -> CGPoint {
        let oneMinusT = 1 - t
        let x = 2 * oneMinusT * (p1.x - p0.x) + 2 * t * (p2.x - p1.x)
        let y = 2 * oneMinusT * (p1.y - p0.y) + 2 * t * (p2.y - p1.y)
        return CGPoint(x: x, y: y)
    }

    /// True when `a` and `b` sit on roughly the same line of writing:
    /// either their bboxes overlap vertically, or the vertical gap between
    /// their centers is small relative to the horizontal gap. Decides
    /// whether `arrowPath` renders a same-line "distribution arc" (bows up,
    /// never crosses the written line) or the generic perpendicular arc
    /// (different lines, e.g. pointing down from one step to the next).
    static func isSameLine(_ a: CGRect, _ b: CGRect) -> Bool {
        if a.minY < b.maxY && b.minY < a.maxY { return true } // vertical overlap
        let dy = abs(a.midY - b.midY)
        let dx = abs(a.midX - b.midX)
        guard dx > 0 else { return false }
        return dy < dx * 0.5
    }

    /// A same-line "distribution arc" (Hugh, 2026-07-12: "make sure we can
    /// correctly render arc circles underneath" — the demo's rainbow-arc
    /// moment, e.g. showing 2 distributing into `(x+5)`). The generic
    /// perpendicular-offset `arcControlPoint` above doesn't guarantee a
    /// direction, so a same-line pair could bow DOWN through the written
    /// line depending on which mark comes first. This forces the control
    /// point above both glyphs' top edges, arc height proportional to
    /// horizontal distance (clamped 12...60), tip landing at the TARGET's
    /// top edge (not its buried center) — always lifts off the page, never
    /// crosses the ink.
    static func distributionArcPath(from fromRect: CGRect, to toRect: CGRect) -> (path: CGPath, controlPoint: CGPoint) {
        let start = CGPoint(x: fromRect.midX, y: fromRect.minY)
        let end = CGPoint(x: toRect.midX, y: toRect.minY)
        let dx = abs(end.x - start.x)
        let arcHeight = min(max(dx * 0.35, 12), 60)
        let control = CGPoint(x: (start.x + end.x) / 2, y: min(fromRect.minY, toRect.minY) - arcHeight)

        let path = CGMutablePath()
        path.move(to: start)
        path.addQuadCurve(to: end, control: control)

        let tangent = quadraticTangent(at: 1.0, p0: start, p1: control, p2: end)
        let angle = atan2(tangent.y, tangent.x)
        let headLength: CGFloat = 12
        let headAngle: CGFloat = .pi / 7
        let left = CGPoint(x: end.x - headLength * cos(angle - headAngle), y: end.y - headLength * sin(angle - headAngle))
        let right = CGPoint(x: end.x - headLength * cos(angle + headAngle), y: end.y - headLength * sin(angle + headAngle))
        path.addLine(to: left)
        path.move(to: end)
        path.addLine(to: right)

        return (path, control)
    }

    /// A curved arrow from `fromRect` to `toRect`, arrowhead baked into the
    /// tail of the same `CGPath` so animating `strokeEnd` 0→1 draws the
    /// shaft first and the tip last for free. Same-line pairs (`isSameLine`)
    /// route to `distributionArcPath` instead — see its doc.
    static func arrowPath(from fromRect: CGRect, to toRect: CGRect, seed: UInt64 = 1) -> (path: CGPath, controlPoint: CGPoint) {
        if isSameLine(fromRect, toRect) {
            return distributionArcPath(from: fromRect, to: toRect)
        }

        let fromCenter = CGPoint(x: fromRect.midX, y: fromRect.midY)
        let toCenter = CGPoint(x: toRect.midX, y: toRect.midY)
        let start = pointOnEdge(of: fromRect, towards: toCenter)
        let end = pointOnEdge(of: toRect, towards: fromCenter)
        let control = arcControlPoint(from: start, to: end)

        let path = CGMutablePath()
        path.move(to: start)
        path.addQuadCurve(to: end, control: control)

        let tangent = quadraticTangent(at: 1.0, p0: start, p1: control, p2: end)
        let angle = atan2(tangent.y, tangent.x)
        let headLength: CGFloat = 12
        let headAngle: CGFloat = .pi / 7
        let left = CGPoint(x: end.x - headLength * cos(angle - headAngle), y: end.y - headLength * sin(angle - headAngle))
        let right = CGPoint(x: end.x - headLength * cos(angle + headAngle), y: end.y - headLength * sin(angle + headAngle))
        path.addLine(to: left)
        path.move(to: end)
        path.addLine(to: right)

        return (path, control)
    }

    // MARK: Flight timing (ported from OverlayWindow.animateBezierFlightArc)

    /// Smoothstep ease (Hermite): `3t² - 2t³`. Ported verbatim from
    /// `OverlayWindow`'s per-frame easing.
    static func smoothstep(_ t: CGFloat) -> CGFloat {
        t * t * (3 - 2 * t)
    }

    /// Quadratic bezier position at `t`. Ported verbatim from
    /// `OverlayWindow.animateBezierFlightArc`'s `bezierX`/`bezierY`.
    static func quadraticBezierPoint(_ t: CGFloat, p0: CGPoint, p1: CGPoint, p2: CGPoint) -> CGPoint {
        let oneMinusT = 1 - t
        let x = oneMinusT * oneMinusT * p0.x + 2 * oneMinusT * t * p1.x + t * t * p2.x
        let y = oneMinusT * oneMinusT * p0.y + 2 * oneMinusT * t * p1.y + t * t * p2.y
        return CGPoint(x: x, y: y)
    }

    /// Flight duration for a pointer hop of `distance` points. The plan's
    /// Task 9 Step 2 explicitly tightens Clicky's own `clamp(dist/800,
    /// 0.6–1.4)s` to `clamp(dist/800, 0.35–0.9)s` "iPad distances are
    /// smaller" — same divisor (800), same shape, tighter clamp band.
    static func flightDuration(distance: CGFloat, divisor: CGFloat = 800, low: TimeInterval = 0.35, high: TimeInterval = 0.9) -> TimeInterval {
        min(max(Double(distance / divisor), low), high)
    }

    // MARK: Path introspection (for pointer placement + draw-duration sizing)

    /// The first point of `path` (its initial `moveTo`) — where the pointer
    /// should land before the path starts drawing.
    static func startPoint(of path: CGPath) -> CGPoint {
        var result: CGPoint = .zero
        var found = false
        path.applyWithBlock { elementPointer in
            guard !found else { return }
            let element = elementPointer.pointee
            if element.type == .moveToPoint {
                result = element.points[0]
                found = true
            }
        }
        return result
    }

    /// The last point drawn along `path` — where the pointer should end up
    /// once the path finishes drawing (the arrow tip, the end of an
    /// underline, etc).
    static func endPoint(of path: CGPath) -> CGPoint {
        var result: CGPoint = .zero
        var subpathStart: CGPoint = .zero
        path.applyWithBlock { elementPointer in
            let element = elementPointer.pointee
            switch element.type {
            case .moveToPoint:
                result = element.points[0]
                subpathStart = result
            case .addLineToPoint:
                result = element.points[0]
            case .addQuadCurveToPoint:
                result = element.points[1]
            case .addCurveToPoint:
                result = element.points[2]
            case .closeSubpath:
                result = subpathStart
            @unknown default:
                break
            }
        }
        return result
    }

    /// Approximate path length via its control polygon (sum of distances
    /// between consecutive anchor/control points). Slightly overestimates
    /// curved segments, which is fine here — it only sizes an animation
    /// duration, not a rendered measurement.
    static func approximateLength(of path: CGPath) -> CGFloat {
        var length: CGFloat = 0
        var current: CGPoint = .zero
        var subpathStart: CGPoint = .zero
        path.applyWithBlock { elementPointer in
            let element = elementPointer.pointee
            switch element.type {
            case .moveToPoint:
                current = element.points[0]
                subpathStart = current
            case .addLineToPoint:
                let p = element.points[0]
                length += hypot(p.x - current.x, p.y - current.y)
                current = p
            case .addQuadCurveToPoint:
                let cp = element.points[0]
                let p = element.points[1]
                length += hypot(cp.x - current.x, cp.y - current.y) + hypot(p.x - cp.x, p.y - cp.y)
                current = p
            case .addCurveToPoint:
                let c1 = element.points[0]
                let c2 = element.points[1]
                let p = element.points[2]
                length += hypot(c1.x - current.x, c1.y - current.y)
                    + hypot(c2.x - c1.x, c2.y - c1.y)
                    + hypot(p.x - c2.x, p.y - c2.y)
                current = p
            case .closeSubpath:
                length += hypot(subpathStart.x - current.x, subpathStart.y - current.y)
                current = subpathStart
            @unknown default:
                break
            }
        }
        return length
    }

    /// True if the last element `path` emitted was `.closeSubpath` — the
    /// literal "polygon closes" check the plan's Task 9 test asks for.
    static func endsWithCloseSubpath(_ path: CGPath) -> Bool {
        var last: CGPathElementType?
        path.applyWithBlock { elementPointer in
            last = elementPointer.pointee.type
        }
        return last == .closeSubpath
    }

    // MARK: - SHAPE geometry (normalized vertices -> page-space diagram)

    /// Maps `points` (each `x`/`y` normalized `0...1`) into `rect`,
    /// top-left-anchored: `(0,0)` -> `rect.origin`, `(1,1)` ->
    /// `rect.origin + rect.size`. Pure, so scaling is testable without a
    /// live view.
    static func scaleNormalizedPoints(_ points: [CGPoint], into rect: CGRect) -> [CGPoint] {
        points.map { CGPoint(x: rect.minX + $0.x * rect.width, y: rect.minY + $0.y * rect.height) }
    }

    /// The FALLBACK page-space box a `[SHAPE:...]` diagram draws into: the
    /// right half of the shared page, inset on all sides. `TutorCoordinator
    /// .nextShapeBox()` only reaches for this when there's no room left
    /// below the student's work (Hugh, 2026-07-12 revision: primary
    /// placement is "on the user's actual canvas... below the student's
    /// most recent work," matching `[WRITE:...]`'s law — this box is the
    /// same "overflow to the right" escape hatch WRITE falls back to).
    static func shapeContentBox(pageSize: CGSize, insetFraction: CGFloat = 0.12) -> CGRect {
        let rightHalf = CGRect(x: pageSize.width * 0.5, y: 0, width: pageSize.width * 0.5, height: pageSize.height)
        return rightHalf.insetBy(dx: rightHalf.width * insetFraction, dy: rightHalf.height * insetFraction)
    }

    /// Axis-aligned bounding box of `points`. `.zero` for an empty array —
    /// callers that care (`jitterVertices`) already guard emptiness
    /// separately.
    static func boundingBox(of points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .zero }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in points.dropFirst() {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// The centroid (mean) of `points` — where a shape's label lands.
    static func centroid(of points: [CGPoint]) -> CGPoint {
        guard !points.isEmpty else { return .zero }
        let sum = points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: sum.x / CGFloat(points.count), y: sum.y / CGFloat(points.count))
    }

    /// Nudges each of `points` by up to `jitterFraction` of the shape's own
    /// bounding-box diagonal, in a random direction — the same
    /// "off by a jittered amount" idea `wobblePoints` uses for the ellipse
    /// case, generalized to arbitrary vertices (a polygon/curve's own
    /// corners) instead of points sampled off a bbox perimeter.
    static func jitterVertices(_ points: [CGPoint], jitterFraction: CGFloat = 0.02, seed: UInt64 = 1) -> [CGPoint] {
        guard !points.isEmpty else { return points }
        var rng = SeededGenerator(seed: seed)
        let diagonal = hypot(boundingBox(of: points).width, boundingBox(of: points).height)
        let maxJitter = max(diagonal * jitterFraction, 1)
        return points.map { p in
            let angle = CGFloat.random(in: 0...(2 * .pi), using: &rng)
            let magnitude = CGFloat.random(in: 0...maxJitter, using: &rng)
            return CGPoint(x: p.x + cos(angle) * magnitude, y: p.y + sin(angle) * magnitude)
        }
    }

    /// Closed wobbly polygon through `points` (already page-space, already
    /// jittered by the caller if desired) — same Catmull-Rom-through-
    /// jittered-points family as `wobbleEllipsePath`, but through the
    /// caller's own vertices instead of points sampled off an ellipse, so a
    /// 3-vertex triangle reads as a triangle, not a circle.
    static func wobblePolygonPath(through points: [CGPoint], jitterFraction: CGFloat = 0.015, seed: UInt64 = 1) -> CGPath {
        catmullRomClosed(jitterVertices(points, jitterFraction: jitterFraction, seed: seed))
    }

    /// A single hand-drawn segment from `start` to `end` — `line`'s
    /// primitive. Slight perpendicular bow at the midpoint (same idea as
    /// `underlinePath`'s sag) so it reads as drawn, not ruled.
    static func wobblyLinePath(from start: CGPoint, to end: CGPoint, bowFraction: CGFloat = 0.03, seed: UInt64 = 1) -> CGPath {
        var rng = SeededGenerator(seed: seed)
        let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        let dx = end.x - start.x
        let dy = end.y - start.y
        let dist = hypot(dx, dy)
        let perp = dist > 0 ? CGPoint(x: -dy / dist, y: dx / dist) : .zero
        let bow = dist * bowFraction * CGFloat.random(in: 0.5...1.5, using: &rng)
        let control = CGPoint(x: mid.x + perp.x * bow, y: mid.y + perp.y * bow)

        let path = CGMutablePath()
        path.move(to: start)
        path.addQuadCurve(to: end, control: control)
        return path
    }

    /// A smooth curve threaded through `points` (already page-space) —
    /// `curve`'s primitive. Standard "smooth polyline" quad-curve chaining:
    /// each interior point is a quadratic control point, and the curve's
    /// actual on-path anchors are the midpoints between consecutive
    /// points — so with exactly 3 points this is one continuous
    /// `addQuadCurve(to: points[2], control: points[1])` (start and end are
    /// ON the curve, the middle point pulls it), and with more points it
    /// keeps reading as one continuous bend instead of visible joints.
    static func quadraticCurvePath(through points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count >= 3 else {
            if points.count == 2 { path.addLine(to: points[1]) }
            return path
        }
        for i in 1..<(points.count - 1) {
            let control = points[i]
            let next = points[i + 1]
            let isLastSegment = i == points.count - 2
            let end = isLastSegment ? next : CGPoint(x: (control.x + next.x) / 2, y: (control.y + next.y) / 2)
            path.addQuadCurve(to: end, control: control)
        }
        return path
    }
}

// MARK: - Pointer

/// The small "tutor's finger" that flies to a target before an annotation
/// draws itself, then rides the annotation's path tip while it draws.
/// Kept as its own tiny type so `AnnotationOverlayView` isn't doing layer
/// bookkeeping inline.
private final class TutorPointer {
    let imageView: UIImageView

    init() {
        // Minimalist triangle cursor (Hugh, 2026-07-12: "more triangle,
        // minimalist"). location.north.fill is a clean filled triangle;
        // blue to match the tutor's ink, subtle shadow, smaller.
        let config = UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
        let image = UIImage(systemName: "location.north.fill", withConfiguration: config)
        imageView = UIImageView(image: image)
        imageView.tintColor = UIColor.systemBlue.withAlphaComponent(0.85)
        imageView.sizeToFit()
        imageView.layer.shadowColor = UIColor.black.cgColor
        imageView.layer.shadowOpacity = 0.2
        imageView.layer.shadowRadius = 2
        imageView.layer.shadowOffset = CGSize(width: 0, height: 1)
        imageView.alpha = 0
        imageView.isUserInteractionEnabled = false
    }
}

// MARK: - AnnotationOverlayView

/// Transparent, non-interactive `UIView` that performs the tutor's
/// annotate-only visual actions (Task 8's `.circle`/`.underline`/
/// `.highlight`/`.arrow` `TutorTag`s) in CANVAS/page-space coordinates.
///
/// This view's own bounds are always the page size (0...pageSize) — it
/// never resizes for zoom. Instead `setZoom(_:contentOffset:)` mirrors
/// `CanvasView.swift`'s `Coordinator.syncUnderlay()` (the same pattern the
/// PDF underlay uses to track the canvas's native `PKCanvasView` scroll
/// zoom): top-left-anchored scale by `zoom`, positioned by
/// `-contentOffset`. That keeps every path in this file in page points —
/// Global Constraint "canvas space everywhere" — while still rendering at
/// the right screen position/size at any zoom level.
///
/// `perform(_:)` queues one `Annotation` at a time (`AnnotationQueue`):
/// pointer flies to the target → the primitive draws itself in with hand
/// wobble → holds → fades out. Ephemeral by default — nothing here mutates
/// any `PageModel.drawing`; this view only ever draws on its own transient
/// `CAShapeLayer`s.
final class AnnotationOverlayView: UIView {

    /// Hold time before an annotation starts fading.
    static let holdDuration: TimeInterval = 3.0
    /// Fade-out duration once the hold ends.
    static let fadeDuration: TimeInterval = 1.0

    let pageSize: CGSize
    private let pointer = TutorPointer()
    private let queue = AnnotationQueue()

    /// Failsafe: the pointer must never outlive the action it's pointing
    /// for (Hugh, 2026-07-13: "make sure the cursor is removed / fades out
    /// when not talking"). Every flight re-arms this; if the normal
    /// after-draw fade is skipped for any reason (interrupted animation
    /// chain, dropped tag mid-queue), this hides it regardless.
    private var pointerFailsafe: DispatchWorkItem?

    private func armPointerFailsafe(after seconds: TimeInterval) {
        pointerFailsafe?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.pointer.imageView.alpha > 0 else { return }
            UIView.animate(withDuration: 0.3) { self.pointer.imageView.alpha = 0 }
        }
        pointerFailsafe = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    init(pageSize: CGSize) {
        self.pageSize = pageSize
        super.init(frame: CGRect(origin: .zero, size: pageSize))
        isUserInteractionEnabled = false
        backgroundColor = .clear
        // Anchor at the top-left so `setZoom` can scale/position this view
        // exactly like `CanvasView`'s paperView frame math, instead of
        // UIKit's default center-anchored `transform`.
        layer.anchorPoint = .zero
        layer.position = .zero
        addSubview(pointer.imageView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Call from the hosting screen's `UIScrollViewDelegate` callbacks
    /// (`scrollViewDidScroll`/`scrollViewDidZoom`), passing the same
    /// `canvasView.zoomScale`/`contentOffset` `CanvasView.Coordinator`
    /// already reads for the PDF underlay.
    func setZoom(_ zoom: CGFloat, contentOffset: CGPoint) {
        layer.position = CGPoint(x: -contentOffset.x, y: -contentOffset.y)
        layer.transform = CATransform3DMakeScale(zoom, zoom, 1)
    }

    /// Queues `annotation`. If nothing is currently mid-flight it starts
    /// immediately; otherwise it plays after everything ahead of it
    /// finishes (fly → draw → hold → fade), enforcing "one visual action at
    /// a time."
    func perform(_ annotation: Annotation) {
        // `.shape` has its own lifecycle (no hold+fade, stays until
        // `clearShapes()`), so it bypasses `AnnotationQueue` entirely
        // instead of forcing that queue's fly/draw/hold/fade shape onto a
        // primitive that doesn't fade. See `Annotation.shape`'s doc.
        if case .shape(let kind, let points, let label, let box) = annotation {
            performShape(kind: kind, points: points, label: label, box: box)
            return
        }
        if queue.enqueue(annotation) {
            runCurrent()
        }
    }

    // MARK: - Sequence: fly -> draw -> hold -> fade

    private func runCurrent() {
        guard let annotation = queue.current else { return }
        performAnimated(annotation) { [weak self] in
            guard let self else { return }
            self.queue.finishCurrent()
            if self.queue.current != nil {
                self.runCurrent()
            }
        }
    }

    private func style(for annotation: Annotation) -> (path: CGPath, color: UIColor, lineWidth: CGFloat) {
        let seed = UInt64.random(in: 1...UInt64.max) // no two renders identical
        switch annotation {
        case .circle(let mark):
            let bbox = RoughGeometry.minimumCircleBBox(mark.bbox)
            return (RoughGeometry.wobbleEllipsePath(around: bbox, seed: seed), .systemRed, 3)
        case .underline(let mark):
            return (RoughGeometry.underlinePath(under: mark.bbox, seed: seed), .systemRed, 3)
        case .highlight(let mark):
            let lineWidth = max(mark.bbox.height * 0.8, 10)
            return (RoughGeometry.highlightPath(over: mark.bbox), UIColor.systemYellow.withAlphaComponent(0.4), lineWidth)
        case .arrow(let from, let to):
            return (RoughGeometry.arrowPath(from: from.bbox, to: to.bbox, seed: seed).path, .systemRed, 3)
        case .shape:
            // Unreachable: `perform(_:)` routes `.shape` straight to
            // `performShape` before it ever reaches the queue/`style(for:)`.
            // This arm exists only so the switch above stays exhaustive.
            preconditionFailure("Annotation.shape bypasses performAnimated; see performShape")
        }
    }

    private func performAnimated(_ annotation: Annotation, completion: @escaping () -> Void) {
        let (path, color, lineWidth) = style(for: annotation)
        let target = RoughGeometry.startPoint(of: path)
        let tip = RoughGeometry.endPoint(of: path)
        let pathLength = RoughGeometry.approximateLength(of: path)

        let shapeLayer = CAShapeLayer()
        shapeLayer.path = path
        shapeLayer.fillColor = UIColor.clear.cgColor
        shapeLayer.strokeColor = color.cgColor
        shapeLayer.lineWidth = lineWidth
        shapeLayer.lineCap = .round
        shapeLayer.lineJoin = .round
        shapeLayer.strokeEnd = 0
        layer.addSublayer(shapeLayer)

        // Pointer flight: from wherever it currently sits (or `target`, the
        // first time) to the annotation's start point.
        let start = pointer.imageView.layer.presentation()?.position ?? pointer.imageView.center
        let flightStart = pointer.imageView.alpha > 0 ? start : target
        let distance = hypot(target.x - flightStart.x, target.y - flightStart.y)
        let flightDuration = RoughGeometry.flightDuration(distance: distance)

        pointer.imageView.center = flightStart
        pointer.imageView.alpha = 1
        // Generous upper bound on flight + draw; re-armed per annotation.
        armPointerFailsafe(after: flightDuration + 4.0)
        let flight = CAKeyframeAnimation(keyPath: "position")
        let controlPoint = RoughGeometry.arcControlPoint(from: flightStart, to: target)
        let flightPath = CGMutablePath()
        flightPath.move(to: flightStart)
        flightPath.addQuadCurve(to: target, control: controlPoint)
        flight.path = flightPath
        flight.duration = flightDuration
        flight.timingFunction = CAMediaTimingFunction(controlPoints: 0, 0, 1, 1) // smoothstep-like ease
        flight.calculationMode = .cubicPaced
        pointer.imageView.layer.position = target
        pointer.imageView.layer.add(flight, forKey: "flight")

        DispatchQueue.main.asyncAfter(deadline: .now() + flightDuration) { [weak self] in
            guard let self else { return }

            // Draw-in: "the speed of a hand, not a machine."
            let drawDuration = 0.3 + Double(pathLength / 1200)
            let draw = CABasicAnimation(keyPath: "strokeEnd")
            draw.fromValue = 0
            draw.toValue = 1
            draw.duration = drawDuration
            draw.timingFunction = CAMediaTimingFunction(name: .easeOut)
            shapeLayer.strokeEnd = 1
            shapeLayer.add(draw, forKey: "draw")

            // Pointer rides the same path, same duration, so it looks like
            // it's the one drawing the line.
            let ride = CAKeyframeAnimation(keyPath: "position")
            ride.path = path
            ride.duration = drawDuration
            ride.calculationMode = .cubicPaced
            ride.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.pointer.imageView.layer.position = tip
            self.pointer.imageView.layer.add(ride, forKey: "ride")

            // Pointer's job ends the moment the ink is drawn — vanish promptly
            // (Hugh, 2026-07-12: it was lingering through the whole 3s hold
            // + fade). The annotation itself still holds, then fades.
            DispatchQueue.main.asyncAfter(deadline: .now() + drawDuration) {
                let pointerFade = CABasicAnimation(keyPath: "opacity")
                pointerFade.fromValue = 1
                pointerFade.toValue = 0
                pointerFade.duration = 0.25
                self.pointer.imageView.layer.opacity = 0
                self.pointer.imageView.layer.add(pointerFade, forKey: "fadePointer")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    self.pointer.imageView.alpha = 0
                    self.pointer.imageView.layer.opacity = 1 // reset for next flight-in
                }
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + drawDuration + Self.holdDuration) {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 1
                fade.toValue = 0
                fade.duration = Self.fadeDuration
                shapeLayer.opacity = 0
                shapeLayer.add(fade, forKey: "fadeShape")

                DispatchQueue.main.asyncAfter(deadline: .now() + Self.fadeDuration) {
                    shapeLayer.removeFromSuperlayer()
                    completion()
                }
            }
        }
    }

    // MARK: - SHAPE primitive (diagrams the tutor draws on its own page)

    /// Rounded system font — reads as "a tutor's board hand", same
    /// convention `TutorWriter.fallbackFont` uses for its `CATextLayer`
    /// fallback glyphs.
    private static let shapeLabelFont: UIFont = {
        let base = UIFont.systemFont(ofSize: 15, weight: .medium)
        let descriptor = base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor
        return UIFont(descriptor: descriptor, size: 15)
    }()

    /// Every shape/label layer currently on screen — tracked so
    /// `clearShapes()` can remove exactly them, nothing else.
    private var shapeLayers: [CAShapeLayer] = []
    private var shapeLabelLayers: [CATextLayer] = []

    /// Removes every `[SHAPE:...]` diagram drawn so far. Shapes don't
    /// auto-fade the way `.circle`/`.underline`/`.highlight`/`.arrow` do
    /// (they're the tutor's own diagram, meant to stay up while it's being
    /// discussed) — this is the explicit clear, e.g. on `[NEWPAGE]` or
    /// whenever the caller decides the diagram is done being useful.
    func clearShapes() {
        shapeLayers.forEach { $0.removeFromSuperlayer() }
        shapeLayers.removeAll()
        shapeLabelLayers.forEach { $0.removeFromSuperlayer() }
        shapeLabelLayers.removeAll()
    }

    /// Draws one `[SHAPE:...]` diagram: scales `points` into `box` (computed
    /// upstream by `TutorCoordinator.nextShapeBox()` — see `Annotation.shape`'s
    /// doc), builds the wobbly path for `kind`, and animates it in with the
    /// same `strokeEnd` 0->1 draw-in language `performAnimated` uses — but
    /// pen-style (solid black, 3pt: it's the tutor DRAWING, not annotating
    /// existing ink in red) and with no pointer flight, no hold timer, no
    /// fade. Deliberately a separate method rather than a branch inside
    /// `performAnimated`, so this file's existing animation function is
    /// untouched.
    private func performShape(kind: String, points: [CGPoint], label: String?, box: CGRect) {
        guard points.count >= 2 else {
            TutorLog.shared.info("AnnotationOverlayView: dropped SHAPE:\(kind) — fewer than 2 points")
            return
        }

        let scaled = RoughGeometry.scaleNormalizedPoints(points, into: box)
        let seed = UInt64.random(in: 1...UInt64.max) // no two renders identical

        let path: CGPath
        switch kind {
        case "polygon":
            path = RoughGeometry.wobblePolygonPath(through: scaled, seed: seed)
        case "curve":
            path = RoughGeometry.quadraticCurvePath(through: RoughGeometry.jitterVertices(scaled, jitterFraction: 0.015, seed: seed))
        default: // "line", and any other kind that somehow made it past the parser
            path = RoughGeometry.wobblyLinePath(from: scaled.first!, to: scaled.last!, seed: seed)
        }

        let shapeLayer = CAShapeLayer()
        shapeLayer.path = path
        shapeLayer.fillColor = UIColor.clear.cgColor
        shapeLayer.strokeColor = UIColor.systemBlue.cgColor
        shapeLayer.lineWidth = 3
        shapeLayer.lineCap = .round
        shapeLayer.lineJoin = .round
        shapeLayer.strokeEnd = 0
        layer.addSublayer(shapeLayer)
        shapeLayers.append(shapeLayer)

        let pathLength = RoughGeometry.approximateLength(of: path)
        let drawDuration = 0.3 + Double(pathLength / 1200)
        let draw = CABasicAnimation(keyPath: "strokeEnd")
        draw.fromValue = 0
        draw.toValue = 1
        draw.duration = drawDuration
        draw.timingFunction = CAMediaTimingFunction(name: .easeOut)
        shapeLayer.strokeEnd = 1
        shapeLayer.add(draw, forKey: "draw")

        guard let label, !label.isEmpty else { return }
        addShapeLabel(label, centeredAt: RoughGeometry.centroid(of: scaled), afterDelay: drawDuration)
    }

    /// The shape's label: small handwriting-adjacent text (same rounded
    /// font family `TutorWriter`'s fallback glyphs use) fading in near the
    /// shape's centroid once the shape itself finishes drawing.
    private func addShapeLabel(_ text: String, centeredAt centroid: CGPoint, afterDelay delay: TimeInterval) {
        let font = Self.shapeLabelFont
        let size = (text as NSString).size(withAttributes: [.font: font])

        let textLayer = CATextLayer()
        textLayer.string = text
        textLayer.font = font.fontName as CFTypeRef
        textLayer.fontSize = font.pointSize
        textLayer.foregroundColor = UIColor.systemBlue.cgColor
        textLayer.alignmentMode = .center
        textLayer.contentsScale = UIScreen.main.scale
        textLayer.frame = CGRect(x: centroid.x - size.width / 2, y: centroid.y - size.height / 2, width: size.width, height: size.height)
        textLayer.opacity = 0
        layer.addSublayer(textLayer)
        shapeLabelLayers.append(textLayer)

        let fadeIn = CABasicAnimation(keyPath: "opacity")
        fadeIn.fromValue = 0
        fadeIn.toValue = 1
        fadeIn.duration = 0.3
        fadeIn.beginTime = CACurrentMediaTime() + delay
        fadeIn.fillMode = .forwards
        textLayer.opacity = 1
        textLayer.add(fadeIn, forKey: "labelFadeIn")
    }
}

// MARK: - Debug harness

#if DEBUG
/// Wraps `AnnotationOverlayView` for Xcode's canvas so a human can eyeball
/// each primitive (Task 9 Step 5's pass condition is a person watching it,
/// not a unit test). Performs all four primitives on fake `Mark`s spread
/// down a blank page; `perform` queues them so they play one at a time.
private struct AnnotationOverlayPreview: UIViewRepresentable {
    static let pageSize = CGSize(width: 768, height: 1024)

    func makeUIView(context: Context) -> UIView {
        let container = UIView(frame: CGRect(origin: .zero, size: Self.pageSize))
        container.backgroundColor = .white

        let overlay = AnnotationOverlayView(pageSize: Self.pageSize)
        overlay.frame = container.bounds
        overlay.setZoom(1, contentOffset: .zero)
        container.addSubview(overlay)

        let markA = Mark(id: 1, bbox: CGRect(x: 80, y: 100, width: 160, height: 36), line: 0, strokeIndices: [0])
        let markB = Mark(id: 2, bbox: CGRect(x: 120, y: 220, width: 220, height: 36), line: 1, strokeIndices: [1])
        let markC = Mark(id: 3, bbox: CGRect(x: 100, y: 340, width: 180, height: 36), line: 2, strokeIndices: [2])
        let markD = Mark(id: 4, bbox: CGRect(x: 420, y: 480, width: 160, height: 36), line: 3, strokeIndices: [3])

        overlay.perform(.circle(markA))
        overlay.perform(.underline(markB))
        overlay.perform(.highlight(markC))
        overlay.perform(.arrow(from: markA, to: markD))

        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

#Preview("Annotation primitives") {
    AnnotationOverlayPreview()
        .frame(width: AnnotationOverlayPreview.pageSize.width, height: AnnotationOverlayPreview.pageSize.height)
}
#endif
