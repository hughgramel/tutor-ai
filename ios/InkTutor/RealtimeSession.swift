import Foundation
import AVFoundation
import WebRTC

/// OpenAI Realtime over WebRTC — the concrete winner of D1 (Task 3 of
/// `docs/superpowers/plans/2026-07-12-inktutor-mvp.md`). Everything above
/// `TutorSession` should be provider-agnostic; only this file knows it's
/// talking to OpenAI.
///
/// Endpoint paths, the data channel label, and event/type names were
/// verified against OpenAI's current Realtime docs (developers.openai.com/
/// api/docs/guides/realtime-webrtc, .../api-reference/realtime-sessions,
/// community-confirmed output_audio_buffer.started/stopped) on 2026-07-12 —
/// see the Task 3 report for the one place this differed from the plan's
/// memory of it (the SDP exchange endpoint is `/v1/realtime/calls`, which
/// the plan already had right; the token endpoint used by Task 1's worker,
/// `/v1/realtime/client_secrets`, also checked out).
final class RealtimeSession: NSObject, TutorSession {

    // MARK: - TutorSession

    private(set) var isSpeaking: Bool = false

    var transcriptDeltas: AsyncStream<String> {
        AsyncStream { continuation in
            self.transcriptContinuation = continuation
        }
    }

    var userTranscript: AsyncStream<String> {
        AsyncStream { continuation in
            self.userTranscriptContinuation = continuation
        }
    }

    var audioLevel: AsyncStream<Float> {
        AsyncStream { continuation in
            self.audioLevelContinuation = continuation
        }
    }

    var isConnected: Bool {
        dataChannel?.readyState == .open
    }

    func connect() async throws {
        TutorLog.shared.lifecycle("connect start")
        do {
            let ephemeralKey = try await fetchEphemeralKey()

            // CRITICAL ORDER: configure the audio session BEFORE creating the
            // peer connection — configuring it after breaks echo cancellation.
            try configureAudioSession()

            let pc = try makePeerConnection()
            peerConnection = pc

            let dc = pc.dataChannel(forLabel: "oai-events", configuration: RTCDataChannelConfiguration())
            dc?.delegate = self
            dataChannel = dc

            let audioTrack = try makeLocalAudioTrack()
            localAudioTrack = audioTrack
            _ = pc.add(audioTrack, streamIds: ["inktutor-mic"])

            let offer = try await createOffer(on: pc)
            try await setLocalDescription(offer, on: pc)

            let answerSDP = try await postOffer(offer.sdp, ephemeralKey: ephemeralKey)
            let answer = RTCSessionDescription(type: .answer, sdp: answerSDP)
            try await setRemoteDescription(answer, on: pc)
            TutorLog.shared.lifecycle("SDP ok")
        } catch {
            TutorLog.shared.error("connect failed: \(error)")
            throw error
        }
    }

    func pushImage(_ jpeg: Data) async {
        let dataURL = "data:image/jpeg;base64,\(jpeg.base64EncodedString())"
        imageItemCounter += 1
        let itemID = String(format: "img_%04d", imageItemCounter)
        TutorLog.shared.info("send image context: \(jpeg.count / 1024) KB JPEG")
        let sent = send([
            "type": "conversation.item.create",
            "item": [
                "id": itemID,
                "type": "message",
                "role": "user",
                "content": [
                    ["type": "input_image", "image_url": dataURL]
                ],
            ],
        ])
        // Deliberately no response.create — this pushes conversation
        // context only, per the plan (Task 7 owns the image-context budget).
        guard sent else { return }
        pushedImageItemIDs.append(itemID)
        pruneOldImageItems()
    }

    /// Token-budget pruning (Task upgrade, 2026-07-12): only the 2 most
    /// recent snapshot images stay live in the conversation — older ones
    /// are deleted server-side so stale ink doesn't keep costing image
    /// tokens on every turn. Registry/text items (pushEvent) are never
    /// tracked here and so never deleted by this path. Client-generated
    /// item ids (set on conversation.item.create above) mean no server
    /// round-trip is needed to know what to delete.
    private static let maxLiveImageItems = 2

