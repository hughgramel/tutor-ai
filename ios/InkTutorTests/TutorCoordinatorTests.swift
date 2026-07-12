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

    private func makeCoordinator(
        session: TutorSession,
        performer: AnnotationPerforming,
        studentPage: PageModel,
        tutorPage: PageModel,
        onOpenTutorPage: @escaping () -> Void = {},
        onWrite: @escaping (String, Anchor) async -> [TutorWriterLayout.GlyphPlacement] = { _, _ in [] },
        writtenLayer: @escaping () -> CALayer? = { nil }
    ) -> TutorCoordinator {
        TutorCoordinator(
            session: session,
            studentPage: studentPage,
            tutorPage: tutorPage,
            pageSize: CGSize(width: 768, height: 1024),
            performer: performer,
            openTutorPage: onOpenTutorPage,
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
        let studentPage = PageModel(role: .student)
        let tutorPage = PageModel(role: .tutor)
        let coordinator = makeCoordinator(session: session, performer: FakeAnnotationPerformer(), studentPage: studentPage, tutorPage: tutorPage)

        studentPage.drawing = drawing([CGPoint(x: 100, y: 500), CGPoint(x: 120, y: 510), CGPoint(x: 140, y: 500)])
        let firstMarks = await coordinator.pushEnrichedSnapshot(for: studentPage)
        XCTAssertEqual(firstMarks.count, 1)
        XCTAssertEqual(firstMarks[0].id, 1)

        // Add a second, far-away stroke (different line) — the first
        // mark's bbox is unchanged, so it must keep id 1; the new one gets
        // a fresh id.
        studentPage.drawing = PKDrawing(strokes: [
            stroke(from: [CGPoint(x: 100, y: 500), CGPoint(x: 120, y: 510), CGPoint(x: 140, y: 500)]),
            stroke(from: [CGPoint(x: 100, y: 700), CGPoint(x: 120, y: 710), CGPoint(x: 140, y: 700)]),
        ])
        let secondMarks = await coordinator.pushEnrichedSnapshot(for: studentPage)

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
        let studentPage = PageModel(role: .student)
        let tutorPage = PageModel(role: .tutor)
        let coordinator = makeCoordinator(session: session, performer: FakeAnnotationPerformer(), studentPage: studentPage, tutorPage: tutorPage)

        studentPage.drawing = drawing([CGPoint(x: 100, y: 500), CGPoint(x: 120, y: 510), CGPoint(x: 140, y: 500)])
        _ = await coordinator.pushEnrichedSnapshot(for: studentPage)

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
        let studentPage = PageModel(role: .student)
        let tutorPage = PageModel(role: .tutor)
        let coordinator = makeCoordinator(session: session, performer: performer, studentPage: studentPage, tutorPage: tutorPage)

        studentPage.drawing = drawing([CGPoint(x: 100, y: 500), CGPoint(x: 120, y: 510), CGPoint(x: 140, y: 500)])
        _ = await coordinator.pushEnrichedSnapshot(for: studentPage)

        await coordinator.dispatch(.circle(1))

        XCTAssertEqual(performer.calls.count, 1)
        XCTAssertEqual(performer.calls[0].page.id, studentPage.id)
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
        let studentPage = PageModel(role: .student)
        let tutorPage = PageModel(role: .tutor)
        let coordinator = makeCoordinator(session: session, performer: performer, studentPage: studentPage, tutorPage: tutorPage)

        // No snapshot ever pushed -- no mark 99 exists in any registry.
        await coordinator.dispatch(.circle(99))

        XCTAssertTrue(performer.calls.isEmpty, "an unresolved mark id must never reach the performer")
        XCTAssertTrue(session.pushedEvents.isEmpty, "a dropped tag must not push a mark_rendered event")
        XCTAssertEqual(coordinator.journal.last?.event, .tagDropped(tag: "CIRCLE:99", reason: "unknown mark id"))
    }

    func testArrowWithBothMarksOnSamePageRenders() async {
        let session = FakeTutorSession()
        let performer = FakeAnnotationPerformer()
        let studentPage = PageModel(role: .student)
        let tutorPage = PageModel(role: .tutor)
        let coordinator = makeCoordinator(session: session, performer: performer, studentPage: studentPage, tutorPage: tutorPage)

        // Two well-separated strokes on the same line -> 2 marks (ids 1, 2).
        studentPage.drawing = PKDrawing(strokes: [
            stroke(from: [CGPoint(x: 100, y: 500), CGPoint(x: 120, y: 510), CGPoint(x: 140, y: 500)]),
            stroke(from: [CGPoint(x: 220, y: 500), CGPoint(x: 240, y: 510), CGPoint(x: 260, y: 500)]),
        ])
        _ = await coordinator.pushEnrichedSnapshot(for: studentPage)

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
        let studentPage = PageModel(role: .student)
        let tutorPage = PageModel(role: .tutor)
        let coordinator = makeCoordinator(session: session, performer: performer, studentPage: studentPage, tutorPage: tutorPage)

        studentPage.drawing = drawing([CGPoint(x: 100, y: 500), CGPoint(x: 120, y: 510), CGPoint(x: 140, y: 500)])
        _ = await coordinator.pushEnrichedSnapshot(for: studentPage)

        await coordinator.dispatch(.arrow(1, 99))

        XCTAssertTrue(performer.calls.isEmpty)
        XCTAssertEqual(coordinator.journal.last?.event, .tagDropped(tag: "ARROW:1>99", reason: "unknown mark id or cross-page pair"))
    }

    func testWriteOpensTutorPageWhenClosedThenWrites() async {
        let session = FakeTutorSession()
        let performer = FakeAnnotationPerformer()
        let studentPage = PageModel(role: .student)
        let tutorPage = PageModel(role: .tutor)
        var openCount = 0
        var writeCalls: [(String, Anchor)] = []
        let coordinator = makeCoordinator(
            session: session, performer: performer, studentPage: studentPage, tutorPage: tutorPage,
            onOpenTutorPage: { openCount += 1 },
            onWrite: { latex, anchor in writeCalls.append((latex, anchor)); return [] }
        )

        await coordinator.dispatch(.write(latex: "x=1", anchor: .belowLast))

        XCTAssertEqual(openCount, 1, "the tutor page must be opened before writing when it wasn't already")
        XCTAssertEqual(writeCalls.count, 1)
        XCTAssertEqual(writeCalls[0].0, "x=1")
        XCTAssertEqual(writeCalls[0].1, .belowLast)
        XCTAssertEqual(coordinator.journal.map(\.event), [.tutorPageOpened, .wrote(latex: "x=1", anchor: "below:last")], "open must be journaled before write")
    }

    func testWriteWhenTutorPageAlreadyOpenDoesNotReopen() async {
        let session = FakeTutorSession()
        let performer = FakeAnnotationPerformer()
        let studentPage = PageModel(role: .student)
        let tutorPage = PageModel(role: .tutor)
        var openCount = 0
        let coordinator = makeCoordinator(
            session: session, performer: performer, studentPage: studentPage, tutorPage: tutorPage,
            onOpenTutorPage: { openCount += 1 }
        )

        await coordinator.dispatch(.newPage)
        await coordinator.dispatch(.write(latex: "x=2", anchor: .below(3)))

        XCTAssertEqual(openCount, 1, "already-open tutor page must not be reopened")
    }

    func testWriteNeverInvokesAnnotationPerformer() async {
        // WRITE carries no page argument anywhere in this file -- there is
        // no code path through which it could reach `PageModel.drawing` on
        // the student page (or mutate anything via `performer`, whose only
        // job is the four annotate-only primitives).
        let session = FakeTutorSession()
        let performer = FakeAnnotationPerformer()
        let studentPage = PageModel(role: .student)
        let tutorPage = PageModel(role: .tutor)
        let coordinator = makeCoordinator(session: session, performer: performer, studentPage: studentPage, tutorPage: tutorPage)

        await coordinator.dispatch(.write(latex: "x=1", anchor: .belowLast))

        XCTAssertTrue(performer.calls.isEmpty)
    }

    // MARK: - WRITE glyphs become addressable marks (own handwriting anchoring)

    func testWriteAppendsWrittenMarksAndPushesEnrichedTutorSnapshot() async {
        let session = FakeTutorSession()
        let performer = FakeAnnotationPerformer()
        let studentPage = PageModel(role: .student)
        let tutorPage = PageModel(role: .tutor)
        let glyphs = [
            fakeGlyph("2", CGRect(x: 60, y: 80, width: 20, height: 30)),
            fakeGlyph("x", CGRect(x: 84, y: 80, width: 20, height: 30)),
        ]
        let coordinator = makeCoordinator(
            session: session, performer: performer, studentPage: studentPage, tutorPage: tutorPage,
            onWrite: { _, _ in glyphs }
        )

        await coordinator.dispatch(.write(latex: "2x", anchor: .belowLast))

        // dispatchWrite pushes its OWN enriched snapshot of the tutor page
        // once the writer finishes -- distinct from the debounced push
        // CanvasView.Coordinator schedules off a PKCanvasView stroke, which
        // never fires here (nothing changed in any PKDrawing).
        XCTAssertEqual(session.pushedImages.count, 1)
        XCTAssertEqual(session.pushedEvents.count, 1)
        let json = session.pushedEvents[0]
        XCTAssertTrue(json.contains("\"page\":\"tutor\""))
        XCTAssertTrue(json.contains("\"id\":1"))
        XCTAssertTrue(json.contains("\"id\":2"))
        XCTAssertTrue(json.contains("\"written\":true"), "written marks must be tagged so the model can tell its own writing from the student's ink")
        XCTAssertEqual(coordinator.journal.last?.event, .snapshotPushed(page: "tutor", markCount: 2))
    }

    func testArrowBetweenTwoWrittenGlyphsDispatchesToPerformer() async {
        // The demo's distribution-arcs moment: ARROW from the "2" TutorWriter
        // itself just wrote to each term of "(x+5)" -- both endpoints are the
        // tutor's own handwriting, not student ink.
        let session = FakeTutorSession()
        let performer = FakeAnnotationPerformer()
        let studentPage = PageModel(role: .student)
        let tutorPage = PageModel(role: .tutor)
        let two = fakeGlyph("2", CGRect(x: 60, y: 80, width: 20, height: 30))
        let x = fakeGlyph("x", CGRect(x: 84, y: 80, width: 20, height: 30))
        let coordinator = makeCoordinator(
            session: session, performer: performer, studentPage: studentPage, tutorPage: tutorPage,
            onWrite: { _, _ in [two, x] }
        )

        await coordinator.dispatch(.write(latex: "2x", anchor: .belowLast))
        await coordinator.dispatch(.arrow(1, 2))

        XCTAssertEqual(performer.calls.count, 1)
        XCTAssertEqual(performer.calls[0].page.id, tutorPage.id, "an arrow between two written marks must dispatch on the tutor page")
        if case .arrow(let from, let to) = performer.calls[0].annotation {
            XCTAssertEqual(from.bbox, two.frame)
            XCTAssertEqual(to.bbox, x.frame)
            XCTAssertTrue(from.written)
            XCTAssertTrue(to.written)
        } else {
            XCTFail("expected .arrow annotation")
        }
    }

    func testWrittenMarkIDsDoNotCollideWithInkMarksOnTutorPage() async {
        // The tutor page can carry BOTH real ink (MarkRegistry.compute) and
        // written glyphs (appendWrittenMarks) -- they must share one ID
        // counter space so [CIRCLE:n] is never ambiguous between the two.
        let session = FakeTutorSession()
        let performer = FakeAnnotationPerformer()
        let studentPage = PageModel(role: .student)
        let tutorPage = PageModel(role: .tutor)
        let glyph = fakeGlyph("5", CGRect(x: 200, y: 200, width: 20, height: 30))
        let coordinator = makeCoordinator(
            session: session, performer: performer, studentPage: studentPage, tutorPage: tutorPage,
            onWrite: { _, _ in [glyph] }
        )

        // Ink first -- MarkRegistry's own counter hands it id 1.
        tutorPage.drawing = drawing([CGPoint(x: 100, y: 500), CGPoint(x: 120, y: 510), CGPoint(x: 140, y: 500)])
        let inkMarks = await coordinator.pushEnrichedSnapshot(for: tutorPage)
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

    func testWaitIsLoggedAndNoOp() async {
        let session = FakeTutorSession()
        let performer = FakeAnnotationPerformer()
        let studentPage = PageModel(role: .student)
        let tutorPage = PageModel(role: .tutor)
        let coordinator = makeCoordinator(session: session, performer: performer, studentPage: studentPage, tutorPage: tutorPage)

        await coordinator.dispatch(.wait(5))

        XCTAssertTrue(performer.calls.isEmpty)
        XCTAssertTrue(session.pushedEvents.isEmpty)
        XCTAssertEqual(coordinator.journal.last?.event, .waited(seconds: 5))
    }

    func testPlotAndShapeAreLoggedAndDropped() async {
        let session = FakeTutorSession()
        let performer = FakeAnnotationPerformer()
        let studentPage = PageModel(role: .student)
        let tutorPage = PageModel(role: .tutor)
        let coordinator = makeCoordinator(session: session, performer: performer, studentPage: studentPage, tutorPage: tutorPage)

        await coordinator.dispatch(.plot("y=sin(x)"))
        await coordinator.dispatch(.shape(kind: "circle", points: [], label: "the region"))

        XCTAssertTrue(performer.calls.isEmpty)
        XCTAssertEqual(coordinator.journal.map(\.event), [
            .tagDropped(tag: "PLOT", reason: "renderer not implemented"),
            .tagDropped(tag: "SHAPE:circle", reason: "renderer not implemented"),
        ])
    }

    // MARK: - 4. Journal cap + tag stripping

    func testJournalCapsAt50() async {
        let session = FakeTutorSession()
        let performer = FakeAnnotationPerformer()
        let studentPage = PageModel(role: .student)
        let tutorPage = PageModel(role: .tutor)
        let coordinator = makeCoordinator(session: session, performer: performer, studentPage: studentPage, tutorPage: tutorPage)

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
        let studentPage = PageModel(role: .student)
        let tutorPage = PageModel(role: .tutor)
        let coordinator = makeCoordinator(session: session, performer: performer, studentPage: studentPage, tutorPage: tutorPage)

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

    func testNotifyTutorPageClosedJournalsAndAllowsReopen() async {
        let session = FakeTutorSession()
        let performer = FakeAnnotationPerformer()
        let studentPage = PageModel(role: .student)
        let tutorPage = PageModel(role: .tutor)
        var openCount = 0
        let coordinator = makeCoordinator(
            session: session, performer: performer, studentPage: studentPage, tutorPage: tutorPage,
            onOpenTutorPage: { openCount += 1 }
        )

        await coordinator.dispatch(.newPage)
        coordinator.notifyTutorPageClosed()
        await coordinator.dispatch(.write(latex: "x=1", anchor: .belowLast))

        XCTAssertEqual(openCount, 2, "closing then writing must reopen the tutor page")
        XCTAssertEqual(coordinator.journal.map(\.event), [
            .tutorPageOpened,
            .tutorPageClosed,
            .tutorPageOpened,
            .wrote(latex: "x=1", anchor: "below:last"),
        ])
    }

    // MARK: - 2. Transcript routing: full pipeline

    func testSubtitleStreamStripsTags() async {
        let session = FakeTutorSession()
        let performer = FakeAnnotationPerformer()
        let studentPage = PageModel(role: .student)
        let tutorPage = PageModel(role: .tutor)
        let coordinator = makeCoordinator(session: session, performer: performer, studentPage: studentPage, tutorPage: tutorPage)

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
        let studentPage = PageModel(role: .student)
        let tutorPage = PageModel(role: .tutor)
        let coordinator = makeCoordinator(session: session, performer: performer, studentPage: studentPage, tutorPage: tutorPage)

        studentPage.drawing = drawing([CGPoint(x: 100, y: 500), CGPoint(x: 120, y: 510), CGPoint(x: 140, y: 500)])
        _ = await coordinator.pushEnrichedSnapshot(for: studentPage)

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
