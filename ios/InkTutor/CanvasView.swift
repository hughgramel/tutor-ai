import SwiftUI
import PencilKit

/// One page's PencilKit canvas: white paper, optional PDF underlay, native
/// pinch-zoom (PKCanvasView IS a UIScrollView, no wrapper needed), tool
/// picker. Used for both the student page and the tutor popup page.
///
/// The PDF underlay is a sibling view *outside* the scroll view's ownmoo
/// content, manually kept in sync with the canvas's contentOffset/zoomScale
/// via UIScrollViewDelegate callbacks — this is the pattern Apple's own
/// PencilKit sample uses for backgrounds, and it's what lets an
/// AnnotationOverlayView (Task 9) track ink at any zoom level too.
struct PageCanvasRepresentable: UIViewRepresentable {
    @ObservedObject var page: PageModel
    let pageSize: CGSize
    /// Snapshot pushes (Task 12, student page only for now) — nil for the
    /// tutor's own popup page, which has nothing to push yet.
    var session: TutorSession? = nil
    /// The coordinator that turns a debounced stroke-end into an enriched
    /// (labeled + registry JSON) snapshot push — student page only, same
    /// gate as `session` above (wiring Step 4).
    var tutorCoordinator: TutorCoordinator? = nil
    /// Reports the page's `AnnotationOverlayView` once `makeUIView` creates
    /// it, so `CanvasScreen` can hand it to the `AnnotationPerforming`
    /// adapter it passes into `TutorCoordinator` (wiring Step 2). Called on
    /// every page's canvas — annotate actions can land on either page's ink.
    var onOverlayReady: ((AnnotationOverlayView) -> Void)? = nil
    /// Reports the page's `TutorWriter` once `makeUIView` creates it —
    /// tutor page only (wiring Step 3).
    var onWriterReady: ((TutorWriter) -> Void)? = nil

    static var drawingPolicy: PKCanvasViewDrawingPolicy {
        #if targetEnvironment(simulator)
        // Apple Pencil doesn't exist in the simulator; allow finger/mouse input so this is testable.
        return .anyInput
        #else
        return .pencilOnly
        #endif
    }

    func makeUIView(context: Context) -> UIView {
        let container = CanvasContainerView()
        container.backgroundColor = .systemGray4 // area outside the page, off-canvas
        container.overrideUserInterfaceStyle = .light

        // White paper + PDF image live together as one sibling "underlay" view,
        // resized/repositioned to mirror the canvas's scroll/zoom.
        let paperView = UIView()
        paperView.backgroundColor = .white
        paperView.frame = CGRect(origin: .zero, size: pageSize)
        container.addSubview(paperView)

        let pdfImageView = UIImageView(image: page.pdfImage)
        pdfImageView.contentMode = .scaleToFill
        pdfImageView.frame = paperView.bounds
        pdfImageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        paperView.addSubview(pdfImageView)

        let canvasView = PKCanvasView()
        canvasView.overrideUserInterfaceStyle = .light
        canvasView.drawingPolicy = Self.drawingPolicy
        canvasView.backgroundColor = .clear // paper shows through from the sibling underlay
        canvasView.minimumZoomScale = 0.5
        canvasView.maximumZoomScale = 4.0
        canvasView.contentSize = pageSize
        // Default tool BEFORE the tool picker attaches.
        canvasView.tool = PKInkingTool(.pen, color: .black, width: 3)
        canvasView.drawing = page.drawing
        canvasView.delegate = context.coordinator // also receives UIScrollViewDelegate callbacks
        canvasView.frame = container.bounds
        canvasView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(canvasView)

        // Annotation overlay: sibling ABOVE the canvas (added after it, so it
        // draws on top), non-interactive, tracked to zoom/scroll the same way
        // `paperView` is below (`syncUnderlay`/`setZoom`). Exists on both
        // pages — CIRCLE/UNDERLINE/ARROW/HIGHLIGHT can land on either page's
        // ink (wiring Step 2).
        let overlay = AnnotationOverlayView(pageSize: pageSize)
        container.addSubview(overlay)
        context.coordinator.overlay = overlay

        // TutorWriter: tutor page only (WRITE is structurally always the
        // tutor's own page — wiring Step 3). `TutorWriter.init(overlayOn:)`
        // infers its page size from the host view's *current* bounds, so it
        // has to be built against `paperView` (already sized to `pageSize`
        // at this point) rather than `container` (still zero-sized pre-
        // layout) — then re-homed into `container` so its own `setZoom`
        // (identical convention to `AnnotationOverlayView`'s) positions it
        // in the same coordinate space as the overlay above.
        var writer: TutorWriter?
        if page.role == .tutor {
            let w = TutorWriter(overlayOn: paperView)
            w.removeFromSuperview()
            container.addSubview(w)
            writer = w
            context.coordinator.writer = w
        }

        let picker = PKToolPicker()
        picker.setVisible(true, forFirstResponder: canvasView)
        picker.addObserver(canvasView)
        canvasView.becomeFirstResponder()

        context.coordinator.page = page
        context.coordinator.paperView = paperView
        context.coordinator.pdfImageView = pdfImageView
        context.coordinator.canvasView = canvasView
        context.coordinator.picker = picker
        context.coordinator.pageSize = pageSize
        // Student page only for now (Task 12) — the tutor popup page passes
        // no session and never pushes snapshots.
        context.coordinator.session = page.role == .student ? session : nil
        context.coordinator.tutorCoordinator = page.role == .student ? tutorCoordinator : nil
        context.coordinator.syncUnderlay()

        onOverlayReady?(overlay)
        if let writer { onWriterReady?(writer) }

        // Center the page whenever the container gets its real bounds (zero at
        // makeUIView time) or changes size — insets keep the page mid-screen.
        container.onLayout = { [weak coordinator = context.coordinator] in
            coordinator?.centerContent()
            coordinator?.syncUnderlay()
        }

        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // The canvas is the sole writer of `page.drawing` (see Coordinator);
        // programmatic writes from the tutor land in Task 11 and will need a
        // guarded sync here. The PDF image can arrive after makeUIView runs
        // (async PDFKit render), so keep that one live.
        if context.coordinator.pdfImageView?.image !== page.pdfImage {
            context.coordinator.pdfImageView?.image = page.pdfImage
        }
        context.coordinator.session = page.role == .student ? session : nil
        context.coordinator.tutorCoordinator = page.role == .student ? tutorCoordinator : nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Container that reports layout passes so the page can be (re)centered
    /// once real bounds exist.
    final class CanvasContainerView: UIView {
        var onLayout: (() -> Void)?
        override func layoutSubviews() {
            super.layoutSubviews()
            onLayout?()
        }
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate, UIScrollViewDelegate {
        weak var page: PageModel?
        weak var paperView: UIView?
        weak var pdfImageView: UIImageView?
        weak var canvasView: PKCanvasView?
        var picker: PKToolPicker? // retain
        var pageSize: CGSize = .zero
        var session: TutorSession?
        var tutorCoordinator: TutorCoordinator?
        weak var overlay: AnnotationOverlayView?
        weak var writer: TutorWriter?

        // MARK: - Snapshot push (Task 12): debounce 800ms after the last
        // stroke, then respect a 3s floor between pushes and skip entirely
        // if the drawing hasn't changed since the last one that went out
        // (Global Constraints snapshot budget).
        private static let debounceNanoseconds: UInt64 = 800_000_000
        private static let minPushInterval: TimeInterval = 3.0

        private var pushTask: Task<Void, Never>?
        private var lastPushedDrawing: PKDrawing?
        private var lastPushTime: Date?

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            page?.drawing = canvasView.drawing
            scheduleSnapshotPush()
        }

        private func scheduleSnapshotPush() {
            // No render work at all while there's nowhere to send it —
            // skips the debounce/render/push path entirely until the data
            // channel is actually open.
            guard let session, session.isConnected else { return }
            pushTask?.cancel()
            pushTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: Coordinator.debounceNanoseconds)
                guard !Task.isCancelled else { return }
                await self?.pushSnapshotIfDue()
            }
        }

