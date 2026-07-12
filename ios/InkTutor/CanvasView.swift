import SwiftUI
import PencilKit

/// One page's PencilKit canvas: white paper, optional PDF underlay, native
/// pinch-zoom (PKCanvasView IS a UIScrollView, no wrapper needed), tool
/// picker. Used for both the student page and the tutor popup page.
///
/// The PDF underlay is a sibling view *outside* the scroll view's own
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

    static var drawingPolicy: PKCanvasViewDrawingPolicy {
        #if targetEnvironment(simulator)
        // Apple Pencil doesn't exist in the simulator; allow finger/mouse input so this is testable.
        return .anyInput
        #else
        return .pencilOnly
        #endif
    }

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
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
        context.coordinator.syncUnderlay()

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
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, PKCanvasViewDelegate, UIScrollViewDelegate {
        weak var page: PageModel?
        weak var paperView: UIView?
        weak var pdfImageView: UIImageView?
        weak var canvasView: PKCanvasView?
        var picker: PKToolPicker? // retain
        var pageSize: CGSize = .zero
        var session: TutorSession?

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
            guard session != nil else { return }
            pushTask?.cancel()
            pushTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: Coordinator.debounceNanoseconds)
                guard !Task.isCancelled else { return }
                await self?.pushSnapshotIfDue()
            }
        }

        @MainActor
        private func pushSnapshotIfDue() async {
            guard let session, let page, let canvasView else { return }

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
            let snapshot = SnapshotRenderer.render(page: page, pageSize: pageSize)
            lastPushedDrawing = drawingAtPushTime
            lastPushTime = Date()
            await session.pushImage(snapshot.jpeg)
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) { syncUnderlay() }
        func scrollViewDidZoom(_ scrollView: UIScrollView) { syncUnderlay() }

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
        }
    }
}
