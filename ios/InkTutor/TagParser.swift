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
    /// Stretch tag, same status as `.plot`. No wire grammar for geometry
    /// exists yet, and the model can never emit coordinates (Global
    /// Constraint), so `points` is always empty here — this case only
    /// exists so a future renderer has somewhere to land `kind`/`label`.
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

    /// `[SHAPE:kind|label]` (label optional). No wire grammar for geometry
    /// exists yet (plan self-review: "SHAPE/PLOT renderers = stretch"), and
    /// the model can't emit coordinates anyway, so `points` is always `[]`.
    private static func parseShape(_ body: Substring) -> TutorTag? {
        guard !body.isEmpty else { return nil }
        let parts = body.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        let kind = String(parts[0])
        guard !kind.isEmpty else { return nil }
        let label = parts.count > 1 ? String(parts[1]) : ""
        return .shape(kind: kind, points: [], label: label)
    }
}
