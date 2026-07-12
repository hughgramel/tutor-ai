import UIKit
import SwiftUI
import CoreText
import SwiftMath

/// The tutor's `[WRITE:latex|below:...]` primitive (Task 11 — "the money
/// shot"): given a latex string and an anchor, hand-writes the math on the
/// tutor's page. SwiftMath computes WHERE each glyph goes; `glyphStrokes`
/// (`Glyphs.generated.swift`) supplies the human pen strokes; `CAShapeLayer`
/// `strokeEnd` animation reveals each stroke in writing order at natural
/// speed. This is layout math + animation only — it never mutates
/// `PageModel.drawing` (Task 11's plan called for committing a `PKStroke` on
/// completion; that's deferred, see the file-level note on `TutorWriter`).
///
/// ## SwiftMath API notes (verified against the 1.7.3 source checkout, not
/// guessed — `MTTypesetter` and `MTFontManager.fontManager` are internal to
/// the package, so the only public entry point to a laid-out display tree is
/// `MTMathUILabel.displayList`, populated by forcing a layout pass):
///
/// - `MTMathUILabel.displayList: MTMathListDisplay?` (MTMathUILabel.swift:180)
///   is the public handle. Setting `.latex` calls `setNeedsLayout()`
///   (MTMathUILabel.swift:92); `layoutIfNeeded()` then synchronously runs
///   `_layoutSubviews()` (MTMathUILabel.swift:242/288) which typesets via the
///   internal `MTTypesetter` and populates `displayList`.
/// - `MTMathListDisplay.subDisplays: [MTDisplay]` (MTMathListDisplay.swift:218)
///   is public and recursive: nested `MTMathListDisplay`s appear for
///   sub/superscripts (confirmed empirically: `x^2` typesets as a top-level
///   `MTMathListDisplay` containing the base's `MTCTLineDisplay` plus a
///   *nested* `MTMathListDisplay` for the exponent, smaller and offset up).
/// - **The surprise the plan didn't anticipate:** SwiftMath does NOT create
///   one `MTDisplay` per glyph. A run of same-style, same-line atoms (e.g.
///   `+8x+12=0`) collapses into a single `MTCTLineDisplay` wrapping one
///   `CTLine`. `MTCTLineDisplay.line: CTLine!` and `.atoms: [MTMathAtom]`
///   (MTMathListDisplay.swift:119,129) are both public, so per-glyph frames
///   are recovered one level deeper via CoreText:
///   `CTLineGetGlyphRuns` → per run `CTRunGetGlyphs`/`CTRunGetPositions` →
///   `CTFontGetBoundingRectsForGlyphs` — the same technique
///   `MTCTLineDisplay.computeDimensions` (MTMathListDisplay.swift:163) uses
///   internally for the line's own ascent/descent. Each run's glyphs zip 1:1,
///   in order, against `atoms` (true for every symbol this glyph library
///   covers — digits, `x`/`y`, operators, parens — all single-character
///   nuclei; ligature-producing multi-char nuclei like `\sin` are out of
///   scope here).
/// - **`MTDisplay.position` is `internal`, not `public`** (MTMathListDisplay.swift:92)
///   — a real gap in the library's access control, not an oversight in this
///   file. It's a *stored* property, so `Mirror` reflection (which walks
///   runtime metadata, unconstrained by compile-time access control) reads
///   it reliably across the module boundary; verified empirically against a
///   throwaway SPM executable linked against the same 1.7.3 checkout before
///   writing this file. `Mirror(reflecting:)` only exposes a type's *own*
///   declared stored properties in `.children`; `position` is declared on
///   the `MTDisplay` base, so it surfaces one level up via
///   `.superclassMirror`.
/// - **SwiftMath's coordinate system is y-up, baseline-relative** (ascent
///   is the distance *above* baseline, descent *below*) — this is Global
///   Constraint territory ("canvas space everywhere... page points, origin
///   top-left") colliding with a typesetting library's native convention.
///   `layout(latex:at:height:)` below does the one deliberate flip, right at
///   the SwiftMath boundary, and everything downstream of it
///   (`GlyphPlacement.frame`) is already canvas-space y-down.
/// - Letters render as Unicode "Mathematical Alphanumeric Symbols" (`x` →
///   U+1D465 MATHEMATICAL ITALIC SMALL X), and `-` renders as U+2212 MINUS
///   SIGN, not ASCII hyphen — confirmed empirically parsing `"5-3=2"`.
///   `normalizeGlyphKey` folds both back to the ASCII keys `glyphStrokes`
///   uses.
enum TutorWriterLayout {

