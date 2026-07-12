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
        TutorLog.shared.lifecycle("push-to-talk: hold start")
    }

    func stopTalking() async {
        guard let localAudioTrack else { return }
        localAudioTrack.isEnabled = false
        send(["type": "input_audio_buffer.commit"])
        send(["type": "response.create"])
        TutorLog.shared.lifecycle("push-to-talk: hold end -> commit + respond")
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

    private func cancelResponse() {
        send(["type": "response.cancel"])
        send(["type": "output_audio_buffer.clear"])
    }

    func endSession() {
        TutorLog.shared.lifecycle("session end")
        stopStatsTimer()
        dataChannel?.close()
        dataChannel = nil
        peerConnection?.close()
        peerConnection = nil
        localAudioTrack = nil
        transcriptContinuation?.finish()
        transcriptContinuation = nil
        audioLevelContinuation?.finish()
        audioLevelContinuation = nil
        pushedImageItemIDs.removeAll()
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
    private var audioLevelContinuation: AsyncStream<Float>.Continuation?
    private var statsTimer: Timer?
    private var pushedImageItemIDs: [String] = []
    private var imageItemCounter = 0

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
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
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

    // MARK: - Data channel event parsing

    private func handleServerEvent(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return }

        TutorLog.shared.received(type: type, raw: object)

        switch type {
        case "response.output_audio_transcript.delta":
            if let delta = object["delta"] as? String {
                transcriptContinuation?.yield(delta)
            }
        case "output_audio_buffer.started":
            isSpeaking = true
        case "output_audio_buffer.stopped", "output_audio_buffer.cleared":
            isSpeaking = false
        default:
            // input_audio_buffer.speech_started (barge-in) and response
            // lifecycle events (response.created/response.done) are noted
            // but unused here — WebRTC's server-side VAD already auto-
            // truncates playback; cancelling pending tag animations on
            // barge-in is Task 9's job against this same event stream.
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
