import SwiftUI
import PDFKit
import UIKit

/// App entry screen: the student's worksheet canvas, full-screen, plus the
/// tutor's popup page. Opens directly onto the canvas — no landing screen
/// (demo priority).
struct CanvasScreen: View {
    /// Page size in canvas points, origin top-left (Global Constraints).
    static let pageSize = CGSize(width: 768, height: 1024)

    @StateObject private var studentPage = PageModel(role: .student)
    @StateObject private var tutorPage = PageModel(role: .tutor)
    @State private var showTutorPage = false

    /// One shared realtime session for the whole screen — the voice bar
    /// drives it, and the student canvas pushes snapshots into it.
    private let session: TutorSession = RealtimeSession()
    /// Routes `TutorCoordinator`'s annotate calls to whichever page's
    /// `AnnotationOverlayView` matches, by `PageModel.role` (there's exactly
    /// one overlay per role in this screen, so role stands in for the
    /// identity check the coordinator's own wiring note describes). No
    /// dependency on `studentPage`/`tutorPage` themselves, so it can be a
    /// plain stored property (no init-ordering issue) and both pages'
    /// `PageCanvasRepresentable`s can register into it as soon as their
    /// overlays exist, independent of when `coordinator` itself is built.
    private let performer = TutorAnnotationPerformer()
    /// Bridges the coordinator's synchronous `writeHandler` to the tutor
    /// page's `TutorWriter`, which may not exist yet the instant a
    /// `[WRITE:...]` tag fires (see `TutorWriteRouter`'s doc comment).
    private let writeRouter = TutorWriteRouter()
    /// Built once, lazily, in `.onAppear` — `TutorCoordinator`'s
    /// `openTutorPage` closure needs to capture `self` to flip
    /// `showTutorPage`, which Swift only allows once this view's `init` has
    /// fully finished (definite-initialization rules forbid escaping `self`
    /// from inside `init` itself).
    @State private var coordinator: TutorCoordinator?

    var body: some View {
        ZStack {
            PageCanvasRepresentable(
                page: studentPage,
                pageSize: Self.pageSize,
                session: session,
                tutorCoordinator: coordinator,
                onOverlayReady: { performer.studentOverlay = $0 }
            )
            .ignoresSafeArea()

            VStack {
                HStack {
                    Spacer()
                    if let coordinator {
                        VoiceBarView(session: session, coordinator: coordinator)
                    }
                }
                Spacer()
            }
            .padding()

            // (Example button removed — the tutor popup opens via [NEWPAGE]
            // once the coordinator is wired; showTutorPage stays for that.)

            if showTutorPage, let coordinator {
                TutorPagePopup(
                    page: tutorPage,
                    pageSize: Self.pageSize,
                    isPresented: $showTutorPage,
                    coordinator: coordinator,
                    onOverlayReady: { performer.tutorOverlay = $0 },
                    onWriterReady: { writeRouter.attach(writer: $0) }
                )
            }
        }
        // PDF underlay disabled for now (Hugh, 2026-07-12): blank canvas, tutor
        // reads the ink alone. Re-enable by restoring this call.
        // .onAppear(perform: loadAssignmentPDF)
        .onAppear(perform: attachCoordinatorIfNeeded)
    }

    /// Wiring Step 1: the screen's one `TutorCoordinator`, built once. Not a
    /// stored-property default (`= TutorCoordinator(...)`) because
    /// `openTutorPage: { showTutorPage = true }` has to capture `self`,
    /// which can't happen inside this struct's own `init`.
    private func attachCoordinatorIfNeeded() {
        guard coordinator == nil else { return }
        coordinator = TutorCoordinator(
            session: session,
            studentPage: studentPage,
            tutorPage: tutorPage,
            pageSize: Self.pageSize,
            performer: performer,
            openTutorPage: { showTutorPage = true },
            writeHandler: { latex, anchor in await writeRouter.handle(latex: latex, anchor: anchor) },
            writtenLayerProvider: { writeRouter.contentLayer }
        )
    }

    /// Renders page 1 of the bundled worksheet into `studentPage.pdfImage`.
    /// Student page only — the tutor page never has a PDF underlay.
    private func loadAssignmentPDF() {
        guard studentPage.pdfImage == nil,
              // Real middle-school worksheet (Mashup Math, tutoring use permitted) —
              // swapped in over the generated assignment.pdf, which stays bundled as backup.
              let url = Bundle.main.url(forResource: "worksheet-equations-word-problems", withExtension: "pdf"),
              let document = PDFDocument(url: url),
              let pdfPage = document.page(at: 0) else { return }
        let thumbnailSize = CGSize(width: Self.pageSize.width * 2, height: Self.pageSize.height * 2)
        studentPage.pdfImage = pdfPage.thumbnail(of: thumbnailSize, for: .mediaBox)
    }
}

/// The tutor's page as a popup card over a dimmed scrim (Hugh, 2026-07-13:
/// don't take the student away from their work). Closeable anytime; the
/// PageModel survives dismissal so reopening restores the drawing.
private struct TutorPagePopup: View {
    @ObservedObject var page: PageModel
    let pageSize: CGSize
    @Binding var isPresented: Bool
    /// Wiring Step 6: both dismiss paths below tell the coordinator the
    /// popup closed, so `dispatchWrite`'s open-if-needed check stays
    /// accurate (the coordinator can't observe `@State showTutorPage`
    /// directly).
    let coordinator: TutorCoordinator
    var onOverlayReady: ((AnnotationOverlayView) -> Void)? = nil
    var onWriterReady: ((TutorWriter) -> Void)? = nil

    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture { dismiss() }

