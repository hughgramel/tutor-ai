import Foundation
import UIKit

/// The integration glue between `TutorSession`, `MarkRegistry`, `TagParser`,
/// and the annotation renderer (plan Task 7, adapted). This file is
/// deliberately STANDALONE and UNWIRED: it is built against protocol seams
/// only and is never imported by any existing screen. It ships on its own
/// branch ahead of `voicebar-v2` (which is still reworking `CanvasScreen`/
/// `CanvasView`/`VoiceBarView`/`RealtimeSession`) so those files can land
/// without a merge conflict here; wiring `TutorCoordinator` in is a followup
/// pass once that branch is verified. See the bottom-of-file "Wiring" note
/// for the exact steps.
///
/// Nothing in this file references `CanvasScreen`, `CanvasView`,
/// `VoiceBarView`, or `RealtimeSession` by name — only `TutorSession`
/// (protocol), `PageModel` (already provider/UI-agnostic), and the two
/// closures/protocol declared below.

// MARK: - Protocol seams

/// Performs one of the four annotate-only visual actions
/// (`AnnotationOverlayView`'s `Annotation` enum) on a specific page. A
/// protocol rather than a bare closure because dispatch has to route to one
/// of *two* overlay instances (student page vs. the tutor's popup page) —
/// the concrete conformer, added at wiring time, is a thin adapter that
/// picks the right `AnnotationOverlayView.perform(_:)` by comparing `page`
/// against the screen's `studentPage`/`tutorPage`.
protocol AnnotationPerforming: AnyObject {
    func perform(_ annotation: Annotation, on page: PageModel)
}

/// `[WRITE:latex|anchor]` handler. `TutorWriter` (plan Task 11) is being
/// built in parallel by someone else — protocolled here as a closure so this
/// file compiles today and the real writer drops in with zero edits to this
/// file. No page parameter: WRITE is structurally always the tutor's own
/// page (see `dispatchWrite` below) — there is no wire representation for
/// "write on the student's page" for a handler to even receive.
typealias WriteHandler = (_ latex: String, _ anchor: Anchor) -> Void

