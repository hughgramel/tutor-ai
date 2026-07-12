import XCTest
import PencilKit
import UIKit
@testable import InkTutor

/// `TutorCoordinator` is the glue between `TutorSession`, `MarkRegistry`,
/// `TagParser`, and the annotation renderer — the plan's Task 7. These tests
/// use fakes for everything (`FakeTutorSession`, `FakeAnnotationPerformer`)
/// and drive two paths:
///   - `dispatch(_:)` directly, for page-rule enforcement and journal
///     behavior given an already-parsed `TutorTag` (the streamed-parse path
///     itself is `TagParser`'s job, covered by `TagParserTests`).
///   - the full `session.transcriptDeltas` -> `start()` -> `subtitleStream`
///     pipeline, for the one thing that path alone proves: tags get
///     stripped from what the voice bar would display.
///
/// Post-pivot (Hugh, 2026-07-12: "remove the 'AI gets its own page', we can
/// just work on the right alongside the user"), there's exactly ONE
/// `PageModel` on screen — `makeCoordinator` takes a single `page` and hands
/// it to `TutorCoordinator` as both its `studentPage` and `tutorPage`
/// arguments, same as `CanvasScreen` does at the real construction site.
@MainActor
final class TutorCoordinatorTests: XCTestCase {

    // MARK: - Fakes

    final class FakeTutorSession: TutorSession {
        private(set) var pushedImages: [Data] = []
        private(set) var pushedEvents: [String] = []
        var isSpeaking: Bool = false

        /// Built once at init (not recreated per access, unlike
        /// `RealtimeSession`'s convention) so `sendDelta` can be called at
        /// any time relative to when `TutorCoordinator.start()` actually
        /// begins consuming it — `AsyncStream`'s default unbounded
        /// buffering queues anything yielded before a consumer attaches.
        let transcriptDeltas: AsyncStream<String>
        private let continuation: AsyncStream<String>.Continuation

        init() {
            var capturedContinuation: AsyncStream<String>.Continuation!
            self.transcriptDeltas = AsyncStream { continuation in
                capturedContinuation = continuation
            }
            self.continuation = capturedContinuation
        }

        func sendDelta(_ text: String) { continuation.yield(text) }
        func finishTranscript() { continuation.finish() }

        // Added post-hoc: `TutorSession` grew `isConnected`/`userTranscript`/
        // `audioLevel`/`startTalking`/`stopTalking` on `voicebar-v2` (push-to-
        // talk + waveform), which landed after this file was written against
        // an earlier version of the protocol. None of these are exercised by
        // `TutorCoordinator` itself (only the wiring layer reads them), so
        // they're inert stubs here purely to satisfy the protocol.
        var isConnected: Bool = true
        var userTranscript: AsyncStream<String> { AsyncStream { _ in } }
        var audioLevel: AsyncStream<Float> { AsyncStream { _ in } }
        func stopSpeaking() async {}
        func startTalking() async {}
        func stopTalking() async {}

        func connect() async throws {}
        func pushImage(_ jpeg: Data) async { pushedImages.append(jpeg) }
        func pushEvent(_ json: String) async { pushedEvents.append(json) }
        func endSession() {}
    }

    final class FakeAnnotationPerformer: AnnotationPerforming {
        struct Call { let annotation: Annotation; let page: PageModel }
        private(set) var calls: [Call] = []
        func perform(_ annotation: Annotation, on page: PageModel) {
            calls.append(Call(annotation: annotation, page: page))
        }
    }

    // MARK: - Helpers

    private static let testPageSize = CGSize(width: 768, height: 1024)

    private func makeCoordinator(
        session: TutorSession,
        performer: AnnotationPerforming,
        page: PageModel,
        onWrite: @escaping (String, CGPoint) async -> [TutorWriterLayout.GlyphPlacement] = { _, _ in [] },
        writtenLayer: @escaping () -> CALayer? = { nil }
    ) -> TutorCoordinator {
        TutorCoordinator(
            session: session,
            studentPage: page,
            tutorPage: page,
            pageSize: Self.testPageSize,
            performer: performer,
            writeHandler: onWrite,
            writtenLayerProvider: writtenLayer
        )
    }

    /// A `TutorWriterLayout.GlyphPlacement` fake — real placements come from
    /// `TutorWriterLayout.layout` (SwiftMath geometry), but everything this
    /// file needs to prove (registry JSON, mark resolution, dispatch) only
    /// depends on `frame`/`glyphKey`/`character` as opaque values, so a
    /// fake avoids parsing real latex through CoreAnimation/SwiftMath in a
    /// unit test (per the plan's "no CoreAnimation assertions" rule).
    private func fakeGlyph(_ character: String, _ frame: CGRect) -> TutorWriterLayout.GlyphPlacement {
        TutorWriterLayout.GlyphPlacement(character: character, glyphKey: character, frame: frame)
    }

