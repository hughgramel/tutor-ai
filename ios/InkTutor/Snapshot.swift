import UIKit
import PencilKit

/// A rendered JPEG of a page plus the transform back into canvas (page-point)
/// space. All geometry the app reasons about (marks, annotations, glyph
/// placements) lives in canvas space — a `Snapshot` is the only place image
/// pixels exist, and it carries the math to get back out.
struct Snapshot {
    let jpeg: Data
    /// The canvas-space rect this snapshot covers.
    let canvasRect: CGRect
    /// image points per canvas point.
    let scale: CGFloat

    /// canvas point -> image (pixel) point.
    func toImage(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - canvasRect.minX) * scale, y: (p.y - canvasRect.minY) * scale)
    }

    /// image (pixel) point -> canvas point. Exact inverse of `toImage`.
    func toCanvas(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x / scale + canvasRect.minX, y: p.y / scale + canvasRect.minY)
    }
}

enum SnapshotRenderer {
    /// Max long-side dimension for a snapshot JPEG (Clicky's number).
    static let maxDimension: CGFloat = 1280
    static let jpegQuality: CGFloat = 0.8

    /// Renders a page (white paper, optional PDF underlay, then ink, then
    /// optionally `writerLayer`) into a Snapshot. On-demand only — never
    /// call this in a loop (Task 7 debounces).
    ///
    /// `writerLayer` composites the tutor's own handwriting: `TutorWriter`
    /// renders its glyphs as `CAShapeLayer`s that never enter any
    /// `PKDrawing`, so `page.drawing.image(from:scale:)` below can't see
    /// them — the caller (`TutorCoordinator`, tutor page only) hands in
    /// `TutorWriter.contentLayer` (already untransformed page-point space —
    /// see that property's doc comment) so it can be scaled and rendered in
    /// here the same way the ink image is. `nil` for the student page,
    /// which has no `TutorWriter`.
    static func render(page: PageModel, pageSize: CGSize, writerLayer: CALayer? = nil) -> Snapshot {
        let canvasRect = CGRect(origin: .zero, size: pageSize)
        let scale = maxDimension / max(pageSize.width, pageSize.height)
        let imageSize = CGSize(width: pageSize.width * scale, height: pageSize.height * scale)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1 // scale is already baked into imageSize; avoid double-scaling by screen scale
        let renderer = UIGraphicsImageRenderer(size: imageSize, format: format)

        let image = renderer.image { ctx in
            // Force light appearance so a device in dark mode still renders white paper.
            let traits = UITraitCollection(userInterfaceStyle: .light)
            traits.performAsCurrent {
                UIColor.white.setFill()
                ctx.fill(CGRect(origin: .zero, size: imageSize))

                if let pdfImage = page.pdfImage {
                    pdfImage.draw(in: CGRect(origin: .zero, size: imageSize))
                }

                let drawingImage = page.drawing.image(from: canvasRect, scale: scale)
                drawingImage.draw(in: CGRect(origin: .zero, size: imageSize))

                if let writerLayer {
                    // `CALayer.render(in:)` renders the MODEL layer tree
                    // (not any in-flight `CABasicAnimation` presentation
                    // state) — fine here because every caller only reaches
                    // this after a `TutorWriter.write` call has fully
                    // `await`ed, so its strokes' model `strokeEnd` is
                    // already 1. `UIGraphicsImageRenderer`'s context is
                    // already flipped to UIKit's top-left/y-down convention
                    // (the standard "snapshot a CALayer to a UIImage"
                    // recipe), so only the scale needs to be applied here,
                    // not a manual flip.
                    let cgContext = ctx.cgContext
                    cgContext.saveGState()
                    cgContext.scaleBy(x: scale, y: scale)
                    writerLayer.render(in: cgContext)
                    cgContext.restoreGState()
                }

                // Mark-ID labels burned in here in Task 5 (MarkRegistry.burnLabels).
            }
        }

        let jpeg = image.jpegData(compressionQuality: jpegQuality) ?? Data()
        return Snapshot(jpeg: jpeg, canvasRect: canvasRect, scale: scale)
    }
}