    /// One rendered glyph resolved from SwiftMath's display tree: the
    /// original character (for the CATextLayer fallback, which should show
    /// what was actually typeset, styling included), the normalized
    /// `glyphStrokes` lookup key, and the frame — already in page/canvas
    /// space (Global Constraint: "canvas space everywhere"), y-down,
    /// scaled+positioned per the `layout(latex:at:height:)` call that
    /// produced it.
    struct GlyphPlacement: Equatable {
        let character: String
        let glyphKey: String
        let frame: CGRect
    }

    /// Font size SwiftMath typesets at before `layout` rescales into the
    /// caller's `height`. Arbitrary but large enough for high-precision
    /// CoreText glyph metrics; doesn't otherwise affect the result, since
    /// every frame is rescaled by `height / (ascent + descent)` afterward.
    static let referenceFontSize: CGFloat = 48

    /// Parses and lays out `latex`, returning one `GlyphPlacement` per
    /// symbol (page/canvas space, y-down) plus the whole equation's
    /// bounding rect, scaled so the rendered math is `height` points tall
    /// and anchored with its top-left at `origin`. `nil` if `latex` fails to
    /// parse or SwiftMath's `position` API has moved out from under
    /// `Mirror`'s reach — both handled by the caller as "fall back, don't
    /// crash" (Task 11's stated contract for unknown/unparseable input).
    static func layout(latex: String, at origin: CGPoint, height: CGFloat) -> (placements: [GlyphPlacement], bounds: CGRect)? {
        guard height > 0 else { return nil }

        let label = MTMathUILabel(frame: CGRect(x: 0, y: 0, width: 4000, height: 4000))
        label.fontSize = referenceFontSize
        label.latex = latex
        label.setNeedsLayout()
        label.layoutIfNeeded()

        guard label.error == nil, let display = label.displayList else {
            TutorLog.shared.error("TutorWriter: failed to parse latex \"\(latex)\" (\(label.error?.localizedDescription ?? "no displayList"))")
            return nil
        }

        let totalAscent = display.ascent
        let totalDescent = display.descent
        let totalHeight = totalAscent + totalDescent
        guard totalHeight > 0, let topPosition = position(of: display) else {
            TutorLog.shared.error("TutorWriter: could not read SwiftMath display geometry for \"\(latex)\" — position API may have changed")
            return nil
        }

        var rawGlyphs: [(character: String, frame: CGRect)] = []
        walk(display, parentOrigin: .zero, into: &rawGlyphs)
        guard !rawGlyphs.isEmpty else {
            TutorLog.shared.error("TutorWriter: \"\(latex)\" parsed but produced no glyphs (unsupported construct?)")
            return nil
        }

        let scale = height / totalHeight
        let topYUp = topPosition.y + totalAscent // top of the whole equation, in SwiftMath's y-up space

        let placements = rawGlyphs.map { entry -> GlyphPlacement in
            let localX = entry.frame.minX - topPosition.x
            let localTopY = topYUp - (entry.frame.minY + entry.frame.height) // y-up -> y-down flip
            let pageFrame = CGRect(
                x: origin.x + localX * scale,
                y: origin.y + localTopY * scale,
                width: entry.frame.width * scale,
                height: entry.frame.height * scale
            )
            return GlyphPlacement(character: entry.character, glyphKey: normalizeGlyphKey(entry.character), frame: pageFrame)
        }

        let bounds = CGRect(x: origin.x, y: origin.y, width: display.width * scale, height: height)
        return (placements, bounds)
    }

    /// Maps a SwiftMath atom nucleus to the key `glyphStrokes` uses.
    /// SwiftMath renders single-letter variables as "Mathematical
    /// Alphanumeric Symbols" (italic styling baked into the codepoint, not a
    /// font attribute) and renders `-` as U+2212 MINUS SIGN rather than
    /// ASCII hyphen — both confirmed empirically against the 1.7.3 source.
    /// `glyphStrokes` only ever needs ASCII keys, so this folds exactly the
    /// codepoints this glyph library's alphabet can produce; anything else
    /// passes through unchanged (and will simply miss the `glyphStrokes`
    /// lookup, triggering the CATextLayer fallback).
    static func normalizeGlyphKey(_ nucleus: String) -> String {
        guard nucleus.unicodeScalars.count == 1, let scalar = nucleus.unicodeScalars.first else { return nucleus }
        switch scalar.value {
        case 0x1D465: return "x" // MATHEMATICAL ITALIC SMALL X
        case 0x1D466: return "y" // MATHEMATICAL ITALIC SMALL Y
        case 0x2212: return "-"  // MINUS SIGN -> ASCII hyphen (glyphStrokes key)
        default: return nucleus
        }
    }

