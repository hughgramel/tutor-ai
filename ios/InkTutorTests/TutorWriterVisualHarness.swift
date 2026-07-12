import XCTest
@testable import InkTutor

/// Visual QA harness for Task 11's handwriting writer — NOT a correctness
/// gate (no assertions beyond "didn't crash / file got written"). Renders a
/// battery of demo expressions through the real `TutorWriter` pipeline
/// (SwiftMath layout -> `glyphStrokes` -> `CAShapeLayer`) and dumps each to a
/// PNG under `/tmp/tutorwriter-battery/`, so a human (or an agent with a
/// Read tool) can eyeball whether the output reads as tidy handwriting.
///
/// Always runs as part of the normal suite (cheap: `write()`'s only real
/// cost is the `Task.sleep` calls that pace the on-screen animation, which
/// stay in the tens-of-milliseconds range even for the whole battery) — so
/// a red run here is a real signal, not just a skipped diagnostic. Re-render
/// on demand with:
///   xcodebuild test -only-testing:InkTutorTests/TutorWriterVisualHarness ...
@MainActor
final class TutorWriterVisualHarness: XCTestCase {

    private static let outputDirectory = URL(fileURLWithPath: "/tmp/tutorwriter-battery", isDirectory: true)

    private static let battery: [(name: String, latex: String)] = [
        ("01_linear_paren", "3(x+4)=21"),
        ("02_linear_paren_2", "2(x+5)=14"),
        ("03_decimal", "x=3.5"),
        ("04_quadratic", "x^2+8x+12=0"),
        ("05_factored", "(x+2)(x+6)=0"),
        ("06_slope_intercept", "y=2x-7"),
        ("07_fraction", "\\frac{1}{2}"),
        ("08_sqrt", "\\sqrt{16}"),
        ("09_unknown_glyphs", "3z+w"),
        ("10_integral", "\\int x"),
        ("11_pi", "\\pi r^2"),
    ]

    func testRenderBattery() async throws {
        let fm = FileManager.default
        try? fm.removeItem(at: Self.outputDirectory)
        try fm.createDirectory(at: Self.outputDirectory, withIntermediateDirectories: true)

        for entry in Self.battery {
            let pageSize = CGSize(width: 600, height: 220)
            let container = UIView(frame: CGRect(origin: .zero, size: pageSize))
            container.backgroundColor = .white

            let writer = TutorWriter(overlayOn: container)
            writer.setZoom(1, contentOffset: .zero)

            let result = await writer.write(latex: entry.latex, at: CGPoint(x: 24, y: 24), height: 72)
            XCTAssertFalse(result.placements.isEmpty, "\(entry.latex) produced no placements — layout failed")

            let renderer = UIGraphicsImageRenderer(size: pageSize)
            let image = renderer.image { ctx in
                container.layer.render(in: ctx.cgContext)
            }
            guard let data = image.pngData() else {
                return XCTFail("failed to encode PNG for \(entry.name)")
            }
            let fileURL = Self.outputDirectory.appendingPathComponent("\(entry.name).png")
            try data.write(to: fileURL)
        }

        print("TutorWriterVisualHarness: wrote \(Self.battery.count) PNGs to \(Self.outputDirectory.path)")
    }
}
