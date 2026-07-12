import Foundation

/// The provider-agnostic contract every later task codes against (D1: Task 3
/// decides which concrete implementation — OpenAI Realtime over WebRTC wins,
/// see `RealtimeSession`). Nothing above this protocol should know it's
/// talking to OpenAI specifically.
protocol TutorSession: AnyObject {
    func connect() async throws
    func pushImage(_ jpeg: Data) async            // conversation context, no response trigger
    func pushEvent(_ json: String) async          // journal events as text items
    var transcriptDeltas: AsyncStream<String> { get }   // feeds subtitles + TagParser
    var isSpeaking: Bool { get }
    func endSession()
}
