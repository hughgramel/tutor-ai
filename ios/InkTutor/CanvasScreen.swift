import SwiftUI
import UIKit
import PDFKit

/// App entry screen: one full-bleed student worksheet canvas. Opens directly
/// onto the canvas — no landing screen (demo priority).
///
/// Pivot (Hugh, 2026-07-12: "remove the 'AI gets its own page', we can just
/// work on the right alongside the user"): there used to be a second
/// `PageModel` for a tutor side panel/popup page. That's gone — the tutor
/// annotates and writes directly onto the student's own page, in the open
/// space to the right of their ink (`TutorCoordinator.nextWriteOrigin()`
/// owns that placement law). `studentPage` is handed to `TutorCoordinator`
/// as BOTH its `studentPage` and `tutorPage` arguments (see that file's
/// header comment) so its internal `.id`-keyed logic collapses onto one
/// page for free.
struct CanvasScreen: View {
    /// Page size in canvas points, origin top-left (Global Constraints).
    static let pageSize = CGSize(width: 768, height: 1024)

    @StateObject private var studentPage = PageModel(role: .student)

    /// One shared realtime session for the whole screen — the voice bar
    /// drives it, and the student canvas pushes snapshots into it.
    private let session: TutorSession = RealtimeSession()
    /// Routes `TutorCoordinator`'s annotate calls to the one page's
    /// `AnnotationOverlayView`. A plain stored property (no init-ordering
    /// issue), so the canvas's `onOverlayReady` can register into it
    /// independent of when `coordinator` itself is built.
    private let performer = TutorAnnotationPerformer()
    /// Bridges the coordinator's `writeHandler` closure to the page's
    /// `TutorWriter`.
    private let writeRouter = TutorWriteRouter()
    /// Built once, lazily, in `.onAppear` — mirrors the previous
    /// `openTutorPage`-must-capture-`self` constraint even though that
    /// closure is gone now, so this stays consistent with
    /// `attachCoordinatorIfNeeded`'s definite-initialization timing.
    @State private var coordinator: TutorCoordinator?

    var body: some View {
        ZStack {
            PageCanvasRepresentable(
                page: studentPage,
                pageSize: Self.pageSize,
                session: session,
                tutorCoordinator: coordinator,
                onOverlayReady: { performer.overlay = $0 },
                onWriterReady: { writeRouter.attach(writer: $0) }
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
        }
        // PDF underlay disabled for now (Hugh, 2026-07-12): blank canvas, tutor
        // reads the ink alone. Re-enable by restoring this call.
        // .onAppear(perform: loadAssignmentPDF)
        .onAppear(perform: attachCoordinatorIfNeeded)
    }

    /// Wiring Step 1: the screen's one `TutorCoordinator`, built once. Not a
    /// stored-property default (`= TutorCoordinator(...)`) so it stays
    /// consistent with the view's other `.onAppear`-timed setup.
    private func attachCoordinatorIfNeeded() {
        guard coordinator == nil else { return }
        coordinator = TutorCoordinator(
            session: session,
            studentPage: studentPage,
            tutorPage: studentPage,
            pageSize: Self.pageSize,
            performer: performer,
            writeHandler: { latex, origin in await writeRouter.handle(latex: latex, origin: origin) },
            writtenLayerProvider: { writeRouter.contentLayer }
        )
    }

    /// Renders page 1 of the bundled worksheet into `studentPage.pdfImage`.
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

// MARK: - Wiring adapters (Task 7 wiring pass)

/// `AnnotationPerforming` adapter `TutorCoordinator` dispatches annotate
/// actions through (wiring Step 1/2). One overlay now that there's one page
/// — kept as its own small type rather than inlined so `TutorCoordinator`
/// doesn't need to know about `AnnotationOverlayView` directly.
@MainActor
private final class TutorAnnotationPerformer: AnnotationPerforming {
    weak var overlay: AnnotationOverlayView?

    func perform(_ annotation: Annotation, on page: PageModel) {
        overlay?.perform(annotation)
    }
}

/// Bridges `TutorCoordinator`'s `writeHandler` closure to the page's
/// `TutorWriter` (wiring Step 3). Placement is no longer this type's
/// problem — `TutorCoordinator.nextWriteOrigin()` computes the origin
/// (right of the student's ink, stacked below the last write) and hands it
/// down as a plain `CGPoint`; this type's only job is calling
/// `TutorWriter.write(latex:at:height:)` with it.
///
/// No pending-write buffer (Hugh's pivot removed the popup-mount delay this
/// used to paper over): the one canvas — and its `TutorWriter` — mounts at
/// launch, well before a voice session can connect and a `[WRITE:...]` tag
/// can fire, so `writer` is always set by the time `handle` is called. If
/// that assumption ever breaks, `handle` drops the write and logs instead of
/// hanging.
@MainActor
private final class TutorWriteRouter {
    private(set) weak var writer: TutorWriter?

    /// The written glyph content, in page-point space — `TutorCoordinator`'s
    /// `writtenLayerProvider` reads this to composite the tutor's own
    /// handwriting into the shared page's snapshot (`TutorWriter.contentLayer`'s
    /// doc comment). `nil` until `attach(writer:)` fires, same as `writer`.
    var contentLayer: CALayer? { writer?.contentLayer }

    /// Line height passed to `TutorWriter.write(latex:at:height:)` — no
    /// spec'd value, chosen to match the previous popup-card layout.
    private static let lineHeight: CGFloat = 56

    func attach(writer: TutorWriter) {
        self.writer = writer
    }

    /// Returns the written glyphs' placements (empty if latex failed to
    /// parse, or if no writer is attached yet) — matches `WriteHandler`'s
    /// contract exactly, so this can be handed to `TutorCoordinator` as-is.
    func handle(latex: String, origin: CGPoint) async -> [TutorWriterLayout.GlyphPlacement] {
        guard let writer else {
            TutorLog.shared.info("TutorWriteRouter: WRITE arrived before writer was ready — dropped")
            return []
        }
        let result = await writer.write(latex: latex, at: origin, height: Self.lineHeight)
        return result.placements
    }
}

#Preview {
    CanvasScreen()
}
