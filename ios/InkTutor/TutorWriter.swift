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
///   U+1D465 MATHEMATICAL ITALIC SMALL X, `\pi` → U+1D70B MATHEMATICAL
///   ITALIC SMALL PI), and `-` renders as U+2212 MINUS SIGN, not ASCII
///   hyphen — confirmed empirically parsing `"5-3=2"`. `normalizeGlyphKey`
///   folds all three (Latin italic, Greek italic, minus sign) back to the
///   keys `glyphStrokes` uses.
/// - `\frac{a}{b}` typesets as `MTFractionDisplay` (public, :292) whose
///   `numerator`/`denominator` sub-display *positions* are already relative
///   to the fraction's own origin (not double-relative like a normal
///   parent/child pair) — confirmed against `MTFractionDisplay.draw`, which
///   draws them without an extra `translateBy`. `\sqrt{a}` typesets as
///   `MTRadicalDisplay` (internal, :387 — the type itself isn't
///   `public`, so it's matched by name via `String(describing:)` rather
///   than `as?`) with the same convention for its `radicand`. `walk` below
///   handles both, plus `MTGlyphDisplay` (internal, :505 — a single
///   pre-rendered glyph, e.g. `\int`) — see `walk`'s own doc comment for
///   the per-case geometry derivation.
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
    /// `glyphStrokes` only ever needs ASCII keys, so this folds every
    /// codepoint this glyph library's alphabet can produce.
    ///
    /// Folds the *whole* Mathematical Italic block (U+1D434-U+1D44D
    /// uppercase, U+1D44E-U+1D467 lowercase, `x`/`y` included), not just the
    /// two letters `glyphStrokes` currently has strokes for: `glyphStrokes`
    /// is a growing dictionary (glyphs-v2 lands more hand-authored letters
    /// later), and an unfolded key would (a) silently miss a future
    /// `glyphStrokes["z"]` entry even after it exists, and (b) feed the
    /// *styled* codepoint to the CATextLayer fallback, which only a
    /// specialized math font renders — defeating the fallback's own
    /// handwriting-adjacent font choice (see `writeFallback`). Unicode
    /// carves italic lowercase "h" out of this block (it collides with the
    /// legacy PLANCK CONSTANT codepoint) — handled as an explicit case.
    ///
    /// Also folds the italic lowercase Greek block (U+1D6FC-1D714, `\pi` /
    /// `\theta` / etc.) back to plain Greek (U+03B1-03C9): both blocks list
    /// the 24 letters in the same order, *including* the same "final sigma"
    /// insertion point between rho and sigma (U+1D70D / U+03C2), so a single
    /// linear offset is correct for the whole block, not just π/θ — verified
    /// letter-by-letter against the Unicode Mathematical Alphanumeric
    /// Symbols block chart, not guessed. Greek letters `glyphStrokes` has no
    /// stroke data for still fall through to the CATextLayer fallback, but
    /// now with the right (non-italic-styled) codepoint, so that fallback
    /// renders the actual letter instead of tofu/silent substitution.
    ///
    /// Anything outside these two blocks passes through unchanged (digits
    /// and ASCII operators already typeset as plain ASCII — confirmed
    /// empirically) and will simply miss the `glyphStrokes` lookup,
    /// triggering the fallback.
    static func normalizeGlyphKey(_ nucleus: String) -> String {
        guard nucleus.unicodeScalars.count == 1, let scalar = nucleus.unicodeScalars.first else { return nucleus }
        switch scalar.value {
        case 0x210E: return "h" // PLANCK CONSTANT, standing in for italic lowercase h
        case 0x1D434...0x1D44D: // MATHEMATICAL ITALIC CAPITAL A...Z
            let offset = scalar.value - 0x1D434
            return String(UnicodeScalar(UInt8(0x41 + offset)))
        case 0x1D44E...0x1D467: // MATHEMATICAL ITALIC SMALL A...Z
            let offset = scalar.value - 0x1D44E
            return String(UnicodeScalar(UInt8(0x61 + offset)))
        case 0x1D6FC...0x1D714: // MATHEMATICAL ITALIC SMALL ALPHA...OMEGA
            let offset = scalar.value - 0x1D6FC
            guard let plain = UnicodeScalar(0x3B1 + offset) else { return nucleus }
            return String(Character(plain))
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

    /// Reads a stored property named `label` off `object` via runtime
    /// reflection, walking up the superclass chain (`Mirror.children` only
    /// exposes a type's *own* declared properties — inherited ones surface
    /// one level up via `.superclassMirror`). This is how this file reaches
    /// every SwiftMath field that's `internal` (not `public`) or whose
    /// *type* is internal and therefore can't be named directly in this
    /// module (`MTRadicalDisplay`, `MTGlyphDisplay` — see `walk` below):
    /// `Mirror` walks runtime metadata, unconstrained by compile-time access
    /// control or type visibility, and `T` only needs to be a type this file
    /// already can name (`CGFloat`, `CGPoint`, `MTMathListDisplay`, `MTFont`
    /// — all `public`), not the declaring type. Verified empirically against
    /// a throwaway SPM executable linked against the same 1.7.3 checkout
    /// before writing this file.
    private static func mirrorChild<T>(of object: Any, label: String, as type: T.Type) -> T? {
        var mirror: Mirror? = Mirror(reflecting: object)
        while let current = mirror {
            for child in current.children where child.label == label {
                if let value = child.value as? T { return value }
            }
            mirror = current.superclassMirror
        }
        return nil
    }

    /// `MTDisplay.position` is `internal`, not `public`
    /// (MTMathListDisplay.swift:92) — a real gap in the library's access
    /// control, not an oversight in this file. `nil` only when the property
    /// truly isn't found (API moved), not when it's legitimately `.zero`, so
    /// callers can distinguish "found and zero" from "SwiftMath changed
    /// out from under us."
    private static func position(of display: MTDisplay) -> CGPoint? {
        mirrorChild(of: display, label: "position", as: CGPoint.self)
    }

    /// Recursively walks the display tree, accumulating each `MTDisplay`
    /// node's `position` (relative to its parent — SwiftMath's own
    /// convention, mirrored by `MTMathListDisplay.draw`'s
    /// `context.translateBy(position)` before drawing its subDisplays) into
    /// an absolute position, and decomposing every leaf into per-glyph
    /// frames (real glyph frames for `MTCTLineDisplay`/`MTGlyphDisplay`,
    /// synthetic `"fracbar"`/`"√"` frames sized from SwiftMath's own layout
    /// math for `MTFractionDisplay`/`MTRadicalDisplay`).
    ///
    /// Five node kinds, all confirmed against the 1.7.3 source
    /// (`MTMathListDisplay.swift`), not guessed:
    ///
    /// - `MTMathListDisplay` (public, :218) — recurse into `subDisplays`.
    /// - `MTCTLineDisplay` (public, :116) — `decompose` into per-glyph
    ///   CoreText frames (digits, letters, `+ - = ( ) .`).
    /// - `MTFractionDisplay` (public, :292) — `numerator`/`denominator` are
    ///   public-gettable `MTMathListDisplay?`, but their own `position` is
    ///   *already* relative to the fraction's own origin (verified against
    ///   `MTFractionDisplay.draw`, which never re-translates before drawing
    ///   them) — so both recurse with the ORIGINAL `parentOrigin`, not
    ///   `absoluteOrigin`, or the fraction's own position would be double-
    ///   counted. The bar itself has no display node of its own; its
    ///   position/thickness are internal fields (`linePosition`,
    ///   `lineThickness`, read via `mirrorChild`) that `MTFractionDisplay
    ///   .draw` uses to stroke a line directly — mirrored here as a
    ///   synthetic `"fracbar"` glyph entry (reusing the existing
    ///   `glyphStrokes["fracbar"]` horizontal-line stroke) spanning the
    ///   fraction's full `width` at `linePosition`.
    /// - `MTRadicalDisplay` (internal, :387 — type name unreferenceable
    ///   outside the module, matched by `String(describing: type(of:))`
    ///   instead) — same non-relative-position convention as the fraction's
    ///   numerator/denominator: `radicand` (public-gettable, internal type
    ///   `MTMathListDisplay` so declared as that instead) recurses with the
    ///   original `parentOrigin`. The √ tick and its overbar are
    ///   reconstructed from `MTRadicalDisplay.draw` (:487-497) and
    ///   `MTTypesetter.makeRadical` (:1108-1140), which establish:
    ///   `radical.width == radicalGlyphWidth + radicand.width` (so the
    ///   glyph's own width is recoverable as `display.width -
    ///   radicand.width` without touching the private `_radicalGlyph`), the
    ///   overbar sits at `y = ascent - topKern - lineThickness/2` above the
    ///   radicand's own left edge spanning `radicand.width`, and the tick
    ///   occupies the width-difference strip immediately to its left,
    ///   vertically spanning from the overbar down to the node's `descent`
    ///   (the checkmark's tail). Both emitted as synthetic entries —
    ///   `"fracbar"` again for the overbar, `"√"` for the tick (reusing
    ///   `glyphStrokes["√"]`, a checkmark-shaped stroke authored to compose
    ///   with a separately-drawn extending bar rather than stretch itself,
    ///   exactly this layout). Geometry validated numerically (not just
    ///   read off the source) against a throwaway SPM executable linked to
    ///   this same 1.7.3 checkout before landing here.
    /// - `MTGlyphDisplay` (internal, :505 — same string-match technique) —
    ///   a single pre-rendered glyph (e.g. `\int`), not a `CTLine`.
    ///   `MTGlyphDisplay.draw` (:519-533) translates by `(position.x,
    ///   position.y - shiftDown)` then draws `glyph` at the CoreText origin
    ///   via `CTFontDrawGlyphs` — so its tight frame is recovered the same
    ///   way `decompose` recovers a `CTLineDisplay` run's per-glyph frame:
    ///   `CTFontGetBoundingRectsForGlyphs` on that one glyph/font (both read
    ///   via `mirrorChild`, `font: MTFont` itself public though its
    ///   `ctFont: CTFont` is internal), offset by `(position.x, position.y -
    ///   shiftDown)`. The atom's own nucleus isn't available on this node
    ///   (no `atoms` array, unlike `MTCTLineDisplay`), so the emitted
    ///   character is the literal glyph this file's demo battery needs —
    ///   `"∫"` — matching `glyphStrokes["∫"]`.
    private static func walk(_ display: MTDisplay, parentOrigin: CGPoint, into result: inout [(character: String, frame: CGRect)]) {
        guard let localPosition = position(of: display) else { return }
        let absoluteOrigin = CGPoint(x: parentOrigin.x + localPosition.x, y: parentOrigin.y + localPosition.y)
        let typeName = String(describing: type(of: display))

        if let line = display as? MTCTLineDisplay {
            decompose(line, absoluteOrigin: absoluteOrigin, into: &result)
        } else if let list = display as? MTMathListDisplay {
            for sub in list.subDisplays {
                walk(sub, parentOrigin: absoluteOrigin, into: &result)
            }
        } else if let fraction = display as? MTFractionDisplay {
            // Emission order is numerator, bar, denominator — not just a
            // list order, but the writing order a human pen would use (this
            // is what CAShapeLayer strokeEnd animation reveals over time):
            // write the numerator, draw the bar under it, then write the
            // denominator. Confirmed against `MTFractionDisplay.draw`
            // (MTMathListDisplay.swift:360-380): the bar's geometry
            // (`self.position` + `linePosition`/`lineThickness`) is
            // independent of numerator/denominator draw order there, so
            // reordering the synthetic "fracbar" append here to sit between
            // the two recursive `walk` calls only changes writing order,
            // not geometry.
            if let numerator = fraction.numerator {
                walk(numerator, parentOrigin: parentOrigin, into: &result)
            }
            let linePosition = mirrorChild(of: fraction, label: "linePosition", as: CGFloat.self) ?? 0
            let lineThickness = mirrorChild(of: fraction, label: "lineThickness", as: CGFloat.self) ?? 0
            let barY = absoluteOrigin.y + linePosition
            result.append((character: "fracbar", frame: CGRect(
                x: absoluteOrigin.x, y: barY - lineThickness / 2,
                width: fraction.width, height: lineThickness
            )))
            if let denominator = fraction.denominator {
                walk(denominator, parentOrigin: parentOrigin, into: &result)
            }
        } else if typeName == "MTRadicalDisplay" {
            guard let radicand = mirrorChild(of: display, label: "radicand", as: MTMathListDisplay.self),
                  let radicandPosition = position(of: radicand) else { return }
            walk(radicand, parentOrigin: parentOrigin, into: &result)

            let topKern = mirrorChild(of: display, label: "topKern", as: CGFloat.self) ?? 0
            let lineThickness = mirrorChild(of: display, label: "lineThickness", as: CGFloat.self) ?? 0
            let radicandAbsoluteX = parentOrigin.x + radicandPosition.x

            let barY = absoluteOrigin.y + (display.ascent - topKern - lineThickness / 2)
            result.append((character: "fracbar", frame: CGRect(
                x: radicandAbsoluteX, y: barY - lineThickness / 2,
                width: radicand.width, height: lineThickness
            )))

            let glyphWidth = display.width - radicand.width
            let tickTop = barY
            let tickBottom = absoluteOrigin.y - display.descent
            result.append((character: "√", frame: CGRect(
                x: radicandAbsoluteX - glyphWidth, y: min(tickTop, tickBottom),
                width: glyphWidth, height: abs(tickTop - tickBottom)
            )))
        } else if typeName == "MTGlyphDisplay" {
            guard let glyph = mirrorChild(of: display, label: "glyph", as: CGGlyph.self),
                  let font = mirrorChild(of: display, label: "font", as: MTFont.self),
                  let ctFont = mirrorChild(of: font, label: "ctFont", as: CTFont.self) else { return }
            let shiftDown = mirrorChild(of: display, label: "shiftDown", as: CGFloat.self) ?? 0

            var mutableGlyph = glyph
            var rect = CGRect.zero
            CTFontGetBoundingRectsForGlyphs(ctFont, .horizontal, &mutableGlyph, &rect, 1)

            let drawOrigin = CGPoint(x: absoluteOrigin.x, y: absoluteOrigin.y - shiftDown)
            let frame = CGRect(
                x: drawOrigin.x + rect.origin.x, y: drawOrigin.y + rect.origin.y,
                width: rect.width, height: rect.height
            )
            result.append((character: "∫", frame: frame))
        } else {
            TutorLog.shared.info("TutorWriter: unsupported display node \(typeName) (range \(display.range)) — subexpression skipped")
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

    /// Feature flag: `false` (default) renders every glyph via the
    /// handwriting-font text path (`writeFallback`, despite the name — see
    /// its doc comment). `true` restores the original `glyphStrokes`
    /// hand-traced `CAShapeLayer` path for every glyph that has authored
    /// strokes (Hugh, 2026-07-12: "the tutor's handwriting looks terrible" —
    /// the stroke glyphs read as a shaky, disconnected scrawl next to real
    /// pen ink; a real handwriting font reads as, well, handwriting). Kept
    /// as a one-line revert, not deleted: `glyphStrokes` stays the ground
    /// truth for the two structural constructs (`"fracbar"`, `"√"`, see
    /// `write` below) either way, and nothing about `TutorWriterLayout`
    /// changed — only which visual each placement gets.
    static let useStrokeGlyphs = true  // Hugh 2026-07-13: strokes ARE the handwriting; font mode kept for fallback

    /// Hand-writes `latex` starting at `origin` (page space, top-left),
    /// scaled so the whole equation is `height` points tall. Glyphs animate
    /// in reading order. Never throws/crashes on unparseable latex or
    /// missing glyphs — both degrade to a logged fallback (Task 11's stated
    /// contract).
    ///
    /// `"fracbar"` (the fraction bar / radical overbar) and `"√"` (the
    /// radical tick) are synthetic entries `TutorWriterLayout.walk`
    /// invents from pure geometry (a straight line; a checkmark-shaped tick
    /// meant to compose with a separately-drawn overbar) — they were never
    /// "a character a font renders," in either mode, so they always draw
    /// via the original `glyphStrokes`-traced `CAShapeLayer` path
    /// regardless of `useStrokeGlyphs`. Rendering `"√"` as an actual font
    /// glyph inside its (deliberately tick-only-width) frame would draw a
    /// whole radical symbol squashed into a sliver and double up with the
    /// separately-drawn overbar — confirmed by eye against the `08_sqrt`
    /// battery render before landing this.
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
            let hasStrokes = glyphStrokes[placement.glyphKey] != nil
            let isStructural = placement.glyphKey == "fracbar" || placement.glyphKey == "√"

            if hasStrokes, Self.useStrokeGlyphs || isStructural {
                for unitStroke in glyphStrokes[placement.glyphKey] ?? [] {
                    await writeStroke(unitStroke, into: placement.frame, on: container)
                }
            } else {
                if !hasStrokes {
                    TutorLog.shared.info("TutorWriter: no glyphStrokes entry for \"\(placement.character)\" (key=\"\(placement.glyphKey)\") — using text fallback")
                }
                writeFallback(character: placement.glyphKey, frame: placement.frame, on: container)
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
        shapeLayer.strokeColor = UIColor.systemBlue.cgColor
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

    /// Despite the name (kept for call-site/log continuity — this was
    /// originally the unknown-glyph fallback, Task 11), this is now the
    /// **default per-glyph render path** whenever `useStrokeGlyphs == false`
    /// (every glyph but the structural `"fracbar"`/`"√"` entries — see
    /// `write` above): a `CATextLayer` set in `handwritingFont`, the font
    /// chosen by eye (2026-07-12 scope cut) to replace the stroke-glyph
    /// rendering that "looks terrible." Falls back to `systemFallbackFont`
    /// per-glyph when the handwriting font's cmap lacks that character
    /// (math symbols like `√`/`∫` or Greek letters most handwriting fonts
    /// don't ship) — verified via `fontHasGlyphs`, not assumed.
    ///
    /// Takes the caller's already-`normalizeGlyphKey`-folded string, NOT the
    /// raw `GlyphPlacement.character` — SwiftMath's raw nucleus for a
    /// variable is a *styled* Mathematical Alphanumeric Symbols codepoint
    /// (e.g. italic z), which neither the handwriting font nor the system
    /// rounded fallback has a glyph for; CoreText silently substitutes a
    /// serif math font instead, so the fallback visibly clashed with the
    /// hand-drawn strokes around it (the actual bug behind "it writes stuff
    /// weirdly" for `z`/`w` in the demo battery). The folded key is plain
    /// ASCII/Greek, which both fonts *do* have.
    ///
    /// Two touches so a run of font-rendered glyphs doesn't read as a rigid
    /// printed row: a small random rotation (±2°, unchanged from the old
    /// fallback) plus a slight vertical baseline wobble (±1.5pt) — real
    /// handwriting never sits perfectly on one ruled line. Reveals with a
    /// left-to-right fade/scale-in (strokeEnd tracing doesn't apply to a
    /// whole font glyph) timed off `TutorWriterLayout.minimumStrokeDuration`
    /// so it finishes comfortably inside the `fallbackPause` gap the caller
    /// already awaits between glyphs.
    private func writeFallback(character: String, frame: CGRect, on container: CALayer) {
        let baselineWobble = CGFloat.random(in: -1.5...1.5)
        var wobbledFrame = frame.offsetBy(dx: 0, dy: baselineWobble)

        // SwiftMath gives punctuation like "." a near-zero-height frame
        // (a period's own ink is tiny in any real font's metrics too) —
        // rendered at that literal height in a text layer, it's essentially
        // invisible (confirmed by eye: "x=3.5"'s decimal point vanished
        // against the width-3 pen ink at both Chalkboard weights). Floor
        // the render size so a period still reads as a mark, growing the
        // frame symmetrically around its own center so its position doesn't
        // shift — every other glyph's frame is already well above this
        // floor, so this is a no-op for them.
        let minimumRenderDimension: CGFloat = 12
        if wobbledFrame.height < minimumRenderDimension {
            wobbledFrame = wobbledFrame.insetBy(dx: -(minimumRenderDimension - wobbledFrame.height) / 2, dy: -(minimumRenderDimension - wobbledFrame.height) / 2)
        }

        let textLayer = CATextLayer()
        textLayer.string = character
        // Two sizing bugs fixed by eye (2026-07-13):
        // 1. CATextLayer hard-clips to bounds, and a glyph at point size N
        //    needs its full line box (~1.35×N) — sizing the layer to the
        //    tight SwiftMath frame cut the bottom off every glyph.
        // 2. fontSize = frame.height double-shrinks: SwiftMath's frame for
        //    "x" is already x-height-sized, and the font then renders "x"
        //    at HALF that again ("x"/"=" microscopic next to digits). The
        //    fix: measure the font's actual INK box for this character and
        //    pick the point size whose ink height fills the frame, then
        //    place the baseline so the ink lands exactly in the frame.
        let (fontSize, inkTopAboveBaseline) = Self.inkFittedFontSize(
            for: character, targetInkHeight: wobbledFrame.height)
        let font = Self.textFont(for: character, size: fontSize)
        let lineHeight = font.ascender - font.descender
        let baselineY = wobbledFrame.minY + inkTopAboveBaseline
        textLayer.frame = CGRect(
            x: wobbledFrame.midX - max(wobbledFrame.width, fontSize),
            y: baselineY - font.ascender,
            width: max(wobbledFrame.width, fontSize) * 2,
            height: lineHeight
        )
        // CATextLayer.font wants a CTFont/CGFont/PostScript-name CFTypeRef,
        // not a UIFont directly (no toll-free bridge) — the font's own
        // PostScript name is the documented, reliable way in.
        textLayer.font = font.fontName as CFTypeRef
        textLayer.fontSize = fontSize
        textLayer.foregroundColor = UIColor.systemBlue.cgColor
        textLayer.alignmentMode = .center
        textLayer.contentsScale = UIScreen.main.scale

        let jitterDegrees = CGFloat.random(in: -2...2)
        let restTransform = CATransform3DMakeRotation(jitterDegrees * .pi / 180, 0, 0, 1)
        let startTransform = CATransform3DScale(restTransform, 0.6, 0.6, 1)
        // Model values are the RESTING state (opacity 1, no extra scale) —
        // `CALayer.render(in:)` (the visual harness's PNG capture) draws
        // model values, not mid-animation presentation values, so a
        // snapshot taken any time after this call still shows the glyph
        // fully written in, exactly like the strokeEnd=1 pattern
        // `writeStroke` already relies on below.
        textLayer.transform = restTransform
        textLayer.opacity = 1
        container.addSublayer(textLayer)

        let revealDuration = TutorWriterLayout.minimumStrokeDuration
        let scaleAnimation = CABasicAnimation(keyPath: "transform")
        scaleAnimation.fromValue = startTransform
        scaleAnimation.toValue = restTransform
        let fadeAnimation = CABasicAnimation(keyPath: "opacity")
        fadeAnimation.fromValue = 0
        fadeAnimation.toValue = 1

        let reveal = CAAnimationGroup()
        reveal.animations = [scaleAnimation, fadeAnimation]
        reveal.duration = revealDuration
        reveal.timingFunction = CAMediaTimingFunction(name: .easeOut)
        textLayer.add(reveal, forKey: "reveal")
    }

    /// The handwriting font every glyph renders in by default (`Self.
    /// useStrokeGlyphs == false`) — chosen by eye against the visual
    /// harness's battery (2026-07-12 scope cut skipped the planned 4-font
    /// audition; Hugh's follow-up refinement asked for "normal handwriting,
    /// not chalky/comic/quirky," compared against Bradley Hand). `nil` (not
    /// a crash) if this exact PostScript name ever stops shipping — callers
    /// (`textFont`) always have `systemFallbackFont` underneath.
    private static let handwritingFontName = "ChalkboardSE-Bold"

    private static func handwritingFont(size: CGFloat) -> UIFont? {
        UIFont(name: handwritingFontName, size: size)
    }

    /// Ink-box measurement cache: character -> (inkHeight, inkMaxY) in
    /// font units per 1pt of point size, measured once at a reference size.
    private static var inkMetricsCache: [String: (height: CGFloat, maxY: CGFloat)] = [:]

    /// The point size at which `character`'s actual drawn ink is
    /// `targetInkHeight` tall, plus where that ink's top sits above the
    /// baseline at that size — so callers can pin the ink into a target
    /// frame exactly. Falls back to (target, target) when the glyph can't
    /// be measured (renders roughly frame-sized, never invisible).
    static func inkFittedFontSize(
        for character: String, targetInkHeight: CGFloat
    ) -> (size: CGFloat, inkTopAboveBaseline: CGFloat) {
        let metrics: (height: CGFloat, maxY: CGFloat)
        if let cached = inkMetricsCache[character] {
            metrics = cached
        } else {
            let ref: CGFloat = 100
            let ctFont = textFont(for: character, size: ref) as CTFont
            var chars = Array(character.utf16)
            var glyphs = [CGGlyph](repeating: 0, count: chars.count)
            let mapped = CTFontGetGlyphsForCharacters(ctFont, &chars, &glyphs, chars.count)
            guard mapped, let g = glyphs.first, g != 0 else {
                return (targetInkHeight, targetInkHeight)
            }
            var glyph = g
            let rect = CTFontGetBoundingRectsForGlyphs(ctFont, .default, &glyph, nil, 1)
            guard rect.height > 0.5 else { return (targetInkHeight, targetInkHeight) }
            metrics = (rect.height / ref, rect.maxY / ref)
            inkMetricsCache[character] = metrics
        }
        let size = targetInkHeight / metrics.height
        return (size, metrics.maxY * size)
    }

    /// Whether `font`'s cmap actually has a glyph for every unicode scalar
    /// in `character` — checked via `CTFontGetGlyphsForCharacters` rather
    /// than assumed, since a missing glyph silently renders as tofu/a
    /// substituted font instead of throwing (the same class of bug
    /// `writeFallback`'s doc comment already called out for the raw
    /// Mathematical Alphanumeric codepoints).
    private static func fontHasGlyphs(for character: String, font: UIFont) -> Bool {
        let utf16 = Array(character.utf16)
        guard !utf16.isEmpty else { return false }
        var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
        let resolved = CTFontGetGlyphsForCharacters(font as CTFont, utf16, &glyphs, utf16.count)
        return resolved && glyphs.allSatisfy { $0 != 0 }
    }

    /// Picks `handwritingFont` when it can actually render `character`,
    /// else `systemFallbackFont` at the same size — the per-glyph fallback
    /// Task 11's font-mode spec calls for (math symbols/Greek letters most
    /// handwriting fonts don't ship, e.g. `√`/`∫`/uncovered Greek letters
    /// after `normalizeGlyphKey`'s fold).
    private static func textFont(for character: String, size: CGFloat) -> UIFont {
        if let handwriting = handwritingFont(size: size), fontHasGlyphs(for: character, font: handwriting) {
            return handwriting
        }
        return systemFallbackFont(size: size)
    }

    /// Rounded system font — reads as "a tutor's board hand" for any glyph
    /// `handwritingFont` can't render, per the five heuristics (Global
    /// Constraints: "everything drawn looks hand-drawn... but a tutor's
    /// board hand, professional, not a scrawl"). Also the whole-suite
    /// fallback if `handwritingFontName` itself ever fails to resolve.
    private static func systemFallbackFont(size: CGFloat) -> UIFont {
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
