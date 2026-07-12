import Foundation
import UIKit

/// The integration glue between `TutorSession`, `MarkRegistry`, `TagParser`,
/// and the annotation renderer (plan Task 7, adapted; wired into
/// `CanvasScreen`/`CanvasView`). Post-pivot (Hugh, 2026-07-12: "remove the
/// 'AI gets its own page', we can just work on the right alongside the
/// user") there is exactly ONE `PageModel` on screen — `studentPage` and
/// `tutorPage` below are the SAME instance, passed twice at `CanvasScreen`'s
/// construction site. That collapse is deliberate, not an oversight: every
/// `isTutorPage`/`resolveMark`/`nextMarkID` check already keyed off
/// `PageModel.id` rather than object identity, so aliasing the two
/// parameters to one page means ink marks, written marks, and the writer's
/// `CALayer` all merge into that one page's registry/snapshot for free, with
/// no change to the internal bookkeeping below. `PageModel.role` still has a
/// `.tutor` case (kept to avoid churn — see `PageModel.swift`); it's just
/// never constructed anymore.

// MARK: - Protocol seams

/// Performs one of the four annotate-only visual actions
/// (`AnnotationOverlayView`'s `Annotation` enum) on a specific page. Still a
/// protocol rather than a bare closure even though there's only one overlay
/// now — keeps the seam testable (`FakeAnnotationPerformer`) without
/// depending on `AnnotationOverlayView`'s real `UIView`.
protocol AnnotationPerforming: AnyObject {
    func perform(_ annotation: Annotation, on page: PageModel)
}

/// `[WRITE:latex]` handler. `TutorWriter` (Task 11) is the real
/// implementation — protocolled here as a closure so this file doesn't
/// depend on it directly. Takes the ALREADY-COMPUTED page-space origin
/// (`TutorCoordinator.nextWriteOrigin()`), not the model's requested
/// `Anchor`: write placement is entirely client-owned now (the "never write
/// on or over the student's ink" law replaces the old "own page only"
/// rule), so by the time this closure is called there's nothing left for
/// the anchor to influence.
///
/// `async`, returning the written glyphs' placements (page/canvas space):
/// `TutorWriter.write` lays out per-glyph frames internally but only ever
/// hands back the aggregate bounding rect — this closure's return value is
/// how those per-glyph frames reach `TutorCoordinator`, which turns them
/// into addressable `Mark`s (`appendWrittenMarks`) so `[ARROW:a>b]`/
/// `[CIRCLE:n]` can target the tutor's own handwriting, not just ink. Empty
/// array if the writer isn't attached yet or the latex failed to parse.
typealias WriteHandler = (_ latex: String, _ origin: CGPoint) async -> [TutorWriterLayout.GlyphPlacement]

/// Reports the `CALayer` holding the tutor's handwritten glyph content —
/// `TutorWriter.contentLayer`, already in untransformed page-point space —
/// so `pushEnrichedSnapshot` can composite it into the shared page's
/// snapshot the same way `SnapshotRenderer` already composites
/// `page.drawing`. `TutorWriter`'s `CAShapeLayer`s never enter any
/// `PKDrawing`, so without this the page's own snapshot would never show
/// what the tutor wrote. Returns `nil` before `TutorWriter` exists yet.
/// Defaulted to `{ nil }` at `TutorCoordinator.init` so existing callers
/// (tests, the `VoiceBarView` preview) that don't care about snapshot
/// compositing don't need updating.
typealias WrittenLayerProvider = () -> CALayer?

// MARK: - Journal (Task 7, capped)

/// One structured event in the coordinator's in-memory journal. Every field
/// here is built from already-parsed values (a `TutorTag` case, a mark id,
/// an already-resolved anchor) rather than raw transcript text, so nothing
/// here can carry a live `[TAG:...]` fragment by construction — but any
/// string that *could* have come from free-form text is still run through
/// `TutorCoordinator.stripTags` before it's stored (Clicky's discipline:
/// `reference/clicky/CompanionManager.swift` ~684 strips its point-tag
/// before saving an exchange to `conversationHistory`, because that history
/// is replayed back into the model on the next turn — same reasoning
/// applies here: `journalJSON()` is designed to re-enter the session on
/// reconnect, so nothing that reaches it may still contain a tag).
enum JournalEvent: Codable, Equatable {
    case snapshotPushed(page: String, markCount: Int)
    case tagRendered(tag: String, markIds: [Int])
    case tagDropped(tag: String, reason: String)
    case wrote(latex: String, anchor: String)
    case waited(seconds: Int)
}