    private func drawing(_ points: [CGPoint]) -> PKDrawing {
        PKDrawing(strokes: [stroke(from: points)])
    }

    // MARK: - 1. Snapshot enrichment: mark stability across two pushes

    func testMarkIdsStableAcrossTwoSnapshotPushes() async {
        let session = FakeTutorSession()
        let page = PageModel(role: .student)
        let coordinator = makeCoordinator(session: session, performer: FakeAnnotationPerformer(), page: page)

        page.drawing = drawing([CGPoint(x: 100, y: 500), CGPoint(x: 120, y: 510), CGPoint(x: 140, y: 500)])
        let firstMarks = await coordinator.pushEnrichedSnapshot(for: page)
        XCTAssertEqual(firstMarks.count, 1)
        XCTAssertEqual(firstMarks[0].id, 1)

        // Add a second, far-away stroke (different line) — the first
        // mark's bbox is unchanged, so it must keep id 1; the new one gets
        // a fresh id.
        page.drawing = PKDrawing(strokes: [
            stroke(from: [CGPoint(x: 100, y: 500), CGPoint(x: 120, y: 510), CGPoint(x: 140, y: 500)]),
            stroke(from: [CGPoint(x: 100, y: 700), CGPoint(x: 120, y: 710), CGPoint(x: 140, y: 700)]),
        ])
        let secondMarks = await coordinator.pushEnrichedSnapshot(for: page)

        XCTAssertEqual(secondMarks.count, 2)
        let carriedOver = secondMarks.first { $0.bbox.minY < 600 }
        let fresh = secondMarks.first { $0.bbox.minY >= 600 }
        XCTAssertEqual(carriedOver?.id, 1, "the unchanged mark must keep its id across pushes")
        XCTAssertEqual(fresh?.id, 2, "the new mark must get a fresh id")

        XCTAssertEqual(session.pushedImages.count, 2)
        XCTAssertEqual(session.pushedEvents.count, 2)
    }

    func testPushEnrichedSnapshotPushesLabeledImageAndRegistryJSON() async {
        let session = FakeTutorSession()
        let page = PageModel(role: .student)
        let coordinator = makeCoordinator(session: session, performer: FakeAnnotationPerformer(), page: page)

        page.drawing = drawing([CGPoint(x: 100, y: 500), CGPoint(x: 120, y: 510), CGPoint(x: 140, y: 500)])
        _ = await coordinator.pushEnrichedSnapshot(for: page)

        XCTAssertEqual(session.pushedImages.count, 1)
        XCTAssertFalse(session.pushedImages[0].isEmpty)
        XCTAssertEqual(session.pushedEvents.count, 1)
        XCTAssertTrue(session.pushedEvents[0].contains("\"page\":\"student\""))
        XCTAssertTrue(session.pushedEvents[0].contains("\"id\":1"))
    }

    // MARK: - 3. Page-rule enforcement

    func testCircleRendersOnResolvedMarkAndPushesMarkRendered() async {
        let session = FakeTutorSession()
        let performer = FakeAnnotationPerformer()
        let page = PageModel(role: .student)
        let coordinator = makeCoordinator(session: session, performer: performer, page: page)

        page.drawing = drawing([CGPoint(x: 100, y: 500), CGPoint(x: 120, y: 510), CGPoint(x: 140, y: 500)])
        _ = await coordinator.pushEnrichedSnapshot(for: page)

        await coordinator.dispatch(.circle(1))

        XCTAssertEqual(performer.calls.count, 1)
        XCTAssertEqual(performer.calls[0].page.id, page.id)
        if case .circle(let mark) = performer.calls[0].annotation {
            XCTAssertEqual(mark.id, 1)
        } else {
            XCTFail("expected .circle annotation")
        }
        XCTAssertTrue(session.pushedEvents.last?.contains("mark_rendered") ?? false)
        XCTAssertEqual(coordinator.journal.last?.event, .tagRendered(tag: "CIRCLE", markIds: [1]))
    }

    func testCircleWithUnknownMarkIdIsDroppedAndLogged() async {
        let session = FakeTutorSession()
        let performer = FakeAnnotationPerformer()
        let page = PageModel(role: .student)
        let coordinator = makeCoordinator(session: session, performer: performer, page: page)

        // No snapshot ever pushed -- no mark 99 exists in any registry.
        await coordinator.dispatch(.circle(99))

        XCTAssertTrue(performer.calls.isEmpty, "an unresolved mark id must never reach the performer")
        XCTAssertTrue(session.pushedEvents.isEmpty, "a dropped tag must not push a mark_rendered event")
        XCTAssertEqual(coordinator.journal.last?.event, .tagDropped(tag: "CIRCLE:99", reason: "unknown mark id"))
    }

