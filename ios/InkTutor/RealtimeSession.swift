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

    func connect() async throws {
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
    }

    func pushImage(_ jpeg: Data) async {
        let dataURL = "data:image/jpeg;base64,\(jpeg.base64EncodedString())"
        send([
            "type": "conversation.item.create",
            "item": [
                "type": "message",
                "role": "user",
                "content": [
                    ["type": "input_image", "image_url": dataURL]
                ],
            ],
        ])
        // Deliberately no response.create — this pushes conversation
        // context only, per the plan (Task 7 owns the image-context budget).
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

    func endSession() {
        dataChannel?.close()
        dataChannel = nil
        peerConnection?.close()
        peerConnection = nil
        localAudioTrack = nil
        transcriptContinuation?.finish()
        transcriptContinuation = nil
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
        return Self.factory.audioTrack(with: audioSource, trackId: "inktutor-mic-track")
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

    private func send(_ event: [String: Any]) {
        guard let dataChannel, dataChannel.readyState == .open else {
            print("⚠️ RealtimeSession: data channel not open, dropping event \(event["type"] ?? "?")")
            return
        }
        guard let payload = try? JSONSerialization.data(withJSONObject: event) else { return }
        dataChannel.sendData(RTCDataBuffer(data: payload, isBinary: false))
    }

    // MARK: - Data channel event parsing

    private func handleServerEvent(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return }

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
    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {}

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        handleServerEvent(buffer.data)
    }
}