struct JournalEntry: Codable, Equatable {
    let timestamp: Date
    let event: JournalEvent
}

// MARK: - TutorCoordinator

/// Owns: mark-registry state per page (so IDs stay stable across snapshot
/// pushes), the streaming `TagParser`, tag dispatch with page-rule
/// enforcement, and the capped event journal. Everything UI-adjacent this
/// touches — `AnnotationPerforming.perform`, the open/write closures, the
/// journal — is expected to run on the main thread (SwiftUI state, UIKit
/// layers), so the whole type is pinned to `@MainActor` rather than hopping
/// per-call the way `RealtimeSession`/`VoiceBarView` do today.
@MainActor
final class TutorCoordinator {

    // MARK: Dependencies (protocol/closure only — see file header)

    private let session: TutorSession
    let studentPage: PageModel
    let tutorPage: PageModel
    private let pageSize: CGSize
    private let performer: AnnotationPerforming
    private let writeHandler: WriteHandler
    private let writtenLayerProvider: WrittenLayerProvider

    init(
        session: TutorSession,
        studentPage: PageModel,
        tutorPage: PageModel,
        pageSize: CGSize,
        performer: AnnotationPerforming,
        writeHandler: @escaping WriteHandler,
        writtenLayerProvider: @escaping WrittenLayerProvider = { nil }
    ) {
        self.session = session
        self.studentPage = studentPage
        self.tutorPage = tutorPage
        self.pageSize = pageSize
        self.performer = performer
        self.writeHandler = writeHandler
        self.writtenLayerProvider = writtenLayerProvider
    }

    deinit {
        transcriptTask?.cancel()
    }

    // MARK: - 1. Snapshot enrichment

    /// Per-page mark state, keyed by `PageModel.id`, threaded as `previous`
    /// into every `MarkRegistry.compute` call so IDs stay stable across
    /// recomputes (Global Constraint: "the model never emits coordinates
    /// for existing content — mark IDs only", which only holds if a mid-
    /// sentence `[CIRCLE:7]` still points at the right ink after the
    /// student adds a stroke elsewhere).
    private var currentMarks: [UUID: [Mark]] = [:]

    /// Marks for glyphs `TutorWriter` has hand-written on the tutor page —
    /// the WRITE-tag analog of `currentMarks`, but not keyed by page id: a
    /// single flat list is enough because WRITE is structurally always the
    /// tutor's own page (see `dispatchWrite`'s doc comment). Populated by
    /// `appendWrittenMarks` after each completed WRITE; never recomputed
    /// from scratch the way `currentMarks` is (there's no PKDrawing to
    /// recompute FROM — a written mark's geometry is exactly what
    /// `TutorWriter` laid out, once, and doesn't move).
    private var writtenMarks: [Mark] = []
    /// One shared `line` number per WRITE call (every glyph an equation
    /// produces reads, to a human, as "one line" — matches how the model
    /// would say "circle the whole equation"), incrementing per call so two
    /// separate WRITEs don't collide on the same line number.
    private var nextWrittenLine = 0
    /// The bounding rect of whatever the tutor most recently placed on the
    /// page — a WRITE's glyph bounds or a SHAPE's content box — `nil` until
    /// the first one lands. Shared between both (not "lastWRITERect") so a
    /// write followed by a shape, or vice versa, stack instead of
    /// overlapping. `belowWorkOrigin()`/`nextShapeBox()` place everything
    /// after the first directly below this (the "keep going down the
    /// column" convention `TutorWriteRouter.lastRect` used before placement
    /// moved into this file — see `belowWorkOrigin()`'s doc for the full
    /// law).
    private var lastWriteRect: CGRect?