    func testArrowWithBothMarksOnSamePageRenders() async {
        let session = FakeTutorSession()
        let performer = FakeAnnotationPerformer()
        let page = PageModel(role: .student)
        let coordinator = makeCoordinator(session: session, performer: performer, page: page)

        // Two well-separated strokes on the same line -> 2 marks (ids 1, 2).
        page.drawing = PKDrawing(strokes: [
            stroke(from: [CGPoint(x: 100, y: 500), CGPoint(x: 120, y: 510), CGPoint(x: 140, y: 500)]),
            stroke(from: [CGPoint(x: 220, y: 500), CGPoint(x: 240, y: 510), CGPoint(x: 260, y: 500)]),
        ])
        _ = await coordinator.pushEnrichedSnapshot(for: page)

        await coordinator.dispatch(.arrow(1, 2))

        XCTAssertEqual(performer.calls.count, 1)
        if case .arrow(let from, let to) = performer.calls[0].annotation {
            XCTAssertEqual(from.id, 1)
            XCTAssertEqual(to.id, 2)
        } else {
            XCTFail("expected .arrow annotation")
        }
    }

    func testArrowWithUnknownMarkDroppedAndLogged() async {
        let session = FakeTutorSession()
        let performer = FakeAnnotationPerformer()
        let page = PageModel(role: .student)
        let coordinator = makeCoordinator(session: session, performer: performer, page: page)

        page.drawing = drawing([CGPoint(x: 100, y: 500), CGPoint(x: 120, y: 510), CGPoint(x: 140, y: 500)])
        _ = await coordinator.pushEnrichedSnapshot(for: page)

        await coordinator.dispatch(.arrow(1, 99))

        XCTAssertTrue(performer.calls.isEmpty)
        XCTAssertEqual(coordinator.journal.last?.event, .tagDropped(tag: "ARROW:1>99", reason: "unknown mark id or cross-page pair"))
    }

    // MARK: - HIGHLIGHT: killed (Hugh, 2026-07-12 — "remove the highlighting
    // tool it looks ugly, pointing is better"). The parser still accepts it
    // so an in-flight session built against the old prompt doesn't crash;
    // it must never reach the performer.

    func testHighlightIsDroppedAndLogged() async {
        let session = FakeTutorSession()
        let performer = FakeAnnotationPerformer()
        let page = PageModel(role: .student)
        let coordinator = makeCoordinator(session: session, performer: performer, page: page)

        page.drawing = drawing([CGPoint(x: 100, y: 500), CGPoint(x: 120, y: 510), CGPoint(x: 140, y: 500)])
        _ = await coordinator.pushEnrichedSnapshot(for: page)

        await coordinator.dispatch(.highlight(1))

        XCTAssertTrue(performer.calls.isEmpty, "HIGHLIGHT must never reach the performer, even for a resolvable mark id")
        XCTAssertTrue(session.pushedEvents.count == 1, "only the snapshot push above, no mark_rendered for HIGHLIGHT")
        XCTAssertEqual(coordinator.journal.last?.event, .tagDropped(tag: "HIGHLIGHT:1", reason: "highlight tool removed"))
    }

    // MARK: - NEWPAGE: no-op (Hugh, 2026-07-12 — "remove the 'AI gets its
    // own page'"). The parser still accepts it; there's nothing left to open.

    func testNewPageIsNoOpAndLogged() async {
        let session = FakeTutorSession()
        let performer = FakeAnnotationPerformer()
        let page = PageModel(role: .student)
        let coordinator = makeCoordinator(session: session, performer: performer, page: page)

        await coordinator.dispatch(.newPage)

        XCTAssertTrue(performer.calls.isEmpty)
        XCTAssertTrue(session.pushedEvents.isEmpty)
        XCTAssertEqual(coordinator.journal.last?.event, .tagDropped(tag: "NEWPAGE", reason: "no-op — single shared canvas"))
    }

    func testWriteNeverInvokesAnnotationPerformer() async {
        // WRITE carries no page argument anywhere in this file -- there is
        // no code path through which it could reach `PageModel.drawing` on
        // the student page (or mutate anything via `performer`, whose only
        // job is the annotate-only primitives).
        let session = FakeTutorSession()
        let performer = FakeAnnotationPerformer()
        let page = PageModel(role: .student)
        let coordinator = makeCoordinator(session: session, performer: performer, page: page)

        await coordinator.dispatch(.write(latex: "x=1", anchor: .belowLast))

        XCTAssertTrue(performer.calls.isEmpty)
    }