    private func pruneOldImageItems() {
        while pushedImageItemIDs.count > Self.maxLiveImageItems {
            let oldest = pushedImageItemIDs.removeFirst()
            TutorLog.shared.info("prune snapshot item \(oldest) (\(pushedImageItemIDs.count) remaining)")
            // Field name verified against the Realtime API's
            // conversation.item.delete client event on developers.openai.com
            // (2026-07-12): {"type": "conversation.item.delete", "item_id": "..."}.
            send([
                "type": "conversation.item.delete",
                "item_id": oldest,
            ])
        }
    }

    func pushEvent(_ json: String) async {
        send([
            "type": "conversation.item.create",
            "item": [
                "type": "message",
                "role": "user",
                "content": [
                    ["type": "input_text", "text": json]
                ],
            ],
        ])
    }

    // MARK: - Push-to-talk mic control
    //
    // Server VAD is disabled once, right after the data channel opens (see
    // `dataChannelDidChangeState`), and stays off — the client owns
    // turn-taking entirely via hold/release. (2026-07-12, simplified: cut
    // the double-tap open-mic mode and semantic_vad — demo interaction is
    // hold-only, no VAD mode-switching at all.) Event shapes verified
    // against developers.openai.com/api/docs (2026-07-12): session.update's
    // turn_detection lives at `session.audio.input.turn_detection` (mirrors
    // the worker's existing `session.audio.output.voice`); `null` disables
    // it entirely. input_audio_buffer.clear/commit and response.create/
    // cancel take no fields beyond `type`. output_audio_buffer.clear is
    // WebRTC/SIP-specific (no WebSocket equivalent — that transport uses
    // conversation.item.truncate instead) and is needed alongside
    // response.cancel to actually stop audio that's already buffered for
    // playback — that's the barge-in mechanism below: holding while the
    // tutor is speaking cancels its response before taking the mic.

    func startTalking() async {
        guard let localAudioTrack else { return }
        if isSpeaking { cancelResponse() } // barge-in: holding while it talks interrupts it
        send(["type": "input_audio_buffer.clear"])
        localAudioTrack.isEnabled = true
        holdStartTime = Date()
        TutorLog.shared.lifecycle("push-to-talk: hold start")
    }

    /// Order (clear -> audio -> commit -> response.create) cross-checked
    /// against developers.openai.com/api/docs/guides/realtime-conversations
    /// "Push-to-talk" section (WebRTC variant, steps 1-7) on 2026-07-12: with
    /// `turn_detection: null` the server does not auto-commit the input
    /// buffer — commit is manual, which is what this does. No auto-commit
    /// behavior is documented for the WebRTC transport with VAD off; if the
    /// server turns out to send an unsolicited `input_audio_buffer.committed`
    /// before ours, that event is already visible via `TutorLog.shared.
    /// received`'s generic path, and a redundant manual commit on an
    /// already-committed buffer is a server `error` event (now surfaced —
    /// see `TutorLog.logServerError`), not silent corruption — worth
    /// watching the console for, not worth a state machine at hackathon scope.
    func stopTalking() async {
        guard let localAudioTrack else { return }
        localAudioTrack.isEnabled = false
        let holdDurationMs = holdStartTime.map { Date().timeIntervalSince($0) * 1000 } ?? 0
        holdStartTime = nil

        // Robustness (Hugh, device testing, 2026-07-12): a hold shorter than
        // ~300ms is almost certainly an accidental tap, not real speech.
        // Committing a near-empty input buffer gets rejected server-side
        // with an `error` event and the button feels dead (no response ever
        // arrives). Clear and bail instead of commit + response.create.
        guard holdDurationMs >= Self.minimumHoldMs else {
            send(["type": "input_audio_buffer.clear"])
            TutorLog.shared.info("push-to-talk: hold end -> too short (\(Int(holdDurationMs))ms), skipping commit")
            return
        }

        send(["type": "input_audio_buffer.commit"])
        beginLatencyMeasurement()
        send(["type": "response.create"])
        TutorLog.shared.lifecycle("push-to-talk: hold end -> commit + respond")
    }

