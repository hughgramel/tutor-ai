import CoreGraphics
import Foundation

/// Tags the model can emit inline in its streamed transcript to drive
/// annotations/handwriting on the canvas. Mark IDs only — the model never
/// emits coordinates for existing content (Global Constraint: "the model
/// never emits coordinates for existing content — mark IDs only").
enum TutorTag: Equatable {
    case circle(Int)
    case underline(Int)
    case arrow(Int, Int)
    case highlight(Int)
    case newPage
    case write(latex: String, anchor: Anchor)
    case wait(Int)
    /// Stretch tag (plan self-review: "SHAPE/PLOT renderers = stretch;
    /// parser accepts them, renderer logs-and-drops until promoted").
    /// Carries the raw plot expression through untouched.
    case plot(String)
    /// Promoted from stretch: the tutor draws its own diagram on its own
    /// page. `points` are NORMALIZED `0...1` floats in the tutor page's
    /// coordinate box — the one sanctioned exception to "the model never
    /// emits coordinates" (Global Constraint), because a diagram on a blank
    /// tutor page has no existing ink for a mark ID to anchor to. `label`
    /// is `""` when the tag omits one.
    case shape(kind: String, points: [CGPoint], label: String)
}

/// Where a `[WRITE:...]` tag's handwriting should be anchored.
enum Anchor: Equatable {
    case belowLast
    case below(Int)
}

/// Incrementally parses `TutorTag`s out of a streamed transcript.
///
/// Clicky (`reference/clicky/CompanionManager.swift`, `parsePointingCoordinates`,
/// ~line 782) parses a single `[POINT:...]` tag anchored to the *end* of a
/// complete response string with one NSRegularExpression pass. We diverge
/// (see `reference/clicky/README.md`: "end-of-response-only tag (we parse
/// tags mid-stream)"): the realtime transcript arrives as many small deltas
/// and a tag can legally straddle a chunk boundary (`"[CIR"` in one delta,
/// `"CLE:7]"` in the next), and a single response can carry several tags.
/// `TagParser` keeps a small pending buffer across `feed()` calls so a tag
/// never gets sliced into two "unknown" halves, but otherwise ports the same
/// discipline Clicky's regex uses: match complete `[...]` groups, strip the
/// tag out of the spoken/displayed text, parse the body, drop anything that
/// doesn't parse.
final class TagParser {
    /// Every tag grammar below is `]`-free inside the brackets (including
    /// WRITE's LaTeX body — enforced by the plan's Task 8 test list: "WRITE
    /// latex containing ]-free pipes"), so a single non-nesting bracket
    /// match is exact — this is the plan's Step 2 "combined regex" trick,
    /// generalized to capture the body instead of matching per tag name.
    private static let bracketRegex = try! NSRegularExpression(pattern: "\\[([^\\[\\]]*)\\]", options: [])

    private static let knownTagNames: Set<String> = [
        "CIRCLE", "UNDERLINE", "ARROW", "HIGHLIGHT", "NEWPAGE", "WRITE", "WAIT", "PLOT", "SHAPE"
    ]

    /// A held-back tail up to this long is still "maybe a tag, wait for more
    /// input"; past it we give up and flush it as plain text (plan Step 2:
    /// "hold a partial-tag tail up to 400 chars, flush as plain text if it
    /// never closes").
    private static let maxPendingLength = 400

    private var buffer = ""

    /// Feed the next transcript delta. Returns display text (tags stripped,
    /// safe to append to the subtitle) and any tags that completed on this
    /// call. A tag split across deltas produces no tag and no subtitle text
    /// for the partial fragment until it closes.
    func feed(_ chunk: String) -> (subtitleText: String, tags: [TutorTag]) {
        buffer += chunk
        return drain()
    }

    /// Call at end of stream (or end of a response) to release any dangling
    /// partial tag as plain text instead of holding it forever.
    func flush() -> (subtitleText: String, tags: [TutorTag]) {
        let text = buffer
        buffer = ""
        return (text, [])
    }

    private func drain() -> (subtitleText: String, tags: [TutorTag]) {
        var output = ""
        var tags: [TutorTag] = []

        let nsRange = NSRange(buffer.startIndex..<buffer.endIndex, in: buffer)
        let matches = Self.bracketRegex.matches(in: buffer, options: [], range: nsRange)

        var consumedUpTo = buffer.startIndex
        for match in matches {
            guard let fullRange = Range(match.range, in: buffer),
                  let contentRange = Range(match.range(at: 1), in: buffer) else { continue }

            output += buffer[consumedUpTo..<fullRange.lowerBound]

            let content = String(buffer[contentRange])
            if let tag = Self.parseTag(content) {
                tags.append(tag)
            } else {
                // Unknown/malformed tag: stripped from the subtitle, never
                // surfaced, never crashes (plan Step 2: "Unknown [WORD:...]
                // → strip silently").
                TutorLog.shared.info("TagParser: dropped malformed/unknown tag [\(content)]")
            }

            consumedUpTo = fullRange.upperBound
        }

        let tail = buffer[consumedUpTo...]
        if let openIndex = tail.lastIndex(of: "[") {
            // Everything before the dangling "[" is safe display text now;
            // the "[" onward might still become a tag on a future feed().
            output += tail[tail.startIndex..<openIndex]
            var pending = String(tail[openIndex...])
            if pending.count > Self.maxPendingLength {
                // Never closed within budget — give up, it's just text.
                output += pending
                pending = ""
            }
            buffer = pending
        } else {
            output += tail
            buffer = ""
        }

        return (output, tags)
    }