    // MARK: - WRITE glyphs become addressable marks (own handwriting anchoring)

    func testWriteAppendsWrittenMarksAndPushesEnrichedSnapshot() async {
        let session = FakeTutorSession()
        let performer = FakeAnnotationPerformer()
        let page = PageModel(role: .student)
        let glyphs = [
            fakeGlyph("2", CGRect(x: 60, y: 80, width: 20, height: 30)),
            fakeGlyph("x", CGRect(x: 84, y: 80, width: 20, height: 30)),
        ]
        let coordinator = makeCoordinator(
            session: session, performer: performer, page: page,
            onWrite: { _, _ in glyphs }
        )

        await coordinator.dispatch(.write(latex: "2x", anchor: .belowLast))

        // dispatchWrite pushes its OWN enriched snapshot of the shared page
        // once the writer finishes -- distinct from the debounced push
        // CanvasView.Coordinator schedules off a PKCanvasView stroke, which
        // never fires here (nothing changed in any PKDrawing).
        XCTAssertEqual(session.pushedImages.count, 1)
        XCTAssertEqual(session.pushedEvents.count, 1)
        let json = session.pushedEvents[0]
        XCTAssertTrue(json.contains("\"page\":\"student\""))
        XCTAssertTrue(json.contains("\"id\":1"))
        XCTAssertTrue(json.contains("\"id\":2"))
        XCTAssertTrue(json.contains("\"written\":true"), "written marks must be tagged so the model can tell its own writing from the student's ink")
        XCTAssertEqual(coordinator.journal.last?.event, .snapshotPushed(page: "student", markCount: 2))
    }

    func testArrowBetweenTwoWrittenGlyphsDispatchesToPerformer() async {
        // The demo's distribution-arcs moment: ARROW from the "2" TutorWriter
        // itself just wrote to each term of "(x+5)" -- both endpoints are the
        // tutor's own handwriting, not student ink.
        let session = FakeTutorSession()
        let performer = FakeAnnotationPerformer()
        let page = PageModel(role: .student)
        let two = fakeGlyph("2", CGRect(x: 60, y: 80, width: 20, height: 30))
        let x = fakeGlyph("x", CGRect(x: 84, y: 80, width: 20, height: 30))
        let coordinator = makeCoordinator(
            session: session, performer: performer, page: page,
            onWrite: { _, _ in [two, x] }
        )

        await coordinator.dispatch(.write(latex: "2x", anchor: .belowLast))
        await coordinator.dispatch(.arrow(1, 2))

        XCTAssertEqual(performer.calls.count, 1)
        XCTAssertEqual(performer.calls[0].page.id, page.id, "an arrow between two written marks must dispatch on the shared page")
        if case .arrow(let from, let to) = performer.calls[0].annotation {
            XCTAssertEqual(from.bbox, two.frame)
            XCTAssertEqual(to.bbox, x.frame)
            XCTAssertTrue(from.written)
            XCTAssertTrue(to.written)
        } else {
            XCTFail("expected .arrow annotation")
        }
    }

    func testWrittenMarkIDsDoNotCollideWithInkMarksOnSharedPage() async {
        // The shared page can carry BOTH real ink (MarkRegistry.compute) and
        // written glyphs (appendWrittenMarks) -- they must share one ID
        // counter space so [CIRCLE:n] is never ambiguous between the two.
        let session = FakeTutorSession()
        let performer = FakeAnnotationPerformer()
        let page = PageModel(role: .student)
        let glyph = fakeGlyph("5", CGRect(x: 200, y: 200, width: 20, height: 30))
        let coordinator = makeCoordinator(
            session: session, performer: performer, page: page,
            onWrite: { _, _ in [glyph] }
        )

        // Ink first -- MarkRegistry's own counter hands it id 1.
        page.drawing = drawing([CGPoint(x: 100, y: 500), CGPoint(x: 120, y: 510), CGPoint(x: 140, y: 500)])
        let inkMarks = await coordinator.pushEnrichedSnapshot(for: page)
        XCTAssertEqual(inkMarks.map(\.id), [1])

        await coordinator.dispatch(.write(latex: "5", anchor: .belowLast))

        // id 2 (not 1) must resolve to the written glyph, proving the two
        // counters didn't collide.
        await coordinator.dispatch(.circle(2))

        XCTAssertEqual(performer.calls.count, 1)
        if case .circle(let mark) = performer.calls[0].annotation {
            XCTAssertEqual(mark.id, 2)
            XCTAssertTrue(mark.written)
            XCTAssertEqual(mark.bbox, glyph.frame)
        } else {
            XCTFail("expected .circle annotation")
        }
    }