    /// Below this, a hold is treated as an accidental tap rather than speech.
    private static let minimumHoldMs: Double = 300

    // MARK: - Latency instrumentation ("the latency is bad" — measure before
    // fixing). One exchange = one `response.create` through its `response.done`.
    // (a) start = this file sending `response.create` in stopTalking(); (b)
    // first_audio = whichever arrives first of `response.output_audio_
    // transcript.delta` or `output_audio_buffer.started` (both are legitimate
    // "the tutor started responding" signals — see the switch in
    // `handleServerEvent`); (c) total = `response.done`. Deliberately not
    // reset on barge-in/cancelResponse — a cancelled exchange just never hits
    // response.done and its start gets overwritten by the next stopTalking(),
    // so no stale numbers get logged.

    private func beginLatencyMeasurement() {
        responseStartTime = Date()
        firstAudioMs = nil
        // Addendum (2026-07-12): reset the pace-calibration accumulators for
        // this response too — see "Speech pace calibration" below.
        audioStartTime = nil
        responseCharCount = 0
    }

    private func recordFirstAudioIfNeeded() {
        guard let start = responseStartTime, firstAudioMs == nil else { return }
        firstAudioMs = Date().timeIntervalSince(start) * 1000
    }

    private func finishLatencyMeasurement() {
        guard let start = responseStartTime else { return }
        let totalMs = Date().timeIntervalSince(start) * 1000
        // If no first-audio signal arrived before response.done (text-only
        // reply, or a signal we don't listen for), fall back to total so the
        // p50/max tracking isn't skewed by a missing sample.
        let firstAudio = firstAudioMs ?? totalMs
        TutorLog.shared.recordLatency(firstAudioMs: firstAudio, totalMs: totalMs)
        responseStartTime = nil
        firstAudioMs = nil
    }

    // MARK: - Speech pace calibration (addendum, 2026-07-12: "the subtitle
    // must track what's ACTUALLY being spoken" — VoiceBarView's word-paced
    // subtitle reveal used a fixed 45ms/char guess. The Realtime API doesn't
    // emit per-word playback timestamps, so exact sync isn't available —
    // this instead measures each completed response's real audio duration
    // (`output_audio_buffer.started` -> `.stopped`) against its transcript
    // character count, and hands the resulting ms/char to `TutorLog` so the
    // NEXT response's reveal pace is calibrated off the last one. Not
    // recorded on `.cleared` (barge-in) — a truncated playback duration
    // paired with the full transcript length would understate the pace.

    private var audioStartTime: Date?
    private var responseCharCount: Int = 0

    private func recordSpeechPaceIfPossible() {
        guard let start = audioStartTime else { return }
        let durationMs = Date().timeIntervalSince(start) * 1000
        TutorLog.shared.recordSpeechPace(audioDurationMs: durationMs, transcriptCharCount: responseCharCount)
    }

    /// Sent once, right after connect: server VAD off, full stop. No
    /// mode-switching after this — hold/release owns turn-taking for the
    /// life of the session.
    private func disableServerVAD() -> [String: Any] {
        [
            "type": "session.update",
            "session": [
                "type": "realtime",
                "audio": [
                    "input": [
                        "turn_detection": NSNull(),
                    ],
                ],
            ],
        ]
    }

    /// Sent once, right after connect: filters the input audio *before* it
    /// reaches VAD/the model, cutting false VAD triggers from room noise —
    /// same underlying complaint as the server_vad-vs-semantic_vad switch
    /// above, addressed at the signal level instead of the turn-detection
    /// level. `near_field` fits an iPad's built-in mic at arm's length
    /// better than `far_field` (meant for conference-room-style distant
    /// mics). Field shape verified against developers.openai.com/api/
    /// reference (RealtimeAudioConfigInput, session.audio.input.noise_
    /// reduction) on 2026-07-12 — the realtime-vad guide itself doesn't
    /// cover this field, only the reference schema does.
    private func noiseReductionUpdate() -> [String: Any] {
        [
            "type": "session.update",
            "session": [
                "type": "realtime",
                "audio": [
                    "input": [
                        "noise_reduction": ["type": "near_field"],
                    ],
                ],
            ],
        ]
    }