    /// Computes marks for `page.drawing`, renders + labels a snapshot, and
    /// pushes both the labeled JPEG and the registry JSON to the session.
    /// This is the ONE call the canvas layer should make per debounced
    /// stroke-end — it replaces the bare `session.pushImage(snapshot.jpeg)`
    /// call `CanvasView.Coordinator.pushSnapshotIfDue` makes today (that
    /// method already owns the debounce/min-interval/unchanged-drawing
    /// gating from the plan's image-context budget; only the "what do I
    /// push" step changes, not the "when"). Also the call `dispatchWrite`
    /// makes directly (not through the debounced canvas path — there's no
    /// PKCanvasView stroke to debounce off of) once a WRITE completes, so
    /// the tutor page's own writing becomes visible + addressable to the
    /// model right after it's drawn.
    ///
    /// For the tutor page specifically, this also folds in `writtenMarks`
    /// (ink-only `MarkRegistry.compute` can't see `TutorWriter`'s
    /// CAShapeLayers — they never enter any `PKDrawing`) into both the
    /// registry JSON and the rendered snapshot (via `writtenLayerProvider`).
    @discardableResult
    func pushEnrichedSnapshot(for page: PageModel) async -> [Mark] {
        let isTutorPage = page.id == tutorPage.id
        let strokePrevious = currentMarks[page.id] ?? []
        // Seed MarkRegistry's own nextID counter (`previous.map(\.id).max()
        // + 1`) with writtenMarks' IDs too, on the tutor page, so a brand
        // new ink stroke there can never land on an ID a written glyph
        // already holds — the two mark kinds share one counter space (see
        // `nextMarkID(for:)`, the written side of the same guarantee).
        // Feeding writtenMarks into `previous` also makes them eligible for
        // MarkRegistry's bbox-overlap ID-matching, so a real stroke drawn
        // directly on top of written ink could in principle inherit its
        // mark ID — a documented judgment call (same status as this file's
        // existing same-id-on-both-pages tiebreak), not expected in
        // practice since the tutor page is scratch space the tutor writes
        // on, not the student.
        let seedPrevious = isTutorPage ? strokePrevious + writtenMarks : strokePrevious
        let strokeMarks = MarkRegistry.compute(drawing: page.drawing, previous: seedPrevious)
        currentMarks[page.id] = strokeMarks

        let marks = isTutorPage ? strokeMarks + writtenMarks : strokeMarks

        let writerLayer = isTutorPage ? writtenLayerProvider() : nil
        let snapshot = SnapshotRenderer.render(page: page, pageSize: pageSize, writerLayer: writerLayer)
        let jpeg = labeledJpeg(from: snapshot, marks: marks)

        await session.pushImage(jpeg)
        await session.pushEvent(MarkRegistry.registryJSON(page: pageName(for: page), marks: marks))
        appendJournal(.snapshotPushed(page: pageName(for: page), markCount: marks.count))

        return marks
    }

    /// Turns one WRITE call's glyph placements into `Mark`s — one mark per
    /// glyph (a written equation is a handful of characters; per-glyph IDs
    /// are cheap and let `[ARROW:a>b]` target an individual term, e.g. the
    /// "2" a distributed multiplication arcs out from, not just "the whole
    /// equation"). IDs come from `nextMarkID(for:)`, the same counter space
    /// `MarkRegistry.compute` seeds from for ink — see that method's doc.
    @discardableResult
    private func appendWrittenMarks(_ placements: [TutorWriterLayout.GlyphPlacement]) -> [Mark] {
        guard !placements.isEmpty else { return [] }
        let line = nextWrittenLine
        nextWrittenLine += 1

        var id = nextMarkID(for: tutorPage)
        var newMarks: [Mark] = []
        newMarks.reserveCapacity(placements.count)
        for placement in placements {
            newMarks.append(Mark(id: id, bbox: placement.frame, line: line, strokeIndices: [], written: true))
            id += 1
        }
        writtenMarks.append(contentsOf: newMarks)
        return newMarks
    }

    /// The next free mark ID for `page`, seeded above the highest ID either
    /// mark kind currently holds on that page — the shared counter space
    /// `MarkRegistry.compute` (ink) and `appendWrittenMarks` (written) both
    /// draw from, so the same integer can never mean "ink stroke" on one
    /// push and "written glyph" on the next.
    private func nextMarkID(for page: PageModel) -> Int {
        let strokeMax = currentMarks[page.id]?.map(\.id).max() ?? 0
        let writtenMax = writtenMarks.map(\.id).max() ?? 0
        return max(strokeMax, writtenMax) + 1
    }