/// Opens the tutor's popup page. At wiring time this is
/// `{ showTutorPage = true }` in `CanvasScreen`.
typealias OpenTutorPageHandler = () -> Void

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
    case tutorPageOpened
    case tutorPageClosed
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
    private let openTutorPageHandler: OpenTutorPageHandler
    private let writeHandler: WriteHandler

    init(
        session: TutorSession,
        studentPage: PageModel,
        tutorPage: PageModel,
        pageSize: CGSize,
        performer: AnnotationPerforming,
        openTutorPage: @escaping OpenTutorPageHandler,
        writeHandler: @escaping WriteHandler
    ) {
        self.session = session
        self.studentPage = studentPage
        self.tutorPage = tutorPage
        self.pageSize = pageSize
        self.performer = performer
        self.openTutorPageHandler = openTutorPage
        self.writeHandler = writeHandler
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

    /// Computes marks for `page.drawing`, renders + labels a snapshot, and
    /// pushes both the labeled JPEG and the registry JSON to the session.
    /// This is the ONE call the canvas layer should make per debounced
    /// stroke-end — it replaces the bare `session.pushImage(snapshot.jpeg)`
    /// call `CanvasView.Coordinator.pushSnapshotIfDue` makes today (that
    /// method already owns the debounce/min-interval/unchanged-drawing
    /// gating from the plan's image-context budget; only the "what do I
    /// push" step changes, not the "when").
    @discardableResult
    func pushEnrichedSnapshot(for page: PageModel) async -> [Mark] {
        let previous = currentMarks[page.id] ?? []
        let marks = MarkRegistry.compute(drawing: page.drawing, previous: previous)
        currentMarks[page.id] = marks

        let snapshot = SnapshotRenderer.render(page: page, pageSize: pageSize)
        let jpeg = labeledJpeg(from: snapshot, marks: marks)

        await session.pushImage(jpeg)
        await session.pushEvent(MarkRegistry.registryJSON(page: pageName(for: page), marks: marks))
        appendJournal(.snapshotPushed(page: pageName(for: page), markCount: marks.count))

        return marks
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
            await dispatchAnnotation(Annotation.highlight, tagName: "HIGHLIGHT", id: id)
        case .arrow(let from, let to):
            await dispatchArrow(fromID: from, toID: to)
        case .newPage:
            openTutorPageIfNeeded()
        case .write(let latex, let anchor):
            dispatchWrite(latex: latex, anchor: anchor)
        case .wait(let seconds):
            // No-op beyond logging — the client honors silence elsewhere
            // (suppressing client-triggered response.create calls is a
            // later task's job against the same TutorSession).
            TutorLog.shared.info("TutorCoordinator: WAIT \(seconds)s")
            appendJournal(.waited(seconds: seconds))
        case .plot(let expression):
            TutorLog.shared.info("TutorCoordinator: dropped PLOT (\(expression)) — renderer not implemented")
            appendJournal(.tagDropped(tag: "PLOT", reason: "renderer not implemented"))
        case .shape(let kind, _, _):
            TutorLog.shared.info("TutorCoordinator: dropped SHAPE:\(kind) — renderer not implemented")
            appendJournal(.tagDropped(tag: "SHAPE:\(kind)", reason: "renderer not implemented"))
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
    /// student-page ink wins the tie.
    private func resolveMark(id: Int) -> (mark: Mark, page: PageModel)? {
        if let mark = currentMarks[studentPage.id]?.first(where: { $0.id == id }) {
            return (mark, studentPage)
        }
        if let mark = currentMarks[tutorPage.id]?.first(where: { $0.id == id }) {
            return (mark, tutorPage)
        }
        return nil
    }

    /// WRITE is allowed ONLY on the tutor page — enforced structurally, not
    /// by a runtime check: `TutorTag.write` carries no page argument (there
    /// is no wire syntax for "write on the student's page"), and this
    /// method never takes a `PageModel` parameter either, so there is no
    /// code path through which a WRITE could reach the student page's
    /// drawing. If the tutor page isn't open yet, open it first, then
    /// write (never silently drop a WRITE just because NEWPAGE was
    /// skipped).
    private func dispatchWrite(latex: String, anchor: Anchor) {
        openTutorPageIfNeeded()
        writeHandler(latex, anchor)
        appendJournal(.wrote(latex: Self.stripTags(latex), anchor: describe(anchor)))
    }

    private func openTutorPageIfNeeded() {
        guard !isTutorPageOpenState else { return }
        isTutorPageOpenState = true
        openTutorPageHandler()
        appendJournal(.tutorPageOpened)
    }

    /// Call from wiring code when the popup's own close button / scrim tap
    /// dismisses it (the coordinator can't observe `CanvasScreen`'s
    /// `@State` directly), so `dispatchWrite`'s open-if-needed check stays
    /// accurate after a manual close.
    func notifyTutorPageClosed() {
        guard isTutorPageOpenState else { return }
        isTutorPageOpenState = false
        appendJournal(.tutorPageClosed)
    }

    private var isTutorPageOpenState = false

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

// MARK: - Wiring (for later, once voicebar-v2 is verified and merged)
//
// 1. `CanvasScreen` constructs one `TutorCoordinator` alongside its existing
//    `studentPage`/`tutorPage`/`session`, passing:
//      - `performer`: a small adapter conforming to `AnnotationPerforming`
//        that holds refs to the student page's and tutor page's
//        `AnnotationOverlayView` instances and picks the right one by
//        comparing `page.id` against `studentPage.id`/`tutorPage.id`.
//      - `openTutorPage`: `{ showTutorPage = true }`.
//      - `writeHandler`: `TutorWriter`'s `write(latex:anchor:)` once that
//        lands (Task 11); a no-op closure until then.
// 2. `CanvasView.Coordinator.pushSnapshotIfDue()` (`CanvasView.swift`
//    ~line 154) currently does
//    `let snapshot = SnapshotRenderer.render(...); await session.pushImage(snapshot.jpeg)`.
//    Replace those two lines with
//    `await coordinator.pushEnrichedSnapshot(for: page)` — the debounce/
//    min-interval/unchanged-drawing gating above it is unchanged.
// 3. `VoiceBarView.streamTranscript()` (`VoiceBarView.swift` ~line 182)
//    currently does `for await delta in session.transcriptDeltas`. Swap
//    that to `for await text in coordinator.subtitleStream` and call
//    `coordinator.start()` right after `session.connect()` succeeds
//    (`VoiceBarView.connect()`, alongside the existing
//    `connection = .live` assignment) instead of feeding raw deltas to
//    `appendTranscriptDelta` — the stripped text already IS the line to
//    append, no further parsing needed at that call site.
// 4. `TutorPagePopup`'s close actions (`CanvasScreen.swift`: the X button
//    and the scrim tap gesture, both `isPresented = false`) should also
//    call `coordinator.notifyTutorPageClosed()` so `dispatchWrite`'s
//    open-if-needed check stays accurate after a manual close.
//
// Protocol mismatch found against the current `TutorSession` shape: none —
// `pushImage`/`pushEvent`/`transcriptDeltas` line up with this file's needs
// exactly as declared in `TutorSession.swift`.