    // MARK: - Stroke scaling (pure geometry — unit box -> target frame)

    /// Maps one unit-box point (`glyphStrokes`' normalization: larger
    /// dimension == 1.0, origin at the glyph's top-left, y-down) into
    /// `frame`. Non-uniform (independent x/y scale) — the typesetter's frame
    /// is the ground truth for where the glyph goes; per Task 11's spec,
    /// tiny frames (e.g. "." ) are trusted as-is rather than special-cased.
    static func scalePoint(_ unit: CGPoint, into frame: CGRect) -> CGPoint {
        CGPoint(x: frame.minX + unit.x * frame.width, y: frame.minY + unit.y * frame.height)
    }

    static func scaleStroke(_ unitStroke: [CGPoint], into frame: CGRect) -> [CGPoint] {
        unitStroke.map { scalePoint($0, into: frame) }
    }

    // MARK: - Duration from arc length

    /// Natural handwriting speed band the plan specifies (~300-600 pt/s);
    /// the point in the middle.
    static let defaultWritingSpeedPointsPerSecond: CGFloat = 450
    /// Floor so a near-zero-length stroke (a dot) still gets a perceptible
    /// draw-in instead of an instant snap.
    static let minimumStrokeDuration: TimeInterval = 0.06
    /// Tiny pause between strokes so pen-lifts read as real lifts.
    static let strokeGap: TimeInterval = 0.05
    /// Pause after a non-animated fallback glyph, so it still reads as
    /// "written" in sequence rather than all fallbacks flashing in at once.
    static let fallbackPause: TimeInterval = 0.15

    static func polylineLength(_ points: [CGPoint]) -> CGFloat {
        guard points.count > 1 else { return 0 }
        var length: CGFloat = 0
        for i in 1..<points.count {
            length += hypot(points[i].x - points[i - 1].x, points[i].y - points[i - 1].y)
        }
        return length
    }

    static func strokeDuration(forArcLength length: CGFloat, speed: CGFloat = defaultWritingSpeedPointsPerSecond) -> TimeInterval {
        max(minimumStrokeDuration, Double(length / speed))
    }

    /// A softly-smoothed path through `points` (quadratic curve to each
    /// consecutive midpoint, control point at the real sample) — the
    /// standard "smooth a polyline" trick, so resampled ink data reads as a
    /// pen stroke instead of a ruler-straight polygon.
    static func smoothedPath(through points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        guard points.count > 1 else {
            path.move(to: first)
            path.addLine(to: first)
            return path
        }
        path.move(to: first)
        if points.count == 2 {
            path.addLine(to: points[1])
            return path
        }
        for i in 1..<(points.count - 1) {
            let mid = CGPoint(x: (points[i].x + points[i + 1].x) / 2, y: (points[i].y + points[i + 1].y) / 2)
            path.addQuadCurve(to: mid, control: points[i])
        }
        path.addLine(to: points[points.count - 1])
        return path
    }

    // MARK: - SwiftMath display-tree walk (internal `position` via Mirror)

    /// Reads `MTDisplay.position` (internal in SwiftMath — see the type doc
    /// comment) via runtime reflection. Returns `nil` only if the property
    /// truly isn't found (API moved), not when it's legitimately `.zero`, so
    /// callers can distinguish "found and zero" from "SwiftMath changed
    /// out from under us."
    private static func position(of display: MTDisplay) -> CGPoint? {
        var mirror: Mirror? = Mirror(reflecting: display)
        while let current = mirror {
            for child in current.children where child.label == "position" {
                if let point = child.value as? CGPoint { return point }
            }
            mirror = current.superclassMirror
        }
        return nil
    }