    /// Decodes the rendered (unlabeled) JPEG back to a `UIImage`, burns the
    /// mark-ID labels in via `MarkRegistry.burnLabels`, and re-encodes.
    /// `SnapshotRenderer.render` hands back only the final JPEG `Data`, not
    /// the intermediate `UIImage`, so label burn-in has to round-trip
    /// through JPEG decode here rather than composing during the original
    /// render pass.
    private func labeledJpeg(from snapshot: Snapshot, marks: [Mark]) -> Data {
        guard let image = UIImage(data: snapshot.jpeg) else {
            TutorLog.shared.error("TutorCoordinator: failed to decode rendered snapshot JPEG for label burn-in; pushing unlabeled")
            return snapshot.jpeg
        }
        let labeled = MarkRegistry.burnLabels(into: image, marks: marks, snapshot: snapshot)
        return labeled.jpegData(compressionQuality: SnapshotRenderer.jpegQuality) ?? snapshot.jpeg
    }

    private func pageName(for page: PageModel) -> String {
        page.role == .student ? "student" : "tutor"
    }

    // MARK: - 2. Transcript routing

    private var tagParser = TagParser()
    private var subtitleContinuation: AsyncStream<String>.Continuation?
    private var transcriptTask: Task<Void, Never>?

    /// Stripped display text, ready for the voice bar's subtitle box. At
    /// wiring time this REPLACES `session.transcriptDeltas` as what
    /// `VoiceBarView.streamTranscript()` iterates — the raw deltas still
    /// flow (into `start()`'s loop below), but only after being fed through
    /// `TagParser` here first, so the UI never sees a live `[CIRCLE:7]`
    /// fragment. Like `RealtimeSession.transcriptDeltas`, this recreates its
    /// continuation on every access — one live subscriber at a time, same
    /// convention the rest of the codebase already uses.
    var subtitleStream: AsyncStream<String> {
        AsyncStream { continuation in
            self.subtitleContinuation = continuation
        }
    }

    /// Begins consuming `session.transcriptDeltas`: feeds every delta
    /// through `TagParser`, republishes stripped text on `subtitleStream`,
    /// and dispatches completed tags. Call once after `session.connect()`
    /// succeeds; safe to call again after `stop()`.
    func start() {
        guard transcriptTask == nil else { return }
        transcriptTask = Task { [weak self] in
            guard let self else { return }
            for await delta in self.session.transcriptDeltas {
                let (text, tags) = self.tagParser.feed(delta)
                if !text.isEmpty {
                    self.subtitleContinuation?.yield(text)
                }
                for tag in tags {
                    await self.dispatch(tag)
                }
            }
            self.subtitleContinuation?.finish()
        }
    }

    func stop() {
        transcriptTask?.cancel()
        transcriptTask = nil
    }

    // MARK: - 3. Tag dispatch with page-rule enforcement

