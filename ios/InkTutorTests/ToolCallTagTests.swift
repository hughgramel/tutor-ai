import XCTest
@testable import InkTutor

/// The silent-function-call → internal-tag translation
/// (RealtimeSession.tagForToolCall). This seam exists because a realtime
/// voice model SPEAKS inline tags; if translation drifts from TagParser's
/// grammar, drawing dies silently — these pin the mapping.
final class ToolCallTagTests: XCTestCase {
    func testAnnotateCircle() {
        XCTAssertEqual(RealtimeSession.tagForToolCall(name: "annotate", argsJSON: #"{"action":"circle","mark":8}"#), "[CIRCLE:8]")
    }
    func testAnnotateUnderline() {
        XCTAssertEqual(RealtimeSession.tagForToolCall(name: "annotate", argsJSON: #"{"action":"underline","mark":3}"#), "[UNDERLINE:3]")
    }
    func testAnnotateArrow() {
        XCTAssertEqual(RealtimeSession.tagForToolCall(name: "annotate", argsJSON: #"{"action":"arrow","mark":19,"to":23}"#), "[ARROW:19>23]")
    }
    func testArrowMissingTargetDropped() {
        XCTAssertNil(RealtimeSession.tagForToolCall(name: "annotate", argsJSON: #"{"action":"arrow","mark":19}"#))
    }
    func testWriteMathDefaultsBelowLast() {
        XCTAssertEqual(RealtimeSession.tagForToolCall(name: "write_math", argsJSON: #"{"latex":"2(x + 5) = 14"}"#), "[WRITE:2(x + 5) = 14|below:last]")
    }
    func testWriteMathBelowMark() {
        XCTAssertEqual(RealtimeSession.tagForToolCall(name: "write_math", argsJSON: #"{"latex":"x = 2","below":7}"#), "[WRITE:x = 2|below:7]")
    }
    func testPause() {
        XCTAssertEqual(RealtimeSession.tagForToolCall(name: "pause", argsJSON: #"{"seconds":4}"#), "[WAIT:4]")
    }
    func testShapePolygon() {
        XCTAssertEqual(
            RealtimeSession.tagForToolCall(name: "draw_shape", argsJSON: #"{"kind":"polygon","points":[[0.1,0.9],[0.9,0.9],[0.9,0.1]],"label":"a^2+b^2=c^2"}"#),
            "[SHAPE:polygon:0.100,0.900;0.900,0.900;0.900,0.100:a^2+b^2=c^2]")
    }
    func testUnknownToolNil() {
        XCTAssertNil(RealtimeSession.tagForToolCall(name: "erase", argsJSON: "{}"))
        XCTAssertNil(RealtimeSession.tagForToolCall(name: "annotate", argsJSON: "not json"))
    }
}
