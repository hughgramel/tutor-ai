import PencilKit
import UIKit

/// A "mark" is a chunk of the student's (or tutor's) ink the model can refer
/// to by a stable integer ID instead of guessing pixel coordinates
/// (Global Constraint: "the model never emits coordinates for existing
/// content — mark IDs only"). Geometry here is entirely in canvas space
/// (page points); only `burnLabels` crosses into image space, via the
/// `Snapshot` transform.
struct Mark: Equatable {
    let id: Int
    let bbox: CGRect
    let line: Int
    let strokeIndices: [Int]
}

/// Deterministically clusters a `PKDrawing`'s strokes into marks, and marks
/// into lines. No direct analog in `reference/clicky/` — Clicky grounds
/// coordinates by asking a vision model (`ElementLocationDetector.swift`);
/// InkTutor grounds them from stroke geometry so the model never has to
/// guess a pixel.
enum MarkRegistry {
    /// A stroke joins the current (temporally last) group if its
    /// render bounds, inflated by this much, intersect the group's bbox.
    static let groupInflate: CGFloat = 12
    /// Or if the horizontal gap from the group's right edge is under this,
    /// AND the stroke's vertical extent still overlaps the group's (see
    /// note in `compute` — the plan's literal "gap < 24pt" rule, read as a
    /// pure x-distance with no y check, would wrongly stitch together the
    /// first stroke of a new line with the last stroke of the line above
    /// it whenever the new line starts further left than the old line
    /// ended, which is the common case. The y-overlap guard is the fix.)
    static let groupGap: CGFloat = 24
    /// Y-cluster threshold for grouping marks into lines is
    /// 0.6 * median mark height (computed per call, not a constant).
    static let lineThresholdFactor: CGFloat = 0.6

    /// Computes marks for `drawing`, preserving IDs from `previous` for any
    /// mark whose bbox still overlaps its old position (stable IDs across
    /// recomputes so a mid-sentence `[CIRCLE:7]` still points at the right
    /// ink after the student adds a stroke elsewhere). Unmatched marks get
    /// fresh IDs from a counter seeded above the highest previous ID.
    static func compute(drawing: PKDrawing, previous: [Mark] = []) -> [Mark] {
        let strokes = drawing.strokes
        guard !strokes.isEmpty else { return [] }

        // Sort temporally (by stroke creation time), but remember each
        // stroke's original index into `drawing.strokes` — that's the index
        // space `strokeIndices` is reported in.
        let temporal = strokes.enumerated().sorted {
            $0.element.path.creationDate < $1.element.path.creationDate
        }

        // --- Step 1: group strokes into marks (word-ish chunks) ---
        var groupIndices: [[Int]] = []
        var groupBBoxes: [CGRect] = []

        for (originalIndex, stroke) in temporal {
            let bounds = stroke.renderBounds
            if let currentBBox = groupBBoxes.last {
                let inflated = bounds.insetBy(dx: -groupInflate, dy: -groupInflate)
                let intersects = inflated.intersects(currentBBox)
                let verticalOverlap = bounds.minY < currentBBox.maxY && bounds.maxY > currentBBox.minY
                let horizontalGap = bounds.minX - currentBBox.maxX
                let closeOnSameLine = verticalOverlap && horizontalGap < groupGap

                if intersects || closeOnSameLine {
                    groupIndices[groupIndices.count - 1].append(originalIndex)
                    groupBBoxes[groupBBoxes.count - 1] = currentBBox.union(bounds)
                    continue
                }
            }
            groupIndices.append([originalIndex])
            groupBBoxes.append(bounds)
        }

        // --- Step 2: cluster group centers on Y into lines ---
        let heights = groupBBoxes.map { $0.height }
        let medianHeight = median(heights)
        let lineThreshold = lineThresholdFactor * medianHeight

        let orderByY = groupBBoxes.indices.sorted { groupBBoxes[$0].midY < groupBBoxes[$1].midY }
        var lineForGroup = [Int](repeating: 0, count: groupBBoxes.count)
        var currentLine = 0
        var lastY: CGFloat?
        for groupIndex in orderByY {
            let y = groupBBoxes[groupIndex].midY
            if let lastY, y - lastY > lineThreshold {
                currentLine += 1
            }
            lineForGroup[groupIndex] = currentLine
            lastY = y
        }

        // --- Step 3: stable IDs via bbox-overlap match against `previous` ---
        var nextID = (previous.map(\.id).max() ?? 0) + 1
        var assignedID = [Int?](repeating: nil, count: groupBBoxes.count)

        // Score every (group, previous mark) pair with a nonzero overlap,
        // then assign greedily by largest overlap first so two groups
        // competing for the same previous mark don't get resolved by
        // array order alone.
        struct Candidate { let groupIndex: Int; let prevID: Int; let overlapArea: CGFloat }
        var candidates: [Candidate] = []
        for (groupIndex, bbox) in groupBBoxes.enumerated() {
            for prev in previous {
                let intersection = bbox.intersection(prev.bbox)
                guard !intersection.isNull else { continue }
                let area = intersection.width * intersection.height
                guard area > 0 else { continue }
                candidates.append(Candidate(groupIndex: groupIndex, prevID: prev.id, overlapArea: area))
            }
        }
        candidates.sort { $0.overlapArea > $1.overlapArea }

        var usedPrevIDs = Set<Int>()
        for candidate in candidates {
            guard assignedID[candidate.groupIndex] == nil, !usedPrevIDs.contains(candidate.prevID) else { continue }
            assignedID[candidate.groupIndex] = candidate.prevID
            usedPrevIDs.insert(candidate.prevID)
        }

        var marks: [Mark] = []
        marks.reserveCapacity(groupBBoxes.count)
        for groupIndex in groupBBoxes.indices {
            let id: Int
            if let matched = assignedID[groupIndex] {
                id = matched
            } else {
                id = nextID
                nextID += 1
            }
            marks.append(Mark(
                id: id,
                bbox: groupBBoxes[groupIndex],
                line: lineForGroup[groupIndex],
                strokeIndices: groupIndices[groupIndex]
            ))
        }
        return marks
    }