    /// Internal (not `private`) so `TutorCoordinatorTests` can drive
    /// individual tags deterministically without racing the `AsyncStream`
    /// lifecycle of `start()`/`session.transcriptDeltas` — the streamed
    /// parse path itself is `TagParser`'s job and is already covered
    /// exhaustively by `TagParserTests`; what this file needs proven is
    /// dispatch given an already-parsed tag.
    func dispatch(_ tag: TutorTag) async {
        switch tag {
        case .circle(let id):
            await dispatchAnnotation(Annotation.circle, tagName: "CIRCLE", id: id)
        case .underline(let id):
            await dispatchAnnotation(Annotation.underline, tagName: "UNDERLINE", id: id)
        case .highlight(let id):
            // Killed (Hugh, 2026-07-12: "remove the highlighting tool it
            // looks ugly, pointing is better"). The parser still accepts
            // HIGHLIGHT so a model that hasn't caught up to the new prompt
            // never crashes the tag pipeline — it's just dropped here,
            // same discipline as PLOT/an unresolved mark id, never routed
            // to the performer. `AnnotationOverlayView.Annotation.highlight`
            // and its `RoughGeometry.highlightPath` stay in place but are
            // now unreachable from this file.
            TutorLog.shared.info("TutorCoordinator: dropped HIGHLIGHT:\(id) — highlight tool removed")
            appendJournal(.tagDropped(tag: "HIGHLIGHT:\(id)", reason: "highlight tool removed"))
        case .arrow(let from, let to):
            await dispatchArrow(fromID: from, toID: to)
        case .newPage:
            // No-op (Hugh, 2026-07-12: "remove the 'AI gets its own page'").
            // The parser still accepts NEWPAGE so an in-flight session
            // built against the old prompt doesn't break; there is nothing
            // left to open — the tutor already works on the one shared
            // page, in the open space to the right of the student's ink.
            TutorLog.shared.info("TutorCoordinator: dropped NEWPAGE — no-op, single shared canvas")
            appendJournal(.tagDropped(tag: "NEWPAGE", reason: "no-op — single shared canvas"))
        case .write(let latex, let anchor):
            await dispatchWrite(latex: latex, anchor: anchor)
        case .wait(let seconds):
            // No-op beyond logging — the client honors silence elsewhere
            // (suppressing client-triggered response.create calls is a
            // later task's job against the same TutorSession).
            TutorLog.shared.info("TutorCoordinator: WAIT \(seconds)s")
            appendJournal(.waited(seconds: seconds))
        case .plot(let expression):
            TutorLog.shared.info("TutorCoordinator: dropped PLOT (\(expression)) — renderer not implemented")
            appendJournal(.tagDropped(tag: "PLOT", reason: "renderer not implemented"))
        case .shape(let kind, let points, let label):
            // SHAPE always renders on the shared page's overlay, scaled
            // into `nextShapeBox()` — same placement law as WRITE (below
            // the student's work, right-half overflow as fallback; see
            // that method's doc). No `resolveMark` needed: there's no mark
            // id, only normalized points, already validated/clamped 0...1
            // by `TagParser.parseShape`. `TutorTag.shape.label` is `""`
            // when the tag omits one; `Annotation.shape.label` wants `nil`
            // for "no label" — bridged here since that's the cheapest place
            // to do it.
            let box = nextShapeBox()
            performer.perform(.shape(kind: kind, points: points, label: label.isEmpty ? nil : label, box: box), on: studentPage)
            lastWriteRect = box
            appendJournal(.tagRendered(tag: "SHAPE:\(kind)", markIds: []))
        }
    }

    /// A single-mark annotate action (CIRCLE/UNDERLINE/HIGHLIGHT). Resolves
    /// `id` against whichever page's CURRENT registry has it; unknown id →
    /// dropped + logged, never crashes, never guesses.
    private func dispatchAnnotation(_ make: (Mark) -> Annotation, tagName: String, id: Int) async {
        guard let resolved = resolveMark(id: id) else {
            TutorLog.shared.info("TutorCoordinator: dropped \(tagName):\(id) — unknown mark id")
            appendJournal(.tagDropped(tag: "\(tagName):\(id)", reason: "unknown mark id"))
            return
        }
        performer.perform(make(resolved.mark), on: resolved.page)
        appendJournal(.tagRendered(tag: tagName, markIds: [id]))
        // The plan's §3 table: the model must know what's on screen — every
        // rendered mark gets echoed back into the session as an event.
        await session.pushEvent(markRenderedJSON(tag: tagName, markIds: [id]))
    }

    private func dispatchArrow(fromID: Int, toID: Int) async {
        guard let from = resolveMark(id: fromID),
              let to = resolveMark(id: toID),
              from.page.id == to.page.id else {
            let reason = "unknown mark id or cross-page pair"
            TutorLog.shared.info("TutorCoordinator: dropped ARROW:\(fromID)>\(toID) — \(reason)")
            appendJournal(.tagDropped(tag: "ARROW:\(fromID)>\(toID)", reason: reason))
            return
        }
        performer.perform(.arrow(from: from.mark, to: to.mark), on: from.page)
        appendJournal(.tagRendered(tag: "ARROW", markIds: [fromID, toID]))
        await session.pushEvent(markRenderedJSON(tag: "ARROW", markIds: [fromID, toID]))
    }

