import PencilKit
import UIKit

/// One page of ink: the student's worksheet, or the tutor's own popup page.
/// Page rules (student = annotate-only, tutor = annotate + write) are
/// enforced in client code that consumes `role` (Task 9), not here.
final class PageModel: ObservableObject, Identifiable {
    enum Role {
        case student
        case tutor
    }

    let id = UUID()
    let role: Role

    /// Canvas-space ink. This view model is the source of truth; the
    /// PKCanvasView representable writes back into it on every stroke.
    @Published var drawing: PKDrawing

    /// PDF worksheet underlay (student page only). Nil for the tutor page.
    @Published var pdfImage: UIImage?

    init(role: Role, drawing: PKDrawing = PKDrawing(), pdfImage: UIImage? = nil) {
        self.role = role
        self.drawing = drawing
        self.pdfImage = pdfImage
    }
}