    func stopSpeaking() async {
        cancelResponse()
        TutorLog.shared.lifecycle("stopSpeaking: response cancelled by user")
    }

    private func cancelResponse() {
        send(["type": "response.cancel"])
        send(["type": "output_audio_buffer.clear"])
    }

    /// (Hugh, device testing, 2026-07-12: pressing ✕ while the tutor was
    /// speaking didn't reliably stop the audio.) Cancel the in-flight
    /// response and clear whatever's already buffered for playback over the
    /// data channel BEFORE tearing anything down — once the peer connection
    /// closes there's no channel left to send these on, and audio already
    /// queued in the WebRTC audio track can keep playing out past that point.
    /// Safe to send unconditionally even if nothing was speaking (server
    /// error events for redundant cancel/clear are already surfaced via
    /// `TutorLog.logServerError` and are harmless during teardown).
    func endSession() {
        TutorLog.shared.lifecycle("session end")
        cancelResponse()
        stopStatsTimer()
        dataChannel?.close()
        dataChannel = nil
        peerConnection?.close()
        peerConnection = nil
        localAudioTrack = nil
        isSpeaking = false
        transcriptContinuation?.finish()
        transcriptContinuation = nil
        userTranscriptContinuation?.finish()
        userTranscriptContinuation = nil
        audioLevelContinuation?.finish()
        audioLevelContinuation = nil
        pushedImageItemIDs.removeAll()
        responseStartTime = nil
        firstAudioMs = nil
        holdStartTime = nil
        audioStartTime = nil
        responseCharCount = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // ponytail: reconnection is a state machine (replay journal + fresh
    // snapshot on reconnect) — that's Task 7's `session_resume` event, not
    // this file's job. This spike does one ephemeral-token re-fetch and
    // stops there; no auto-reconnect on dropped peer connections.

    // MARK: - WebRTC state

    private static let factory: RTCPeerConnectionFactory = {
        let encoderFactory = RTCDefaultVideoEncoderFactory()
        let decoderFactory = RTCDefaultVideoDecoderFactory()
        return RTCPeerConnectionFactory(encoderFactory: encoderFactory, decoderFactory: decoderFactory)
    }()

    private var peerConnection: RTCPeerConnection?
    private var dataChannel: RTCDataChannel?
    private var localAudioTrack: RTCAudioTrack?
    private var transcriptContinuation: AsyncStream<String>.Continuation?
    private var userTranscriptContinuation: AsyncStream<String>.Continuation?
    private var audioLevelContinuation: AsyncStream<Float>.Continuation?
    private var statsTimer: Timer?
    private var pushedImageItemIDs: [String] = []
    private var imageItemCounter = 0
    /// Wall-clock start of the current hold (push-to-talk), used both for
    /// the too-short-hold guard in `stopTalking` and has no relation to the
    /// latency pair below (that one times the exchange, this one times the
    /// hold itself).
    private var holdStartTime: Date?
    /// Wall-clock start of the current response exchange — set in
    /// `stopTalking` right before sending `response.create`; cleared by
    /// `finishLatencyMeasurement` on `response.done`. See "Latency
    /// instrumentation" above.
    private var responseStartTime: Date?
    private var firstAudioMs: Double?

    /// One long-lived URLSession for the REST calls (Global Constraint —
    /// Clicky's socket-corruption warning against creating a fresh session
    /// per request).
    private let urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.waitsForConnectivity = true
        return URLSession(configuration: config)
    }()

    enum RealtimeSessionError: Error {
        case tokenFetchFailed
        case sdpExchangeFailed
        case peerConnectionSetupFailed
    }

    // MARK: - Token + SDP exchange (REST)

    private struct EphemeralTokenResponse: Decodable {
        let value: String
    }