            GeometryReader { geo in
                let cardWidth = geo.size.width * 0.85
                let cardHeight = geo.size.height * 0.85

                VStack(spacing: 0) {
                    HStack {
                        Spacer()
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(8)
                    }
                    .background(.white)

                    PageCanvasRepresentable(
                        page: page,
                        pageSize: pageSize,
                        onOverlayReady: onOverlayReady,
                        onWriterReady: onWriterReady
                    )
                }
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .shadow(radius: 20)
                .frame(width: cardWidth, height: cardHeight)
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
        }
        .transition(.opacity)
    }

    private func dismiss() {
        isPresented = false
        coordinator.notifyTutorPageClosed()
    }
}

// MARK: - Wiring adapters (Task 7 wiring pass)

/// `AnnotationPerforming` adapter `TutorCoordinator` dispatches annotate
/// actions through (wiring Step 1/2). Routes by `PageModel.role` rather than
/// object identity — equivalent here since the screen only ever has one
/// student page and one tutor page, and it sidesteps needing either
/// `PageModel` at construction time, which would otherwise force this to be
/// built lazily alongside `coordinator` (see `CanvasScreen.coordinator`'s
/// doc comment) instead of as a plain, always-available stored property that
/// both pages' overlays can register into independent of coordinator timing.
@MainActor
private final class TutorAnnotationPerformer: AnnotationPerforming {
    weak var studentOverlay: AnnotationOverlayView?
    weak var tutorOverlay: AnnotationOverlayView?

    func perform(_ annotation: Annotation, on page: PageModel) {
        switch page.role {
        case .student: studentOverlay?.perform(annotation)
        case .tutor: tutorOverlay?.perform(annotation)
        }
    }
}

/// Bridges `TutorCoordinator`'s `writeHandler` closure to the tutor page's
/// `TutorWriter` (wiring Step 3). Two problems this solves that a direct
/// `{ latex, anchor in await writer.write(...) }` closure couldn't:
///
/// 1. **Timing:** `dispatchWrite` calls `openTutorPageIfNeeded()` then
///    `await writeHandler(...)` back to back — but `showTutorPage` flipping
///    true doesn't mount `TutorPagePopup`'s canvas (and therefore its
///    `TutorWriter`) until SwiftUI's next render pass. A `[WRITE:...]` that
///    opens the tutor page for the first time would otherwise hand a latex
///    string to a writer that doesn't exist yet. `handle` suspends (via a
///    buffered continuation) any write that arrives before `attach(writer:)`
///    fires, and resumes it, in order, once it does — instead of firing a
///    detached `Task` that `writeHandler`'s caller couldn't `await`, which
///    is what a synchronous `handle` had to do before `WriteHandler` became
///    `async`.
/// 2. **Anchoring:** this type owns the running `lastRect` (`.belowLast`'s
///    placement — see the doc comment on `write` below) across calls.
@MainActor
private final class TutorWriteRouter {
    private(set) weak var writer: TutorWriter?
    private var lastRect: CGRect?
    private var pending: [(latex: String, anchor: Anchor, continuation: CheckedContinuation<[TutorWriterLayout.GlyphPlacement], Never>)] = []

    /// The written glyph content, in page-point space — `TutorCoordinator`'s
    /// `writtenLayerProvider` reads this to composite the tutor's own
    /// handwriting into the tutor page's snapshot (`TutorWriter.contentLayer`'s
    /// doc comment). `nil` until `attach(writer:)` fires, same as `writer`.
    var contentLayer: CALayer? { writer?.contentLayer }

    /// Left margin + first line's top, and the vertical gap between
    /// consecutive writes — arbitrary layout constants (no spec'd values),
    /// chosen to sit comfortably inside `TutorPagePopup`'s card.
    private static let leftMargin: CGFloat = 60
    private static let topMargin: CGFloat = 80
    private static let lineHeight: CGFloat = 56
    private static let lineGap: CGFloat = 24

    func attach(writer: TutorWriter) {
        self.writer = writer
        let queued = pending
        pending.removeAll()
        for item in queued {
            Task { @MainActor in
                let placements = await self.write(latex: item.latex, anchor: item.anchor)
                item.continuation.resume(returning: placements)
            }
        }
    }

    /// Returns the written glyphs' placements (empty if latex failed to
    /// parse) once the write animation completes — matches `WriteHandler`'s
    /// contract exactly, so this can be handed to `TutorCoordinator` as-is.
    func handle(latex: String, anchor: Anchor) async -> [TutorWriterLayout.GlyphPlacement] {
        if writer == nil {
            return await withCheckedContinuation { continuation in
                pending.append((latex, anchor, continuation))
            }
        }
        return await write(latex: latex, anchor: anchor)
    }

    private func write(latex: String, anchor: Anchor) async -> [TutorWriterLayout.GlyphPlacement] {
        guard let writer else { return [] }
        let origin: CGPoint
        switch anchor {
        case .belowLast, .below(_):
            // `.below(id)` is spec'd as anchoring under a specific mark, but
            // that mark could be existing ink OR a past WRITE — and
            // `TutorWriter` doesn't track written equations by id (only the
            // aggregate bounds of each `write` call). Resolving a mark's
            // bbox lives on `TutorCoordinator` (`resolveMark`, private) and
            // isn't threaded through `writeHandler`'s two-argument contract.
            // Falling back to `.belowLast`'s placement is a documented
            // judgment call, not a spec'd behavior — same status as the
            // coordinator's own same-id-on-both-pages tiebreak.
            if let lastRect {
                origin = CGPoint(x: Self.leftMargin, y: lastRect.maxY + Self.lineGap)
            } else {
                origin = CGPoint(x: Self.leftMargin, y: Self.topMargin)
            }
        }
        let result = await writer.write(latex: latex, at: origin, height: Self.lineHeight)
        lastRect = result.bounds
        return result.placements
    }
}

#Preview {
    CanvasScreen()
}