    /// Mark IDs are computed independently per page (`MarkRegistry` seeds
    /// its own counter per drawing), so in principle the same integer could
    /// exist on both pages' registries at once. The plan's guardrail table
    /// (Task 13) lists CIRCLE/UNDERLINE/ARROW/HIGHLIGHT as valid on
    /// "either page's marks" without a disambiguation rule for a collision,
    /// so this is a documented judgment call, not a spec'd behavior:
    /// student-page ink wins the tie. Checks `writtenMarks` last — tutor
    /// page only, and `nextMarkID(for:)` already keeps written IDs disjoint
    /// from the tutor page's own `currentMarks` entry, so there's no
    /// three-way tie to break there.
    private func resolveMark(id: Int) -> (mark: Mark, page: PageModel)? {
        if let mark = currentMarks[studentPage.id]?.first(where: { $0.id == id }) {
            return (mark, studentPage)
        }
        if let mark = currentMarks[tutorPage.id]?.first(where: { $0.id == id }) {
            return (mark, tutorPage)
        }
        if let mark = writtenMarks.first(where: { $0.id == id }) {
            return (mark, tutorPage)
        }
        return nil
    }

    /// WRITE now always lands directly on the student's own page, beneath
    /// their own work — the client-enforced law that replaces both the old
    /// "own page only" rule AND this file's own first cut at it (a fenced
    /// column to the right of the ink). Hugh, 2026-07-12, revising that
    /// first cut: "don't make it on the side; make it on the user's actual
    /// canvas they're drawing on" — like a person tutoring on paper writes
    /// underneath what's already there, not off in a margin.
    /// `nextWriteOrigin()` computes where, ignoring the model's requested
    /// `Anchor` entirely (it's still logged — see `describe(_:)` — for
    /// journal fidelity, but no longer drives placement; same judgment call
    /// `TutorWriteRouter` already made for `.below(id)` before this moved
    /// client-side).
    ///
    /// Once the write completes, its glyphs become addressable marks
    /// (`appendWrittenMarks`) and an enriched snapshot of the shared page
    /// goes out immediately — the debounced push `CanvasView.Coordinator`
    /// schedules on stroke-end never fires here (nothing changed in any
    /// `PKDrawing`), so without this push the model would never learn the
    /// IDs it needs to target what the tutor just wrote.
    private func dispatchWrite(latex: String, anchor: Anchor) async {
        let origin = nextWriteOrigin()
        let placements = await writeHandler(latex, origin)
        appendJournal(.wrote(latex: Self.stripTags(latex), anchor: describe(anchor)))
        guard !placements.isEmpty else { return }
        lastWriteRect = placements.reduce(CGRect.null) { $0.union($1.frame) }
        appendWrittenMarks(placements)
        await pushEnrichedSnapshot(for: tutorPage)
    }

    /// Vertical gap kept between the bottom of the student's work (or the
    /// tutor's last write) and where the next write starts — the "never
    /// write ON or OVER the student's ink" law's margin of safety in the
    /// primary (below-work) placement mode.
    private static let writeBelowGap: CGFloat = 40
    /// Left edge used when there's no ink yet to align under (nothing on
    /// the page for `belowWorkOrigin()` to read a left edge from).
    private static let writeLeftMarginFallback: CGFloat = 60
    /// Hard left clamp — a write never starts closer to the page edge than
    /// this, even if the student's own ink starts right at the margin.
    private static let writeMinX: CGFloat = 20
    /// Kept clear from the page's right edge when clamping a write's x, so
    /// there's always some width left to actually write into.
    private static let writeMinXBuffer: CGFloat = 100
    /// Gap kept clear between the rightmost student ink and where writing
    /// starts, in the right-overflow FALLBACK mode only (`rightOverflowOrigin()`).
    private static let writeRightGap: CGFloat = 32
    /// Vertical gap between one WRITE's bounds and the next, in the
    /// right-overflow FALLBACK mode only.
    private static let writeLineGap: CGFloat = 24
    /// Y for the very first write on a page with no ink yet (nothing to
    /// align "below the student's work" against, in either mode).
    private static let writeTopMarginFallback: CGFloat = 80
    /// How close to the page's bottom edge a write's computed origin can
    /// land before that mode counts as "vertically exhausted."
    private static let writePageBottomMargin: CGFloat = 40
    /// A `nextShapeBox()` result smaller than this on either axis isn't
    /// worth drawing a diagram into — falls back to the right-half box
    /// instead of squeezing a shape into a sliver of leftover space.
    private static let shapeMinBoxSize: CGFloat = 150