    /// Recursively walks the display tree, accumulating each `MTDisplay`
    /// node's `position` (relative to its parent — SwiftMath's own
    /// convention, mirrored by `MTMathListDisplay.draw`'s
    /// `context.translateBy(position)` before drawing its subDisplays) into
    /// an absolute position, and decomposing every `MTCTLineDisplay` leaf
    /// into per-glyph frames.
    ///
    /// Only `MTMathListDisplay` (recurse) and `MTCTLineDisplay` (decompose)
    /// are handled — covers every symbol this glyph library and Task 11's
    /// required demo strings need (digits, `x`/`y`, `+ - = ( ) .`).
    /// `MTFractionDisplay`/`MTRadicalDisplay` (`\frac`, `\sqrt`) are logged
    /// and skipped rather than guessed at: their sub-displays use a
    /// different, non-relative position convention (numerator/denominator
    /// positions are pre-baked absolute-to-the-fraction's-parent, per
    /// `MTFractionDisplay`'s own doc comment), which would need separate,
    /// separately-verified handling this task's scope doesn't require.
    private static func walk(_ display: MTDisplay, parentOrigin: CGPoint, into result: inout [(character: String, frame: CGRect)]) {
        guard let localPosition = position(of: display) else { return }
        let absoluteOrigin = CGPoint(x: parentOrigin.x + localPosition.x, y: parentOrigin.y + localPosition.y)

        if let line = display as? MTCTLineDisplay {
            decompose(line, absoluteOrigin: absoluteOrigin, into: &result)
        } else if let list = display as? MTMathListDisplay {
            for sub in list.subDisplays {
                walk(sub, parentOrigin: absoluteOrigin, into: &result)
            }
        } else {
            TutorLog.shared.info("TutorWriter: unsupported display node \(type(of: display)) (range \(display.range)) — subexpression skipped (frac/sqrt not wired yet)")
        }
    }

    /// Per-glyph frames within one `MTCTLineDisplay`'s `CTLine`, the same
    /// technique `MTCTLineDisplay.computeDimensions` uses internally for the
    /// line's aggregate ascent/descent, applied per-glyph instead: for each
    /// `CTRun`, `CTRunGetGlyphs`/`CTRunGetPositions` give per-glyph position
    /// within the line, `CTFontGetBoundingRectsForGlyphs` gives the tight
    /// bounding box. Glyphs zip 1:1, in run order, against `line.atoms`
    /// (true for this glyph library's whole alphabet — see the type doc).
    private static func decompose(_ line: MTCTLineDisplay, absoluteOrigin: CGPoint, into result: inout [(character: String, frame: CGRect)]) {
        guard let ctLine = line.line, let runs = CTLineGetGlyphRuns(ctLine) as? [CTRun] else { return }

        var atomIndex = 0
        for run in runs {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }

            var glyphs = [CGGlyph](repeating: 0, count: count)
            CTRunGetGlyphs(run, CFRangeMake(0, count), &glyphs)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetPositions(run, CFRangeMake(0, count), &positions)

            let attributes = CTRunGetAttributes(run) as NSDictionary
            guard let ctFont = attributes[kCTFontAttributeName as String] else {
                atomIndex += count
                continue
            }
            var rects = [CGRect](repeating: .zero, count: count)
            // swiftlint-safe force cast: CTRunGetAttributes always carries the
            // font it was laid out with; this mirrors MTCTLineDisplay's own
            // computeDimensions() usage of the same attribute.
            CTFontGetBoundingRectsForGlyphs(ctFont as! CTFont, .horizontal, glyphs, &rects, count)

            for i in 0..<count {
                guard atomIndex < line.atoms.count else { break }
                let character = line.atoms[atomIndex].nucleus
                let rect = rects[i]
                let glyphOrigin = CGPoint(x: absoluteOrigin.x + positions[i].x, y: absoluteOrigin.y + positions[i].y)
                let frame = CGRect(
                    x: glyphOrigin.x + rect.origin.x,
                    y: glyphOrigin.y + rect.origin.y,
                    width: rect.width,
                    height: rect.height
                )
                result.append((character: character, frame: frame))
                atomIndex += 1
            }
        }
    }
}

// MARK: - TutorWriter

/// Hosts the tutor's handwriting animation as a transparent, non-interactive
/// overlay in page/canvas coordinates — same convention as
/// `AnnotationOverlayView` (Task 9): top-left-anchored layer, `setZoom`
/// scales/positions it to track the host `PKCanvasView`'s zoom/scroll
/// without ever putting an image-pixel coordinate into this file (Global
/// Constraint: "canvas space everywhere").
///
/// Scope note: the plan's Task 11 also calls for committing a real `PKStroke`
/// to `PageModel.drawing` once the animation finishes ("so the result is
/// genuine ink, selectable/snapshotable"). This file only produces the
/// animated `CAShapeLayer`/`CATextLayer` presentation `write(latex:at:height:)`
/// promises — PKStroke commit is a follow-up, not silently dropped: nothing
/// here writes to any `PageModel`.
@MainActor
final class TutorWriter: UIView {