    private static func median(_ values: [CGFloat]) -> CGFloat {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 0 {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }

    /// Compact JSON pushed to the model alongside a snapshot:
    /// `{"page":"student","marks":[{"id":7,"bbox":[x,y,w,h],"line":2}]}`.
    /// Bbox values are rounded to ints — the model reasons about marks by
    /// ID, not sub-pixel geometry, so int precision keeps the payload small.
    static func registryJSON(page: String, marks: [Mark]) -> String {
        let marksJSON = marks.map { mark -> String in
            let b = mark.bbox
            let x = Int(b.origin.x.rounded())
            let y = Int(b.origin.y.rounded())
            let w = Int(b.width.rounded())
            let h = Int(b.height.rounded())
            return "{\"id\":\(mark.id),\"bbox\":[\(x),\(y),\(w),\(h)],\"line\":\(mark.line)}"
        }.joined(separator: ",")
        return "{\"page\":\"\(page)\",\"marks\":[\(marksJSON)]}"
    }

    /// Burns red mark-ID labels (white pill background) into a rendered
    /// snapshot image, for the copy the model sees. Canvas-space bboxes are
    /// mapped through `snapshot`'s transform — the only place this file
    /// touches image-pixel space (Global Constraint: canvas space
    /// everywhere else).
    static func burnLabels(into image: UIImage, marks: [Mark], snapshot: Snapshot) -> UIImage {
        guard !marks.isEmpty else { return image }

        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)

        return renderer.image { ctx in
            image.draw(at: .zero)

            let font = UIFont.boldSystemFont(ofSize: 22)
            let textColor = UIColor.red
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]
            let horizontalPadding: CGFloat = 8
            let verticalPadding: CGFloat = 4
            let gapFromMark: CGFloat = 4

            for mark in marks {
                let text = "\(mark.id)"
                let textSize = text.size(withAttributes: attributes)
                let pillSize = CGSize(
                    width: textSize.width + horizontalPadding * 2,
                    height: textSize.height + verticalPadding * 2
                )

                let markOriginInImage = snapshot.toImage(mark.bbox.origin)
                var pillOrigin = CGPoint(
                    x: markOriginInImage.x - pillSize.width - gapFromMark,
                    y: markOriginInImage.y
                )
                pillOrigin.x = max(0, min(pillOrigin.x, image.size.width - pillSize.width))
                pillOrigin.y = max(0, min(pillOrigin.y, image.size.height - pillSize.height))

                let pillRect = CGRect(origin: pillOrigin, size: pillSize)
                let pillPath = UIBezierPath(roundedRect: pillRect, cornerRadius: pillSize.height / 2)
                UIColor.white.setFill()
                pillPath.fill()

                let textOrigin = CGPoint(
                    x: pillRect.minX + horizontalPadding,
                    y: pillRect.minY + verticalPadding
                )
                text.draw(at: textOrigin, withAttributes: attributes)
            }
        }
    }
}