    /// Where the next `[WRITE:...]` should start, in page-space. Tries the
    /// primary law first (`belowWorkOrigin()` — directly beneath the
    /// student's own work); if there's no vertical room left for that,
    /// falls back to `rightOverflowOrigin()` (this file's original
    /// right-of-the-ink column, kept as the escape hatch Hugh's revision
    /// explicitly asked for: "if vertical space runs out, THEN overflow to
    /// the right of their work").
    private func nextWriteOrigin() -> CGPoint {
        belowWorkOrigin() ?? rightOverflowOrigin()
    }

    /// Primary placement: directly below the student's own work, like a
    /// tutor writing underneath what's on the page. `x` is left-aligned
    /// with the student's ink (its leftmost edge, clamped inside the page)
    /// — recomputed on every call, not just the first write, so a run of
    /// writes reads as one visually consistent column under the student's,
    /// not a first-write-only alignment that drifts on later calls. `y` is
    /// below the LOWER of (the student's ink) and (the tutor's last write):
    /// if the student has since written further down than the last write
    /// landed, this re-derives from their new bottommost mark instead of
    /// stacking under a now-stale `lastWriteRect` and landing on top of
    /// what they just added. Returns `nil` — "no room" — when that `y`
    /// would run past the page's bottom edge, so the caller can fall back
    /// to `rightOverflowOrigin()`.
    private func belowWorkOrigin() -> CGPoint? {
        let inkMarks = currentMarks[studentPage.id] ?? []
        let inkMinX = inkMarks.map(\.bbox.minX).min()
        let inkMaxY = inkMarks.map(\.bbox.maxY).max()

        let x = min(max(inkMinX ?? Self.writeLeftMarginFallback, Self.writeMinX), pageSize.width - Self.writeMinXBuffer)

        let belowCandidates = [inkMaxY, lastWriteRect?.maxY].compactMap { $0 }
        let y = belowCandidates.isEmpty
            ? Self.writeTopMarginFallback
            : belowCandidates.max()! + Self.writeBelowGap

        guard y <= pageSize.height - Self.writePageBottomMargin else { return nil }
        return CGPoint(x: x, y: y)
    }

    /// Fallback placement (superseded as the primary law by Hugh's
    /// 2026-07-12 revision, kept as the vertical-exhaustion escape hatch):
    /// `x: max(rightmost edge of all student marks + 32pt, pageWidth *
    /// 0.5)`, `y:` the top of the student's most recently reached line for
    /// the FIRST write in this mode, then stacked below `lastWriteRect` for
    /// every write after that. If even THIS `y` would run the writing past
    /// the page's bottom edge, placement continues below everything already
    /// on the page (ink and prior writes alike) instead of overlapping the
    /// last thing written in the right column.
    private func rightOverflowOrigin() -> CGPoint {
        let inkMarks = currentMarks[studentPage.id] ?? []
        let rightmostInkEdge = inkMarks.map(\.bbox.maxX).max() ?? 0
        let x = max(rightmostInkEdge + Self.writeRightGap, pageSize.width * 0.5)

        let firstWriteY: CGFloat
        if let mostRecentLine = inkMarks.map(\.line).max() {
            let topsOnLine = inkMarks.filter { $0.line == mostRecentLine }.map(\.bbox.minY)
            firstWriteY = topsOnLine.min() ?? Self.writeTopMarginFallback
        } else {
            firstWriteY = Self.writeTopMarginFallback
        }
        let y = lastWriteRect.map { $0.maxY + Self.writeLineGap } ?? firstWriteY

        guard y > pageSize.height - Self.writePageBottomMargin else {
            return CGPoint(x: x, y: y)
        }
        let contentBottoms = inkMarks.map(\.bbox.maxY) + [lastWriteRect?.maxY ?? 0]
        let below = (contentBottoms.max() ?? 0) + Self.writeLineGap
        return CGPoint(x: x, y: below)
    }