        @MainActor
        private func pushSnapshotIfDue() async {
            guard let session, session.isConnected, let page, let canvasView, let tutorCoordinator else { return }

            if canvasView.drawing == lastPushedDrawing { return } // unchanged since last push

            if let lastPushTime {
                let sinceLastPush = Date().timeIntervalSince(lastPushTime)
                if sinceLastPush < Coordinator.minPushInterval {
                    // Too soon — try again once the budget reopens, so a
                    // burst of strokes still nets one push once it settles.
                    let remaining = Coordinator.minPushInterval - sinceLastPush
                    pushTask = Task { [weak self] in
                        try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                        guard !Task.isCancelled else { return }
                        await self?.pushSnapshotIfDue()
                    }
                    return
                }
            }

            let drawingAtPushTime = canvasView.drawing
            lastPushedDrawing = drawingAtPushTime
            lastPushTime = Date()
            // Wiring Step 4: the bare SnapshotRenderer.render + session.pushImage
            // call this used to make is replaced by the coordinator's version,
            // which also computes marks, burns in their ID labels, and pushes
            // the registry JSON alongside the image — same debounce/interval/
            // unchanged-drawing gating above, only "what do I push" changed.
            await tutorCoordinator.pushEnrichedSnapshot(for: page)
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) { syncUnderlay() }
        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            centerContent()
            syncUnderlay()
        }

        /// Keeps the page centered when it's smaller than the viewport
        /// (contentInset trick — offsets go negative, syncUnderlay's
        /// `-offset` math shifts the paper along with the ink for free).
        func centerContent() {
            guard let cv = canvasView else { return }
            let scaledW = pageSize.width * cv.zoomScale
            let scaledH = pageSize.height * cv.zoomScale
            let dx = max((cv.bounds.width - scaledW) / 2, 0)
            let dy = max((cv.bounds.height - scaledH) / 2, 0)
            cv.contentInset = UIEdgeInsets(top: dy, left: dx, bottom: dy, right: dx)
        }

        func syncUnderlay() {
            guard let canvasView, let paperView else { return }
            let zoom = canvasView.zoomScale
            let offset = canvasView.contentOffset
            paperView.frame = CGRect(
                x: -offset.x,
                y: -offset.y,
                width: pageSize.width * zoom,
                height: pageSize.height * zoom
            )
            // Same zoom/scroll tracking as the paper underlay above, via each
            // view's own `setZoom` (top-left-anchored CALayer transform,
            // AnnotationOverlayView/TutorWriter's shared convention) instead
            // of frame math.
            overlay?.setZoom(zoom, contentOffset: offset)
            writer?.setZoom(zoom, contentOffset: offset)
        }
    }
}