    // MARK: - WRITE placement: directly beneath the student's own work
    // (Hugh, 2026-07-12 revision: "don't make it on the side; make it on
    // the user's actual canvas they're drawing on"). `onWrite` is the hook
    // — it receives the already-computed page-space origin.

    func testWriteBelowWorkAlignsWithInkLeftEdgeAndBottom() async {
        let session = FakeTutorSession()
        let performer = FakeAnnotationPerformer()
        let page = PageModel(role: .student)
        var capturedOrigins: [CGPoint] = []
        let coordinator = makeCoordinator(
            session: session, performer: performer, page: page,
            onWrite: { _, origin in capturedOrigins.append(origin); return [] }
        )

        page.drawing = drawing([CGPoint(x: 100, y: 500), CGPoint(x: 120, y: 510), CGPoint(x: 140, y: 500)])
        let marks = await coordinator.pushEnrichedSnapshot(for: page)
        guard let mark = marks.first else { return XCTFail("expected one mark") }

        await coordinator.dispatch(.write(latex: "x=1", anchor: .belowLast))

        XCTAssertEqual(capturedOrigins.count, 1)
        XCTAssertEqual(capturedOrigins[0].x, mark.bbox.minX, accuracy: 0.01, "x must align with the student's ink, not sit in a right-hand column")
        XCTAssertEqual(capturedOrigins[0].y, mark.bbox.maxY + 40, accuracy: 0.01, "y must sit ~40pt below the bottom of the student's work")
    }

    func testWriteWithNoInkUsesFallbackMargins() async {
        let session = FakeTutorSession()
        let performer = FakeAnnotationPerformer()
        let page = PageModel(role: .student)
        var capturedOrigins: [CGPoint] = []
        let coordinator = makeCoordinator(
            session: session, performer: performer, page: page,
            onWrite: { _, origin in capturedOrigins.append(origin); return [] }
        )

        await coordinator.dispatch(.write(latex: "x=1", anchor: .belowLast))

        XCTAssertEqual(capturedOrigins, [CGPoint(x: 60, y: 80)], "with no ink to align under, the first write must fall back to fixed margins")
    }

    func testSecondWriteStacksBelowFirstWritesBounds() async {
        let session = FakeTutorSession()
        let performer = FakeAnnotationPerformer()
        let page = PageModel(role: .student)
        let glyphs = [fakeGlyph("a", CGRect(x: 100, y: 80, width: 20, height: 30))]
        var capturedOrigins: [CGPoint] = []
        let coordinator = makeCoordinator(
            session: session, performer: performer, page: page,
            onWrite: { _, origin in capturedOrigins.append(origin); return glyphs }
        )

        await coordinator.dispatch(.write(latex: "a", anchor: .belowLast))
        await coordinator.dispatch(.write(latex: "b", anchor: .belowLast))

        XCTAssertEqual(capturedOrigins.count, 2)
        XCTAssertEqual(capturedOrigins[0], CGPoint(x: 60, y: 80))
        // lastWriteRect after the first write = the glyphs' union bounds
        // (maxY 110); the second write must stack 40pt below THAT, not
        // repeat the same fallback origin.
        XCTAssertEqual(capturedOrigins[1], CGPoint(x: 60, y: 150))
    }

    func testWriteReDerivesFromInkThatExtendsPastLastWriteRect() async {
        // The "never write ON or OVER the student's ink" law's teeth: if the
        // student writes further down AFTER the tutor's last write landed,
        // the next write must re-derive from their new bottommost mark, not
        // stack under a now-stale `lastWriteRect` and land on top of it.
        let session = FakeTutorSession()
        let performer = FakeAnnotationPerformer()
        let page = PageModel(role: .student)
        let glyphs = [fakeGlyph("a", CGRect(x: 100, y: 80, width: 20, height: 30))]
        var capturedOrigins: [CGPoint] = []
        let coordinator = makeCoordinator(
            session: session, performer: performer, page: page,
            onWrite: { _, origin in capturedOrigins.append(origin); return glyphs }
        )

        await coordinator.dispatch(.write(latex: "a", anchor: .belowLast)) // lastWriteRect maxY = 110

        page.drawing = drawing([CGPoint(x: 50, y: 400), CGPoint(x: 70, y: 410), CGPoint(x: 90, y: 400)])
        let marks = await coordinator.pushEnrichedSnapshot(for: page)
        guard let mark = marks.first else { return XCTFail("expected one mark") }

        await coordinator.dispatch(.write(latex: "b", anchor: .belowLast))

        XCTAssertEqual(capturedOrigins.count, 2)
        XCTAssertEqual(capturedOrigins[1].y, mark.bbox.maxY + 40, accuracy: 0.01)
        XCTAssertEqual(capturedOrigins[1].x, mark.bbox.minX, accuracy: 0.01)
    }