    // MARK: - Tag body parsing

    private static func parseTag(_ content: String) -> TutorTag? {
        let name: Substring
        let body: Substring
        if let colonIndex = content.firstIndex(of: ":") {
            name = content[content.startIndex..<colonIndex]
            body = content[content.index(after: colonIndex)...]
        } else {
            name = Substring(content)
            body = ""
        }

        guard knownTagNames.contains(String(name)) else { return nil }

        switch name {
        case "CIRCLE":
            return intBody(body).map { .circle($0) }
        case "UNDERLINE":
            return intBody(body).map { .underline($0) }
        case "HIGHLIGHT":
            return intBody(body).map { .highlight($0) }
        case "ARROW":
            return parseArrow(body)
        case "NEWPAGE":
            return body.isEmpty ? .newPage : nil
        case "WRITE":
            return parseWrite(body)
        case "WAIT":
            return intBody(body).map { .wait($0) }
        case "PLOT":
            return body.isEmpty ? nil : .plot(String(body))
        case "SHAPE":
            return parseShape(body)
        default:
            return nil
        }
    }

    private static func intBody(_ body: Substring) -> Int? {
        Int(body)
    }

    /// `[ARROW:from>to]` — two mark ids separated by `>`.
    private static func parseArrow(_ body: Substring) -> TutorTag? {
        let parts = body.split(separator: ">", omittingEmptySubsequences: false)
        guard parts.count == 2, let from = Int(parts[0]), let to = Int(parts[1]) else { return nil }
        return .arrow(from, to)
    }

    /// `[WRITE:latex|below:id]` / `[WRITE:latex|below:last]`. LaTeX can
    /// legitimately contain `|` (absolute value bars), so the anchor suffix
    /// is split off the *last* `|` in the body, not the first — otherwise
    /// `|x|+1|below:7` would slice the latex apart at the wrong pipe.
    private static func parseWrite(_ body: Substring) -> TutorTag? {
        guard let lastPipe = body.lastIndex(of: "|") else { return nil }
        let latex = body[body.startIndex..<lastPipe]
        let anchorStr = body[body.index(after: lastPipe)...]
        guard !latex.isEmpty, let anchor = parseAnchor(anchorStr) else { return nil }
        return .write(latex: String(latex), anchor: anchor)
    }

    private static func parseAnchor(_ raw: Substring) -> Anchor? {
        guard raw.hasPrefix("below:") else { return nil }
        let idPart = raw.dropFirst("below:".count)
        if idPart == "last" { return .belowLast }
        guard let id = Int(idPart) else { return nil }
        return .below(id)
    }

    /// `kind` values `[SHAPE:...]` accepts — the HeyClicky-derived grammar
    /// the plan adopts, narrowed to what a weekend demo needs: polygons
    /// (the a²+b²=c² triangle) and simple curves.
    private static let shapeKinds: Set<String> = ["polygon", "line", "curve"]

    /// `[SHAPE:kind:x,y;x,y;...:label]` — `label` optional. `kind` is one
    /// of `shapeKinds`; vertices are `;`-separated `x,y` pairs, each
    /// coordinate a normalized `0...1` float (see `TutorTag.shape`'s doc).
    /// Splitting on `:` with `maxSplits: 2` (not full split) mirrors
    /// `parseWrite`'s pipe handling: it lets a label contain its own `:`
    /// without slicing the tag apart, since only the *first two* colons are
    /// structural here (kind/points), same shape as WRITE using only its
    /// *last* `|` for the opposite reason (anchor is the suffix there,
    /// label is the suffix here).
    ///
    /// Malformed input (unknown `kind`, unparseable vertex, fewer than 2
    /// vertices) drops the whole tag — same discipline as every other tag.
    /// A vertex coordinate outside `0...1` is clamped rather than dropped:
    /// a diagram a hair past the edge of its drawing box is still a usable
    /// diagram, and clamping can't misplace it the way a bad coordinate
    /// misplaces an annotation (there's no existing ink to point at wrong).
    private static func parseShape(_ body: Substring) -> TutorTag? {
        let parts = body.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }

        let kind = String(parts[0])
        guard shapeKinds.contains(kind) else { return nil }

        guard let points = parsePoints(parts[1]), points.count >= 2 else { return nil }

        let label = parts.count > 2 ? String(parts[2]) : ""
        return .shape(kind: kind, points: points, label: label)
    }

    /// `x,y;x,y;...` -> `[CGPoint]`, each component clamped into `0...1`.
    /// `nil` if any vertex fails to parse as exactly two comma-separated
    /// numbers — a single bad vertex invalidates the whole shape rather
    /// than silently dropping a point and distorting it.
    private static func parsePoints(_ raw: Substring) -> [CGPoint]? {
        guard !raw.isEmpty else { return nil }
        var points: [CGPoint] = []
        for vertex in raw.split(separator: ";", omittingEmptySubsequences: false) {
            let coords = vertex.split(separator: ",", omittingEmptySubsequences: false)
            guard coords.count == 2,
                  let x = Double(coords[0]),
                  let y = Double(coords[1]) else { return nil }
            points.append(CGPoint(x: clampUnit(x), y: clampUnit(y)))
        }
        return points
    }

    private static func clampUnit(_ value: Double) -> CGFloat {
        CGFloat(min(max(value, 0), 1))
    }
}