    /// Where the next `[SHAPE:...]` diagram draws, as a page-space box —
    /// same two-mode law as `nextWriteOrigin()`: primary is below the
    /// student's work (reusing `belowWorkOrigin()` for the top-left
    /// corner, then sizing the box to whatever room remains), falling back
    /// to `RoughGeometry.shapeContentBox`'s fixed right-half box if that
    /// remaining room is too small to draw a diagram into
    /// (`shapeMinBoxSize`). `dispatch(_:)`'s `.shape` case sets
    /// `lastWriteRect` to whatever this returns, so a WRITE and a SHAPE
    /// placed back-to-back stack instead of overlapping — same sharing
    /// `belowWorkOrigin()` already relies on in the other direction.
    private func nextShapeBox() -> CGRect {
        guard let origin = belowWorkOrigin() else {
            return RoughGeometry.shapeContentBox(pageSize: pageSize)
        }
        let width = pageSize.width - origin.x - Self.writeMinX
        let height = pageSize.height - origin.y - Self.writePageBottomMargin
        guard width >= Self.shapeMinBoxSize, height >= Self.shapeMinBoxSize else {
            return RoughGeometry.shapeContentBox(pageSize: pageSize)
        }
        return CGRect(origin: origin, size: CGSize(width: width, height: height))
    }

    /// The model's requested anchor, kept for the journal only — placement
    /// itself no longer consults it (see `dispatchWrite`'s doc comment).
    private func describe(_ anchor: Anchor) -> String {
        switch anchor {
        case .belowLast: return "below:last"
        case .below(let id): return "below:\(id)"
        }
    }

    private func markRenderedJSON(tag: String, markIds: [Int]) -> String {
        let ids = markIds.map(String.init).joined(separator: ",")
        return "{\"type\":\"mark_rendered\",\"tag\":\"\(tag)\",\"marks\":[\(ids)]}"
    }

    // MARK: - 4. Journal

    private(set) var journal: [JournalEntry] = []
    private let journalCap = 50

    private func appendJournal(_ event: JournalEvent) {
        journal.append(JournalEntry(timestamp: Date(), event: event))
        if journal.count > journalCap {
            journal.removeFirst(journal.count - journalCap)
        }
    }

    /// Compact JSON array of the capped journal, newest-last — for a future
    /// `session_resume` reconnect payload (plan Task 7 Step 3). Not wired
    /// to anything yet; exposed so the reconnect flow can be added later
    /// without touching this file's internals.
    func journalJSON() -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(journal), let text = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return text
    }

    /// Runs `text` through a scratch `TagParser` and returns only the
    /// stripped display portion, discarding any tags found. Defensive:
    /// every value that lands in `JournalEvent` today is already built from
    /// a successfully-parsed `TutorTag` (so it structurally can't contain a
    /// live `[TAG:...]`), but `journalJSON()` is designed to re-enter the
    /// session on reconnect (Clicky's pattern — see the `JournalEvent` doc
    /// comment above), so anything free-form gets run through this first
    /// rather than relying on that invariant holding forever.
    static func stripTags(_ text: String) -> String {
        let parser = TagParser()
        let (strippedNow, _) = parser.feed(text)
        let (strippedTail, _) = parser.flush()
        return strippedNow + strippedTail
    }
}

// MARK: - Wiring status
//
// Already wired: `CanvasScreen` constructs one `TutorCoordinator`, passing
// the SAME `PageModel` instance as both `studentPage` and `tutorPage` (see
// this file's header comment), a `TutorAnnotationPerformer` adapter as
// `performer`, and `TutorWriteRouter.handle(latex:origin:)` as
// `writeHandler`. `CanvasView.Coordinator.pushSnapshotIfDue()` calls
// `coordinator.pushEnrichedSnapshot(for:)`; `VoiceBarView` streams
// `coordinator.subtitleStream` and calls `coordinator.start()` after
// `session.connect()` succeeds.