    private func fetchEphemeralKey() async throws -> String {
        var request = URLRequest(url: Config.workerURL.appendingPathComponent("realtime-token"))
        request.httpMethod = "POST"
        return try await fetchEphemeralKeyOnce(request)
    }

    /// One re-fetch on failure, no further retry logic (Global Constraint:
    /// hackathon pace, no reconnection state machine here).
    private func fetchEphemeralKeyOnce(_ request: URLRequest, attempt: Int = 1) async throws -> String {
        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw RealtimeSessionError.tokenFetchFailed
            }
            return try JSONDecoder().decode(EphemeralTokenResponse.self, from: data).value
        } catch {
            if attempt < 2 {
                return try await fetchEphemeralKeyOnce(request, attempt: attempt + 1)
            }
            throw error
        }
    }

    private func postOffer(_ sdp: String, ephemeralKey: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/realtime/calls?model=gpt-realtime-2.1")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(ephemeralKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/sdp", forHTTPHeaderField: "Content-Type")
        request.httpBody = sdp.data(using: .utf8)

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw RealtimeSessionError.sdpExchangeFailed
        }
        guard let answerSDP = String(data: data, encoding: .utf8), !answerSDP.isEmpty else {
            throw RealtimeSessionError.sdpExchangeFailed
        }
        return answerSDP
    }

    // MARK: - Audio session (echo-cancellation gotcha)

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        // .mixWithOthers so this session doesn't outright silence Zoom's
        // broadcast-extension session when screen-sharing for a demo. Only
        // covers our half of the interruption: if Zoom's own session
        // activates non-mixable (its choice, not ours), it still wins and
        // interrupts us regardless of this flag — needs testing against the
        // actual Zoom share flow, not assumed fixed by this alone.
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP, .mixWithOthers])
        try session.setActive(true)
    }

    // MARK: - Peer connection setup

    private func makePeerConnection() throws -> RTCPeerConnection {
        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        // OpenAI's WebRTC endpoint terminates the connection directly — no
        // STUN/TURN servers needed for this exchange.
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let pc = Self.factory.peerConnection(with: config, constraints: constraints, delegate: self) else {
            throw RealtimeSessionError.peerConnectionSetupFailed
        }
        return pc
    }

    private func makeLocalAudioTrack() throws -> RTCAudioTrack {
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let audioSource = Self.factory.audioSource(with: constraints)
        let track = Self.factory.audioTrack(with: audioSource, trackId: "inktutor-mic-track")
        // Push-to-talk default: muted until a hold enables it — see
        // `startTalking`/`stopTalking`.
        track.isEnabled = false
        return track
    }

    private func createOffer(on pc: RTCPeerConnection) async throws -> RTCSessionDescription {
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: ["OfferToReceiveAudio": "true"],
            optionalConstraints: nil
        )
        return try await withCheckedThrowingContinuation { continuation in
            pc.offer(for: constraints) { sdp, error in
                if let sdp {
                    continuation.resume(returning: sdp)
                } else {
                    continuation.resume(throwing: error ?? RealtimeSessionError.peerConnectionSetupFailed)
                }
            }
        }
    }

    private func setLocalDescription(_ sdp: RTCSessionDescription, on pc: RTCPeerConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pc.setLocalDescription(sdp) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private func setRemoteDescription(_ sdp: RTCSessionDescription, on pc: RTCPeerConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pc.setRemoteDescription(sdp) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    // MARK: - Sending over the data channel

    @discardableResult
    private func send(_ event: [String: Any]) -> Bool {
        let type = event["type"] as? String ?? "?"
        guard let dataChannel, dataChannel.readyState == .open else {
            let message = "data channel not open, dropping event \(type)"
            print("⚠️ RealtimeSession: \(message)")
            TutorLog.shared.error(message)
            return false
        }
        guard let payload = try? JSONSerialization.data(withJSONObject: event) else { return false }
        TutorLog.shared.sent(type: type, byteCount: payload.count)
        dataChannel.sendData(RTCDataBuffer(data: payload, isBinary: false))
        return true
    }

    // MARK: - Audio level metering (WebRTC v2 statistics API)

    /// ~15Hz, matching the waveform's redraw cadence — polling faster just
    /// burns CPU on JSON-free but still nontrivial stats-collection work.
    private static let statsPollInterval: TimeInterval = 1.0 / 15.0

    private func startStatsTimer() {
        stopStatsTimer()
        let timer = Timer(timeInterval: Self.statsPollInterval, repeats: true) { [weak self] _ in
            self?.pollAudioLevel()
        }
        RunLoop.main.add(timer, forMode: .common)
        statsTimer = timer
    }

    private func stopStatsTimer() {
        statsTimer?.invalidate()
        statsTimer = nil
    }

    /// Reads `RTCStatistics` entries off the v2 stats API: the local mic's
    /// level lives on the "media-source" (kind "audio") entry, the tutor's
    /// spoken audio on the "inbound-rtp" (kind "audio") entry — both carry
    /// an `audioLevel` value in `values`, 0...1 linear, per the WebRTC/W3C
    /// stats spec (confirmed against stasel/WebRTC's RTCStatisticsReport.h,
    /// which defines `RTCStatistics.type`/`.values` as the generic
    /// String-keyed carrier for these spec-defined dictionaries — the
    /// binary xcframework has no per-field header, so "media-source" /
    /// "inbound-rtp" / "audioLevel" are cross-checked against
    /// w3.org/TR/webrtc-stats instead, 2026-07-12).
    private func pollAudioLevel() {
        guard let peerConnection else { return }
        peerConnection.statistics { [weak self] report in
            guard let self else { return }
            var micLevel: Float = 0
            var remoteLevel: Float = 0
            for stat in report.statistics.values {
                guard let level = (stat.values["audioLevel"] as? NSNumber)?.floatValue else { continue }
                switch stat.type {
                case "media-source": micLevel = max(micLevel, level)
                case "inbound-rtp": remoteLevel = max(remoteLevel, level)
                default: break
                }
            }
            self.audioLevelContinuation?.yield(max(micLevel, remoteLevel))
        }
    }

    // MARK: - Tool-call → tag translation

    /// Maps a silent realtime function call onto the inline-tag grammar the
    /// rest of the app already parses/renders (`TagParser.swift` is the
    /// grammar's source of truth). Returns nil for unknown tools/args.
    static func tagForToolCall(name: String, argsJSON: String) -> String? {
        guard let data = argsJSON.data(using: .utf8),
              let args = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        switch name {
        case "annotate":
            guard let action = args["action"] as? String,
                  let mark = args["mark"] as? Int else { return nil }
            switch action {
            case "circle": return "[CIRCLE:\(mark)]"
            case "underline": return "[UNDERLINE:\(mark)]"
            case "arrow":
                guard let to = args["to"] as? Int else { return nil }
                return "[ARROW:\(mark)>\(to)]"
            default: return nil
            }
        case "write_math":
            guard let latex = args["latex"] as? String, !latex.isEmpty else { return nil }
            let anchor: String
            if let below = args["below"] as? Int { anchor = "below:\(below)" }
            else { anchor = "below:last" }
            return "[WRITE:\(latex)|\(anchor)]"
        case "draw_shape":
            guard let kind = args["kind"] as? String,
                  let pts = args["points"] as? [[Double]], pts.count >= 2 else { return nil }
            let vertices = pts.compactMap { p -> String? in
                guard p.count == 2 else { return nil }
                return String(format: "%.3f,%.3f", p[0], p[1])
            }.joined(separator: ";")
            let label = (args["label"] as? String) ?? ""
            return "[SHAPE:\(kind):\(vertices):\(label)]"
        case "pause":
            let seconds = (args["seconds"] as? Int) ?? 5
            return "[WAIT:\(seconds)]"
        default:
            return nil
        }
    }

    // MARK: - Data channel event parsing

    private func handleServerEvent(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return }

        TutorLog.shared.received(type: type, raw: object)

        switch type {
        case "response.output_audio_transcript.delta":
            recordFirstAudioIfNeeded()
            if let delta = object["delta"] as? String {
                transcriptContinuation?.yield(delta)
                responseCharCount += delta.count
            }
        case "output_audio_buffer.started":
            recordFirstAudioIfNeeded()
            isSpeaking = true
            if audioStartTime == nil { audioStartTime = Date() }
        case "output_audio_buffer.stopped":
            isSpeaking = false
            recordSpeechPaceIfPossible()
            audioStartTime = nil
        case "output_audio_buffer.cleared":
            // Barge-in cut this response's audio short — not a valid pace
            // sample (duration would be truncated relative to the full
            // transcript already accumulated), so skip calibration here.
            isSpeaking = false
            audioStartTime = nil
        case "response.output_item.done":
            // Drawing commands arrive as FUNCTION CALLS, not inline tags —
            // a realtime voice model SPEAKS its text output, so inline tags
            // got voiced aloud ("circle eight"). Function calls ride the
            // data channel silently. We translate each back into the exact
            // tag string the existing pipeline understands and yield it into
            // the same transcript stream: TagParser strips it from subtitles
            // and dispatches it — zero downstream changes.
            if let item = object["item"] as? [String: Any],
               item["type"] as? String == "function_call",
               let name = item["name"] as? String,
               let callID = item["call_id"] as? String {
                let argsJSON = item["arguments"] as? String ?? "{}"
                if let tag = Self.tagForToolCall(name: name, argsJSON: argsJSON) {
                    TutorLog.shared.lifecycle("tool call \(name) -> \(tag)")
                    transcriptContinuation?.yield(tag)
                } else {
                    TutorLog.shared.info("tool call \(name) not translatable: \(argsJSON)")
                }
                // Ack immediately — the render is fire-and-forget client-side.
                _ = send([
                    "type": "conversation.item.create",
                    "item": [
                        "type": "function_call_output",
                        "call_id": callID,
                        "output": "{\"ok\":true}",
                    ],
                ])
                // Resume narration after a drawing call — but NOT after
                // `pause`: asking for a new response there would make the
                // model talk through its own wait.
                if name != "pause" {
                    _ = send(["type": "response.create"])
                }
            }
        case "response.done":
            finishLatencyMeasurement()
        case "conversation.item.input_audio_transcription.completed":
            // Event shape verified against developers.openai.com/api/docs/
            // guides/realtime-transcription (2026-07-12): {item_id,
            // content_index, transcript}. Deliberately not consuming the
            // sibling `.delta` event here — the low-opacity "you: ..." line
            // (VoiceBarView) replaces per completed utterance rather than
            // streaming word-by-word, so completed-only is enough; `.delta`
            // still arrives on the wire (transcription is enabled
            // session-wide) and is sampled/logged generically by
            // `TutorLog.received`.
            if let transcript = object["transcript"] as? String {
                userTranscriptContinuation?.yield(transcript)
                TutorLog.shared.info("student said: \(transcript)")
            }
        default:
            // input_audio_buffer.speech_started (barge-in) and
            // response.created are noted but unused here — WebRTC's
            // server-side VAD already auto-truncates playback; cancelling
            // pending tag animations on barge-in is Task 9's job against
            // this same event stream.
            break
        }
    }
}

// MARK: - RTCPeerConnectionDelegate

extension RealtimeSession: RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}

// MARK: - RTCDataChannelDelegate

extension RealtimeSession: RTCDataChannelDelegate {
    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        switch dataChannel.readyState {
        case .open:
            TutorLog.shared.lifecycle("data channel open")
            startStatsTimer()
            // Push-to-talk default: server VAD off, client owns
            // turn-taking, right as the channel becomes usable. Plus
            // near-field input noise reduction.
            send(disableServerVAD())
            send(noiseReductionUpdate())
        case .closing: TutorLog.shared.lifecycle("data channel closing")
        case .closed:
            TutorLog.shared.lifecycle("data channel closed")
            stopStatsTimer()
        case .connecting: break
        @unknown default: break
        }
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        handleServerEvent(buffer.data)
    }
}