    let pageSize: CGSize
    private var writtenContainers: [CALayer] = []

    /// Holds every glyph this writer has drawn, in pure page-point space
    /// with NO zoom/pan transform ever applied to it — `self.layer` (this
    /// view's own root layer) carries `setZoom`'s live transform for
    /// on-screen presentation, but a snapshot compositor (`SnapshotRenderer`,
    /// via `TutorCoordinator`'s `WrittenLayerProvider`) needs the
    /// untransformed content so it lines up, scale-for-scale, with the
    /// identity-space rendering `PKDrawing.image(from:scale:)` already
    /// produces for the page's real ink. A sibling sublayer of `self.layer`
    /// rather than `self.layer` itself, so it never inherits that
    /// transform. Not `private` so `TutorCoordinator`'s written-layer
    /// closure (wired at `CanvasScreen`) can read it.
    let contentLayer = CALayer()

    /// `pageView`'s current bounds become this overlay's page size (mirrors
    /// `AnnotationOverlayView`'s `init(pageSize:)`, inferred from the host
    /// instead of passed explicitly, per this task's requested signature).
    init(overlayOn pageView: UIView) {
        pageSize = pageView.bounds.size
        super.init(frame: CGRect(origin: .zero, size: pageSize))
        isUserInteractionEnabled = false
        backgroundColor = .clear
        layer.anchorPoint = .zero
        layer.position = .zero
        contentLayer.anchorPoint = .zero
        contentLayer.frame = CGRect(origin: .zero, size: pageSize)
        layer.addSublayer(contentLayer)
        pageView.addSubview(self)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Mirrors `AnnotationOverlayView.setZoom` exactly: top-left-anchored
    /// scale by `zoom`, positioned by `-contentOffset`, so every path this
    /// file animates stays in page points regardless of the canvas's zoom
    /// level.
    func setZoom(_ zoom: CGFloat, contentOffset: CGPoint) {
        layer.position = CGPoint(x: -contentOffset.x, y: -contentOffset.y)
        layer.transform = CATransform3DMakeScale(zoom, zoom, 1)
    }

    /// One `write(...)` call's result: the written bounding rect (so callers
    /// can anchor the next `[WRITE:...|below:last]` beneath it — the
    /// pre-existing contract) plus the per-glyph placements that produced
    /// it, in the same page/canvas space, so a caller (`TutorCoordinator`)
    /// can turn the tutor's own handwriting into addressable `Mark`s.
    struct WriteResult {
        let bounds: CGRect
        let placements: [TutorWriterLayout.GlyphPlacement]
    }

    /// Hand-writes `latex` starting at `origin` (page space, top-left),
    /// scaled so the whole equation is `height` points tall. Glyphs animate
    /// in reading order; within each glyph, strokes animate in
    /// `glyphStrokes`' authored order. Never throws/crashes on unparseable
    /// latex or missing glyphs — both degrade to a logged fallback (Task
    /// 11's stated contract).
    @discardableResult
    func write(latex: String, at origin: CGPoint, height: CGFloat) async -> WriteResult {
        guard let (placements, bounds) = TutorWriterLayout.layout(latex: latex, at: origin, height: height) else {
            // TutorWriterLayout.layout already logged the reason.
            return WriteResult(bounds: CGRect(origin: origin, size: .zero), placements: [])
        }

        let container = CALayer()
        contentLayer.addSublayer(container)
        writtenContainers.append(container)

        for placement in placements {
            if let strokes = glyphStrokes[placement.glyphKey] {
                for unitStroke in strokes {
                    await writeStroke(unitStroke, into: placement.frame, on: container)
                }
            } else {
                TutorLog.shared.info("TutorWriter: no glyphStrokes entry for \"\(placement.character)\" (key=\"\(placement.glyphKey)\") — using text fallback")
                writeFallback(character: placement.character, frame: placement.frame, on: container)
                try? await Task.sleep(nanoseconds: UInt64(TutorWriterLayout.fallbackPause * 1_000_000_000))
            }
        }

        return WriteResult(bounds: bounds, placements: placements)
    }

    /// Removes every layer any past `write` call added. Nothing is ever
    /// erased on either page's real ink (Global Constraint: "no erase tag
    /// exists anywhere") — this only clears the tutor's own transient
    /// handwriting presentation layers.
    func clear() {
        writtenContainers.forEach { $0.removeFromSuperlayer() }
        writtenContainers.removeAll()
    }

    // MARK: - Private

    private func writeStroke(_ unitStroke: [CGPoint], into frame: CGRect, on container: CALayer) async {
        let scaled = TutorWriterLayout.scaleStroke(unitStroke, into: frame)
        let path = TutorWriterLayout.smoothedPath(through: scaled)
        let length = TutorWriterLayout.polylineLength(scaled)
        let duration = TutorWriterLayout.strokeDuration(forArcLength: length)

        let shapeLayer = CAShapeLayer()
        shapeLayer.path = path
        shapeLayer.strokeColor = UIColor.black.cgColor
        shapeLayer.fillColor = UIColor.clear.cgColor
        shapeLayer.lineWidth = 3
        shapeLayer.lineCap = .round
        shapeLayer.lineJoin = .round
        shapeLayer.strokeEnd = 0
        container.addSublayer(shapeLayer)

        let animation = CABasicAnimation(keyPath: "strokeEnd")
        animation.fromValue = 0
        animation.toValue = 1
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        shapeLayer.strokeEnd = 1
        shapeLayer.add(animation, forKey: "write")

        try? await Task.sleep(nanoseconds: UInt64((duration + TutorWriterLayout.strokeGap) * 1_000_000_000))
    }

    /// Non-animated fallback for a glyph absent from `glyphStrokes` (letters
    /// we lack, etc.) — a rounded system font so it reads as "the tutor's
    /// handwriting" rather than a mismatched printed character, per Task
    /// 11's spec: log it (done by the caller) and never crash.
    private func writeFallback(character: String, frame: CGRect, on container: CALayer) {
        let textLayer = CATextLayer()
        textLayer.string = character
        textLayer.frame = frame
        let font = Self.fallbackFont(size: frame.height)
        // CATextLayer.font wants a CTFont/CGFont/PostScript-name CFTypeRef,
        // not a UIFont directly (no toll-free bridge) — the font's own
        // PostScript name is the documented, reliable way in.
        textLayer.font = font.fontName as CFTypeRef
        textLayer.fontSize = frame.height
        textLayer.foregroundColor = UIColor.black.cgColor
        textLayer.alignmentMode = .center
        textLayer.contentsScale = UIScreen.main.scale
        container.addSublayer(textLayer)
    }

    /// Rounded system font — reads as "a tutor's board hand" for the rare
    /// glyph `glyphStrokes` doesn't cover, per the five heuristics
    /// (Global Constraints: "everything drawn looks hand-drawn... but a
    /// tutor's board hand, professional, not a scrawl").
    private static func fallbackFont(size: CGFloat) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: .medium)
        let descriptor = base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor
        return UIFont(descriptor: descriptor, size: size)
    }
}

