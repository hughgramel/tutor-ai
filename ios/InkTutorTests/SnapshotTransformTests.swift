import XCTest
import CoreGraphics
@testable import InkTutor

/// Round-trip check for Snapshot's canvas<->image coordinate transform.
/// Canvas space is page points (768x1024, origin top-left); image space is
/// the rendered JPEG's pixel grid. toImage/toCanvas must be exact inverses.
final class SnapshotTransformTests: XCTestCase {
    func testSnapshotTransformRoundTrip() {
        let snap = Snapshot(jpeg: Data(), canvasRect: CGRect(x: 0, y: 0, width: 768, height: 1024), scale: 1280.0/768.0)
        let p = CGPoint(x: 200, y: 300)
        XCTAssertEqual(snap.toCanvas(snap.toImage(p)).x, p.x, accuracy: 0.01)
        XCTAssertEqual(snap.toImage(CGPoint.zero), .zero)
    }

    func testRoundTripWithNonZeroOrigin() {
        // canvasRect can be offset (e.g. a cropped region); the transform must still invert cleanly.
        let snap = Snapshot(jpeg: Data(), canvasRect: CGRect(x: 50, y: 100, width: 768, height: 1024), scale: 1280.0 / 1024.0)
        let p = CGPoint(x: 412.5, y: 987.25)
        let roundTripped = snap.toCanvas(snap.toImage(p))
        XCTAssertEqual(roundTripped.x, p.x, accuracy: 0.01)
        XCTAssertEqual(roundTripped.y, p.y, accuracy: 0.01)
    }
}
