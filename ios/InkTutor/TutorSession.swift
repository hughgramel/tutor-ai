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
    /// The student's own speech, transcribed server-side (Realtime API input
    /// audio transcription — worker enables `session.audio.input.transcription`).
    /// Yields one complete utterance per element, on
    /// `conversation.item.input_audio_transcription.completed` — not deltas —
    /// since the low-opacity "you: ..." line (VoiceBarView) just replaces on
    /// each completed turn rather than streaming word-by-word.
    var userTranscript: AsyncStream<String> { get }
    var isSpeaking: Bool { get }
    /// Immediately stops any in-flight tutor response (speech + generation).
    /// Session stays connected — this is the stop button, not teardown.
    func stopSpeaking() async
    /// Live mic/tutor audio level, 0...1, emitted ~15Hz while connected —
    /// drives the voice bar's waveform. `max(micLevel, remoteLevel)` so
    /// either party talking moves the bars.
    var audioLevel: AsyncStream<Float> { get }
    /// True once the data channel is open — gates snapshot pushes so no
    /// render/debounce work happens while there's nowhere to send it.
    var isConnected: Bool { get }

    // MARK: - Push-to-talk mic control (Hugh, first device run, 2026-07-12:
    // server VAD's open mic was auto-responding to ambient noise). Server
    // VAD is disabled once, right after connect (`turn_detection: null`),
    // and stays off — the client owns turn-taking entirely via hold/release.
    // (2026-07-12, simplified: cut the double-tap open-mic mode and all
    // VAD mode-switching. Hold-to-talk only; holding while the tutor is
    // speaking is itself the barge-in.)

    /// Hold begins: if the tutor is speaking, cancel its response first
    /// (barge-in), then clear the input buffer and un-mute the mic.
    func startTalking() async
    /// Hold ends: mute the mic, then commit the input buffer and trigger
    /// a response.
    func stopTalking() async

    /// Ends the session outright (the ✕ button, always — no interrupt-only
    /// role anymore since holding covers interruption).
    func endSession()
}