// MARK: - Debug harness

#if DEBUG
/// Wraps `TutorWriter` for Xcode's canvas so a human can watch it write —
/// Task 11 Step 5's actual pass condition. Writes `x^2+8x+12=0`, then
/// `(x+2)(x+6)=0` anchored below the first line's returned bounds (the same
/// `below:last` pattern `TutorTag.write`'s anchor resolution will use).
private struct TutorWriterPreview: UIViewRepresentable {
    static let pageSize = CGSize(width: 768, height: 1024)

    func makeUIView(context: Context) -> UIView {
        let container = UIView(frame: CGRect(origin: .zero, size: Self.pageSize))
        container.backgroundColor = .white

        let writer = TutorWriter(overlayOn: container)
        writer.setZoom(1, contentOffset: .zero)

        Task { @MainActor in
            let first = await writer.write(latex: "x^2+8x+12=0", at: CGPoint(x: 60, y: 140), height: 56)
            _ = await writer.write(latex: "(x+2)(x+6)=0", at: CGPoint(x: 60, y: first.bounds.maxY + 56), height: 56)
        }

        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

#Preview("Tutor handwriting") {
    TutorWriterPreview()
        .frame(width: TutorWriterPreview.pageSize.width, height: TutorWriterPreview.pageSize.height)
}
#endif
