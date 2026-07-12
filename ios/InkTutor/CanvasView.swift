import SwiftUI
import PencilKit

/// Full-screen PencilKit canvas with the system tool picker.
/// This is the spike: prove Apple Pencil ink works on-device. Nothing else.
struct CanvasView: UIViewRepresentable {
    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.drawingPolicy = .anyInput   // finger too, so it works in the simulator
        canvas.backgroundColor = .systemBackground

        let picker = PKToolPicker()
        picker.setVisible(true, forFirstResponder: canvas)
        picker.addObserver(canvas)
        canvas.becomeFirstResponder()
        context.coordinator.picker = picker  // retain it
        return canvas
    }

    func updateUIView(_ uiView: PKCanvasView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var picker: PKToolPicker? }
}
