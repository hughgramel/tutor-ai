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
    case highlight(Mark)
    case arrow(from: Mark, to: Mark)
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

    /// A curved arrow from `fromRect` to `toRect`, arrowhead baked into the
    /// tail of the same `CGPath` so animating `strokeEnd` 0→1 draws the
    /// shaft first and the tip last for free.
    static func arrowPath(from fromRect: CGRect, to toRect: CGRect, seed: UInt64 = 1) -> (path: CGPath, controlPoint: CGPoint) {
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
}

// MARK: - Pointer

/// The small "tutor's finger" that flies to a target before an annotation
/// draws itself, then rides the annotation's path tip while it draws.
/// Kept as its own tiny type so `AnnotationOverlayView` isn't doing layer
/// bookkeeping inline.
private final class TutorPointer {
    let imageView: UIImageView

    init() {
        let config = UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold)
        let image = UIImage(systemName: "hand.point.up.left.fill", withConfiguration: config)
        imageView = UIImageView(image: image)
        imageView.tintColor = .systemBlue
        imageView.sizeToFit()
        imageView.layer.shadowColor = UIColor.black.cgColor
        imageView.layer.shadowOpacity = 0.35
        imageView.layer.shadowRadius = 3
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
            return (RoughGeometry.wobbleEllipsePath(around: mark.bbox, seed: seed), .systemRed, 3)
        case .underline(let mark):
            return (RoughGeometry.underlinePath(under: mark.bbox, seed: seed), .systemRed, 3)
        case .highlight(let mark):
            let lineWidth = max(mark.bbox.height * 0.8, 10)
            return (RoughGeometry.highlightPath(over: mark.bbox), UIColor.systemYellow.withAlphaComponent(0.4), lineWidth)
        case .arrow(let from, let to):
            return (RoughGeometry.arrowPath(from: from.bbox, to: to.bbox, seed: seed).path, .systemRed, 3)
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

            DispatchQueue.main.asyncAfter(deadline: .now() + drawDuration + Self.holdDuration) {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 1
                fade.toValue = 0
                fade.duration = Self.fadeDuration
                shapeLayer.opacity = 0
                shapeLayer.add(fade, forKey: "fadeShape")
                self.pointer.imageView.layer.opacity = 0
                self.pointer.imageView.layer.add(fade, forKey: "fadePointer")

                DispatchQueue.main.asyncAfter(deadline: .now() + Self.fadeDuration) {
                    shapeLayer.removeFromSuperlayer()
                    self.pointer.imageView.alpha = 0
                    self.pointer.imageView.layer.opacity = 1 // reset for next flight-in fade
                    completion()
                }
            }
        }
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