    func testWriteXClampsToMinimumLeftMargin() async {
        let session = FakeTutorSession()
        let performer = FakeAnnotationPerformer()
        let page = PageModel(role: .student)
        var capturedOrigins: [CGPoint] = []
        let coordinator = makeCoordinator(
            session: session, performer: performer, page: page,
            onWrite: { _, origin in capturedOrigins.append(origin); return [] }
        )

        // Ink starts almost flush with the page's left edge.
        page.drawing = drawing([CGPoint(x: 2, y: 200), CGPoint(x: 5, y: 205), CGPoint(x: 8, y: 200)])
        _ = await coordinator.pushEnrichedSnapshot(for: page)

        await coordinator.dispatch(.write(latex: "x=1", anchor: .belowLast))

        XCTAssertEqual(capturedOrigins[0].x, 20, "x must never clamp below the hard left margin, even if the ink starts right at the edge")
    }

    func testWriteXClampsWithinRightBuffer() async {
        let session = FakeTutorSession()
        let performer = FakeAnnotationPerformer()
        let page = PageModel(role: .student)
        var capturedOrigins: [CGPoint] = []
        let coordinator = makeCoordinator(
            session: session, performer: performer, page: page,
            onWrite: { _, origin in capturedOrigins.append(origin); return [] }
        )

        // Ink starts almost flush with the page's right edge (page width 768).
        page.drawing = drawing([CGPoint(x: 760, y: 200), CGPoint(x: 764, y: 205), CGPoint(x: 767, y: 200)])
        _ = await coordinator.pushEnrichedSnapshot(for: page)

        await coordinator.dispatch(.write(latex: "x=1", anchor: .belowLast))

        XCTAssertEqual(capturedOrigins[0].x, 668, "x must clamp so at least writeMinXBuffer stays free from the right edge")
    }

    func testWriteFallsBackToRightOverflowWhenVerticalSpaceExhausted() async {
        // Ink positioned so below-work placement would run the write past
        // the page's bottom margin (maxY + 40 > 984), but the ink's TOP
        // (minY) is still comfortably above that margin -- so
        // rightOverflowOrigin()'s "top of the most recent line" branch
        // resolves cleanly, without cascading into its own "start below
        // everything" sub-fallback (which a maxY much closer to minY, or
        // ink even further down the page, would trigger instead).
        //
        // Monotonic (strictly increasing x and y, no direction reversal) so
        // PencilKit's own path smoothing doesn't round off a cusp and pull
        // the bbox in from what the raw points suggest -- a zigzag/"hump"
        // stroke (up then back down) measurably does that (verified empirically:
        // an up-then-down triangle peaking at y=950 rendered a bbox.maxY of
        // only 935, ~15pt short of the raw peak).
        let session = FakeTutorSession()
        let performer = FakeAnnotationPerformer()
        let page = PageModel(role: .student)
        var capturedOrigins: [CGPoint] = []
        let coordinator = makeCoordinator(
            session: session, performer: performer, page: page,
            onWrite: { _, origin in capturedOrigins.append(origin); return [] }
        )

        page.drawing = drawing([CGPoint(x: 100, y: 900), CGPoint(x: 120, y: 940), CGPoint(x: 140, y: 975)])
        let marks = await coordinator.pushEnrichedSnapshot(for: page)
        guard let mark = marks.first else { return XCTFail("expected one mark") }
        XCTAssertGreaterThan(mark.bbox.maxY + 40, Self.testPageSize.height - 40, "test setup must actually exhaust vertical room below the work")
        XCTAssertLessThanOrEqual(mark.bbox.minY, Self.testPageSize.height - 40, "test setup must NOT also exhaust the fallback's own top-of-line position")

        await coordinator.dispatch(.write(latex: "x=1", anchor: .belowLast))

        let expectedX = max(mark.bbox.maxX + 32, Self.testPageSize.width * 0.5)
        XCTAssertEqual(capturedOrigins[0].x, expectedX, accuracy: 0.01)
        XCTAssertEqual(capturedOrigins[0].y, mark.bbox.minY, accuracy: 0.01, "fallback y aligns with the top of the student's most recent line")
    }

    // MARK: - SHAPE: promoted from stretch to fully rendered, same
    // below-work-first placement law as WRITE.

    func testShapeRendersOnSharedPageAndIsJournaled() async {
        let session = FakeTutorSession()
        let performer = FakeAnnotationPerformer()
        let page = PageModel(role: .student)
        let coordinator = makeCoordinator(session: session, performer: performer, page: page)

        await coordinator.dispatch(.shape(kind: "polygon", points: [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1)], label: "right triangle"))

        XCTAssertEqual(performer.calls.count, 1)
        XCTAssertEqual(performer.calls[0].page.id, page.id)
        guard case .shape(let kind, _, let label, _) = performer.calls[0].annotation else {
            return XCTFail("expected .shape annotation")
        }
        XCTAssertEqual(kind, "polygon")
        XCTAssertEqual(label, "right triangle")
        XCTAssertEqual(coordinator.journal.last?.event, .tagRendered(tag: "SHAPE:polygon", markIds: []))
    }

    func testShapeBelowWorkOriginMatchesInkLeftEdgeAndBottom() async {
        let session = FakeTutorSession()
        let performer = FakeAnnotationPerformer()
        let page = PageModel(role: .student)
        let coordinator = makeCoordinator(session: session, performer: performer, page: page)

        page.drawing = drawing([CGPoint(x: 100, y: 500), CGPoint(x: 120, y: 510), CGPoint(x: 140, y: 500)])
        let marks = await coordinator.pushEnrichedSnapshot(for: page)
        guard let mark = marks.first else { return XCTFail("expected one mark") }

        await coordinator.dispatch(.shape(kind: "line", points: [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)], label: ""))

        guard case .shape(_, _, _, let box) = performer.calls[0].annotation else {
            return XCTFail("expected .shape annotation")
        }
        XCTAssertEqual(box.minX, mark.bbox.minX, accuracy: 0.01)
        XCTAssertEqual(box.minY, mark.bbox.maxY + 40, accuracy: 0.01)
    }

    func testShapeFallsBackToRightHalfBoxWhenVerticalSpaceExhausted() async {
        let session = FakeTutorSession()
        let performer = FakeAnnotationPerformer()
        let page = PageModel(role: .student)
        let coordinator = makeCoordinator(session: session, performer: performer, page: page)

        page.drawing = drawing([CGPoint(x: 100, y: 990), CGPoint(x: 120, y: 995), CGPoint(x: 140, y: 990)])
        _ = await coordinator.pushEnrichedSnapshot(for: page)

        await coordinator.dispatch(.shape(kind: "line", points: [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)], label: ""))

        guard case .shape(_, _, _, let box) = performer.calls[0].annotation else {
            return XCTFail("expected .shape annotation")
        }
        XCTAssertEqual(box, RoughGeometry.shapeContentBox(pageSize: Self.testPageSize))
    }

    func testWriteAfterShapeStacksBelowShapesBox() async {
        // Proves `lastWriteRect` is shared between WRITE and SHAPE, not two
        // independent trackers -- a shape then a write back-to-back must
        // key off the SAME rect, not overlap.
        //
        // `nextShapeBox()` deliberately hands a below-work shape ALL the
        // remaining room down to the page's bottom margin (see its doc:
        // "sizing the box to whatever room remains"), so its `maxY` always
        // lands right at the page's exhaustion threshold -- which means the
        // very next write's `belowWorkOrigin()` is *always* exhausted
        // (`box.maxY + 40` necessarily overshoots the bottom margin) and
        // the write cascades into `rightOverflowOrigin()`'s "top of line"
        // slot instead. That's still `lastWriteRect`-driven placement (the
        // fallback's own `y = lastWriteRect.maxY + writeLineGap` reads the
        // SAME `box` this test captured), just via the fallback's formula
        // rather than `belowWorkOrigin()`'s -- proving the sharing without
        // asserting a below-work stack this particular production rule can
        // never actually produce right after a shape.
        let session = FakeTutorSession()
        let performer = FakeAnnotationPerformer()
        let page = PageModel(role: .student)
        var capturedOrigins: [CGPoint] = []
        let coordinator = makeCoordinator(
            session: session, performer: performer, page: page,
            onWrite: { _, origin in capturedOrigins.append(origin); return [] }
        )

        await coordinator.dispatch(.shape(kind: "line", points: [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)], label: ""))
        guard case .shape(_, _, _, let box) = performer.calls[0].annotation else {
            return XCTFail("expected .shape annotation")
        }

        await coordinator.dispatch(.write(latex: "x=1", anchor: .belowLast))

        XCTAssertEqual(capturedOrigins.count, 1)
        XCTAssertEqual(capturedOrigins[0].y, box.maxY + 24, accuracy: 0.01, "the write's y must still derive from the shape's box, via the right-overflow fallback's line gap")
        XCTAssertEqual(capturedOrigins[0].x, Self.testPageSize.width * 0.5, accuracy: 0.01)
    }

    // MARK: - WAIT / PLOT

    func testWaitIsLoggedAndNoOp() async {
        let session = FakeTutorSession()
        let performer = FakeAnnotationPerformer()
        let page = PageModel(role: .student)
        let coordinator = makeCoordinator(session: session, performer: performer, page: page)

        await coordinator.dispatch(.wait(5))

        XCTAssertTrue(performer.calls.isEmpty)
        XCTAssertTrue(session.pushedEvents.isEmpty)
        XCTAssertEqual(coordinator.journal.last?.event, .waited(seconds: 5))
    }

    func testPlotIsLoggedAndDropped() async {
        let session = FakeTutorSession()
        let performer = FakeAnnotationPerformer()
        let page = PageModel(role: .student)
        let coordinator = makeCoordinator(session: session, performer: performer, page: page)

        await coordinator.dispatch(.plot("y=sin(x)"))

        XCTAssertTrue(performer.calls.isEmpty)
        XCTAssertEqual(coordinator.journal.last?.event, .tagDropped(tag: "PLOT", reason: "renderer not implemented"))
    }

    // MARK: - 4. Journal cap + tag stripping

    func testJournalCapsAt50() async {
        let session = FakeTutorSession()
        let performer = FakeAnnotationPerformer()
        let page = PageModel(role: .student)
        let coordinator = makeCoordinator(session: session, performer: performer, page: page)

        for i in 1...60 {
            await coordinator.dispatch(.wait(i))
        }

        XCTAssertEqual(coordinator.journal.count, 50)
        // Newest-last: the last dispatched WAIT (60) must be the last entry.
        XCTAssertEqual(coordinator.journal.last?.event, .waited(seconds: 60))
        // The oldest 10 (1...10) must have fallen off the cap.
        XCTAssertEqual(coordinator.journal.first?.event, .waited(seconds: 11))
    }

    func testJournalJSONRoundTripsAndIsCapped() async {
        let session = FakeTutorSession()
        let performer = FakeAnnotationPerformer()
        let page = PageModel(role: .student)
        let coordinator = makeCoordinator(session: session, performer: performer, page: page)

        for i in 1...55 {
            await coordinator.dispatch(.wait(i))
        }

        let json = coordinator.journalJSON()
        let data = json.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try! decoder.decode([JournalEntry].self, from: data)
        XCTAssertEqual(decoded.count, 50)
        XCTAssertEqual(decoded.last?.event, .waited(seconds: 55))
    }

    func testStripTagsRemovesBracketedTag() {
        let result = TutorCoordinator.stripTags("hello [CIRCLE:1] world")
        XCTAssertEqual(result, "hello  world")
    }

    func testStripTagsLeavesPlainTextUntouched() {
        let result = TutorCoordinator.stripTags("nothing to strip here")
        XCTAssertEqual(result, "nothing to strip here")
    }

    // MARK: - 2. Transcript routing: full pipeline

    func testSubtitleStreamStripsTags() async {
        let session = FakeTutorSession()
        let performer = FakeAnnotationPerformer()
        let page = PageModel(role: .student)
        let coordinator = makeCoordinator(session: session, performer: performer, page: page)

        let stream = coordinator.subtitleStream
        coordinator.start()

        let collector = Task {
            var lines: [String] = []
            for await line in stream { lines.append(line) }
            return lines
        }

        session.sendDelta("so [CIRCLE:1] look here")
        session.finishTranscript()

        let lines = await collector.value
        coordinator.stop()

        XCTAssertEqual(lines.joined(), "so  look here", "the [CIRCLE:1] tag must never reach the subtitle stream")
    }

    func testTagsFedThroughTranscriptAreDispatched() async {
        let session = FakeTutorSession()
        let performer = FakeAnnotationPerformer()
        let page = PageModel(role: .student)
        let coordinator = makeCoordinator(session: session, performer: performer, page: page)

        page.drawing = drawing([CGPoint(x: 100, y: 500), CGPoint(x: 120, y: 510), CGPoint(x: 140, y: 500)])
        _ = await coordinator.pushEnrichedSnapshot(for: page)

        let stream = coordinator.subtitleStream
        coordinator.start()
        let collector = Task {
            var lines: [String] = []
            for await line in stream { lines.append(line) }
            return lines
        }

        session.sendDelta("look [CIRCLE:1] right there")
        session.finishTranscript()
        _ = await collector.value
        coordinator.stop()

        XCTAssertEqual(performer.calls.count, 1, "a tag delivered via the real transcript stream must reach the performer")
    }
}
