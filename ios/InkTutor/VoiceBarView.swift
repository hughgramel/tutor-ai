import SwiftUI
import UIKit

/// Top-right voice chrome. Tap the idle "Ask AI" box to connect (server VAD
/// off — push-to-talk, for the life of the session). The box collapses into
/// a waveform pill: **hold** it to talk, release to commit + get a
/// response. Holding while the tutor is speaking is itself the barge-in —
/// it cancels the in-flight response before taking the mic, so there's no
/// separate interrupt gesture. The **✕** beside the pill always just ends
/// the session and collapses back to idle. (Hugh, first device run,
/// 2026-07-12: the old tap-to-toggle + always-on server VAD picked up
/// ambient noise and kept auto-responding — push-to-talk replaces that.
/// 2026-07-12, simplified again: cut the double-tap open-mic/continuous-
/// listening mode and all VAD mode-switching — demo interaction is
/// hold-only.) A subtitle box streams the tutor's words above the pill
/// while connected.
///
/// Native Liquid Glass (`.glassEffect()`) where the iOS 26 SDK is available;
/// falls back to `.ultraThinMaterial` on the iOS 17 deployment target this
/// project still builds against (Global Constraints: no beta APIs, but the
/// SDK here is iOS 26 so we take the real material when we can get it).
struct VoiceBarView: View {
    let session: TutorSession

    @State private var connection: ConnectionState = .idle
    @State private var subtitleLines: [String] = []
    @State private var currentLine: String = ""
    /// Student's last completed utterance, from `session.userTranscript` —
    /// the low-opacity "you: ..." line below the tutor's subtitle box.
    /// Replaced (not appended) on every completed transcription.
    @State private var studentTranscript: String = ""
    @Namespace private var glassNamespace

    /// Real amplitude bars, driven by `session.audioLevel` (2026-07-12
    /// upgrade — replaces the earlier timer-driven fake waveform). A fixed-
    /// size ring buffer of recent smoothed levels; new samples push in on
    /// the trailing edge so the bars read as a scrolling waveform.
    private static let barCount = 11
    @State private var barLevels: [CGFloat] = Array(repeating: Self.idleBarLevel, count: Self.barCount)
    @State private var smoothedLevel: CGFloat = Self.idleBarLevel
    private static let idleBarLevel: CGFloat = 0.08

    /// Whether the pill is currently being held (mic live).
    @State private var isHolding = false
    /// True between `endHold()` (release) and the tutor's first audio —
    /// drives the pill's brief "…" state so release doesn't feel dead while
    /// waiting on the model. Cleared by the first transcript delta (the
    /// same signal `RealtimeSession` uses for its own first-audio timing).
    @State private var isThinking = false

    private var isConnected: Bool { connection == .live || connection == .connecting }

    private var pillCaption: String? {
        if connection == .connecting { return "connecting — keep holding" }
        if isHolding { return "listening" }
        if isThinking { return "…" }
        return nil
    }

    var body: some View {
        // Chrome on top, speech BELOW the waveform (Hugh, 2026-07-12) —
        // reading flows downward from the thing you're touching.
        VStack(alignment: .trailing, spacing: 10) {
            morphingChrome

            // Fixed-height caption slot — conditional insertion shifted the
            // chrome vertically every time the caption appeared/vanished
            // (part of "it moves once you start holding").
            Text(pillCaption ?? " ")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(height: 14)
                .opacity(pillCaption == nil ? 0 : 1)

            if isConnected && (!subtitleLines.isEmpty || !currentLine.isEmpty) {
                subtitleBox
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            if isConnected && !studentTranscript.isEmpty {
                studentTranscriptLine
                    .transition(.opacity)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: connection)
        .animation(.easeInOut(duration: 0.2), value: studentTranscript)
        .animation(.easeInOut(duration: 0.15), value: pillCaption)
    }

    // MARK: - Morph container

    /// `GlassEffectContainer` + matched `glassEffectID` is the iOS 26 way to
    /// get the box-melts-into-pill morph "for free" -- both states share one
    /// glass identity inside the container. Below iOS 26 this just falls
    /// back to a plain switch (the earlier deployment target this project
    /// still declares).
    /// The talk surface (idle box ⇄ waveform pill) is ONE stable view whose
    /// contents cross-fade — NOT a switch that swaps views. A switch removes
    /// the view mid-press when idle morphs to pill, which cancels the
    /// long-press gesture and kills the one-gesture hold flow (press "Ask
    /// AI" → connect → mic live → release sends). The ✕ sits outside the
    /// gesture surface. (Traded away the GlassEffectContainer morph for
    /// gesture continuity — function over gloss.)
    private var morphingChrome: some View {
        HStack(spacing: 10) {
            talkSurface
            if isConnected {
                closeButton
                    .transition(.opacity.combined(with: .scale))
            }
        }
    }

    private var showPill: Bool { isConnected }

    private var talkSurface: some View {
        ZStack {
            idleContent.opacity(showPill ? 0 : 1)
            pillContent.opacity(showPill ? 1 : 0)
        }
        // Constant padding in both states — state-dependent padding made the
        // whole chrome shift the instant a hold started (Hugh, device
        // testing: "it moves once you start holding").
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .contentShape(Capsule())
        .glassBackground(cornerRadius: 26, tint: connection == .error ? .red.opacity(0.15) : nil)
        .overlay(
            // glossy sheen: bright top edge fading out mid-capsule
            Capsule()
                .fill(LinearGradient(colors: [.white.opacity(0.35), .clear],
                                     startPoint: .top, endPoint: .center))
                .allowsHitTesting(false)
        )
        .clipShape(Capsule())
        .scaleEffect(isHolding ? 1.08 : 1.0)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isHolding)
        // DragGesture(minimumDistance: 0), NOT onLongPressGesture: the long-
        // press variant reports pressing=false when the gesture *recognizes*
        // (minimumDuration elapsing), not when the finger lifts — which is
        // exactly the "release doesn't stop recording" bug from device
        // testing. A zero-distance drag fires onChanged at touch-down and
        // onEnded at actual lift, unconditionally.
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !pressTracking {
                        pressTracking = true
                        handlePress(true)
                    }
                }
                .onEnded { _ in
                    pressTracking = false
                    handlePress(false)
                }
        )
    }

    /// Dedupes DragGesture.onChanged (fires continuously) into one
    /// press-down edge.
    @State private var pressTracking = false

    // MARK: - Idle state

    /// Idle: a static mini-waveform as the icon — the button previews the
    /// interaction it starts — plus a soft top sheen for the glossy read.
    private static let idleWaveHeights: [CGFloat] = [7, 13, 18, 11, 6]

    /// One gesture end-to-end (Hugh, device testing, 2026-07-12: "you can't
    /// just hold down and then release to have it respond" — before this,
    /// the idle button only connected on tap and hold-to-talk existed only
    /// on the post-morph pill, so holding "Ask AI" and speaking went
    /// nowhere). Press-down here starts connecting AND queues the hold; the
    /// mic goes live the instant the session is up; release commits.
    private var idleContent: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2.5) {
                ForEach(Array(Self.idleWaveHeights.enumerated()), id: \.offset) { _, h in
                    Capsule()
                        .fill(connection == .error ? Color.red : Color.primary.opacity(0.75))
                        .frame(width: 2.5, height: h)
                }
            }
            Text("Ask AI")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(connection == .error ? .red : .primary)
    }

    // MARK: - Waveform pill

    /// No `Button` here — `onLongPressGesture(minimumDuration: 0.01, ...)`
    /// is used purely for its `onPressingChanged` press-down/press-up
    /// edges, which map directly onto hold-to-talk start/stop.
    ///
    /// `maximumDistance: 60` bounds how far a touch can wander *within this
    /// gesture* before it cancels — it does not extend this view's hit-test
    /// area into `closeButton`'s territory (that's `.contentShape`, already
    /// scoped to this view's own 56x32 + padding frame). Widened the ✕'s tap
    /// target and the HStack spacing anyway as extra margin (device
    /// testing, 2026-07-12) since the two sit only a few points apart.
    private var pillContent: some View {
        HStack(spacing: 3) {
            ForEach(Array(barLevels.enumerated()), id: \.offset) { _, level in
                Capsule()
                    // Red while holding — an unmistakable "you're live"
                    // signal (Hugh, device testing, 2026-07-12: hold state
                    // wasn't clearly readable before).
                    .fill(isHolding ? Color.red.opacity(0.85) : .primary.opacity(0.8))
                    .frame(width: 2.5, height: barHeight(for: level))
            }
        }
        .frame(width: 56, height: 32)
        .opacity(connection == .connecting ? 0.55 : 1.0)
        .animation(.easeOut(duration: 0.08), value: barLevels)
        .onAppear(perform: resetWaveform)
    }

    // MARK: - Close button

    /// Visible glass chip stays 32x32 (unchanged look); the tappable area
    /// is padded out to 44x44 to clear Apple's HIG minimum touch target
    /// (Hugh, device testing, 2026-07-12: ✕ wasn't reliably registering).
    /// Not a Button (Hugh, device testing ×2: ✕ still didn't register) — a
    /// plain view + onTapGesture can't lose priority to sibling gestures the
    /// way UIKit-backed Button touch-up can, and the tap is logged so a dead
    /// ✕ is diagnosable from the console instead of a mystery.
    private var closeButton: some View {
        Image(systemName: "xmark")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: 32, height: 32)
            .glassBackground(cornerRadius: 16)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .onTapGesture {
                TutorLog.shared.lifecycle("close (X) tapped")
                handleClose()
            }
    }

    private func barHeight(for level: CGFloat) -> CGFloat {
        let minHeight: CGFloat = 4
        let maxHeight: CGFloat = 20
        let clamped = min(max(level, 0), 1)
        return minHeight + clamped * (maxHeight - minHeight)
    }

    // MARK: - Subtitles

    /// Completed lines dim; `currentLine` — the words being spoken RIGHT NOW,
    /// revealed word-by-word at speech pace — is always visible and full-
    /// opacity, so the box tracks exactly where the voice is (Hugh,
    /// 2026-07-12: "make sure we're tracking what's actually being spoken").
    private var subtitleBox: some View {
        VStack(alignment: .trailing, spacing: 3) {
            ForEach(Array(subtitleLines.suffix(2).enumerated()), id: \.offset) { index, line in
                Text(line)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .opacity(subtitleOpacity(forDistanceFromEnd: subtitleLines.suffix(2).count - index))
                    .multilineTextAlignment(.trailing)
            }
            if !currentLine.isEmpty {
                Text(currentLine)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.trailing)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 260, alignment: .trailing)
        .glassBackground(cornerRadius: 16)
    }

    private func subtitleOpacity(forDistanceFromEnd distance: Int) -> Double {
        switch distance {
        case 0: return 1.0
        case 1: return 0.6
        default: return 0.35
        }
    }

    // MARK: - Student transcript ("we need low opacity chat showing what
    // the student was saying below it" — Hugh, 2026-07-12)

    /// Deliberately no glass background/padding box — "keep it minimal": a
    /// single low-opacity line, right-aligned under the subtitle box, same
    /// max width, truncating middle so long utterances still show start and
    /// end rather than just a cut-off beginning.
    private var studentTranscriptLine: some View {
        Text("you: \(studentTranscript)")
            .font(.system(size: 12, weight: .regular, design: .default).italic())
            .foregroundStyle(.primary)
            .opacity(0.45)
            .lineLimit(1)
            .truncationMode(.middle)
            .multilineTextAlignment(.trailing)
            .frame(maxWidth: 260, alignment: .trailing)
            .padding(.horizontal, 14)
    }

    // MARK: - Connection lifecycle

    private func connect() {
        guard connection == .idle || connection == .error else { return }
        connection = .connecting
        subtitleLines = []
        currentLine = ""
        studentTranscript = ""
        resetWaveform()
        resetGestureState()
        Task {
            do {
                try await session.connect()
                await MainActor.run {
                    connection = .live
                    // One-gesture flow: if the finger that initiated this
                    // connect is still down, the hold starts right now —
                    // the "listening" caption tells the user the mic is live.
                    if pressQueuedHold {
                        pressQueuedHold = false
                        beginHold()
                    }
                }
                Task { await streamAudioLevels() }
                Task { await streamUserTranscript() }
                await streamTranscript()
            } catch {
                await MainActor.run {
                    connection = .error
                }
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                await MainActor.run {
                    if connection == .error { connection = .idle }
                }
            }
        }
    }

    private func disconnect() {
        session.endSession()
        connection = .idle
        revealTask?.cancel()
        revealTask = nil
        pendingSpeech = ""
        resetWaveform()
        resetGestureState()
    }

    private func resetGestureState() {
        isHolding = false
        isThinking = false
        pressQueuedHold = false
    }

    // MARK: - Pill gesture: hold-to-talk

    /// Fires on every press-down and press-up of the idle box AND the pill.
    /// Press-down starts a hold, press-up ends it — no tap-length
    /// classification, no double-tap. Barge-in (interrupting a speaking
    /// tutor) is just holding while it talks. From IDLE, press-down first
    /// connects, and the hold begins automatically the moment the session
    /// is live (Hugh, 2026-07-12: one gesture end-to-end — hold "Ask AI",
    /// speak, release; no tap-then-hold dance). If the finger lifts before
    /// the session is up, the queued hold is abandoned and the session just
    /// stays connected, waiting.
    private func handlePress(_ pressing: Bool) {
        switch connection {
        case .live:
            if pressing { beginHold() } else { endHold() }
        case .idle, .error:
            guard pressing else { return }
            pressQueuedHold = true
            connect() // beginHold fires from connect() once live, if still pressed
        case .connecting:
            if !pressing { pressQueuedHold = false } // released before we got up
        }
    }

    /// Set while the finger is down from an idle press, waiting on connect.
    @State private var pressQueuedHold = false

    /// Haptics (Hugh, device testing, 2026-07-12: hold state wasn't clearly
    /// felt/seen) — `.medium` on hold-start reads as "grabbed the mic",
    /// `.light` on release as a softer hand-off. `UIImpactFeedbackGenerator`
    /// prepares lazily on first use; not worth pre-warming for a push-to-talk
    /// button that isn't latency-critical the way the model round-trip is.
    private func beginHold() {
        guard !isHolding else { return }
        isHolding = true
        isThinking = false
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        Task { await session.startTalking() }
    }

    private func endHold() {
        guard isHolding else { return }
        isHolding = false
        // "…" thinking state until the first tutor transcript delta arrives
        // (cleared in `appendTranscriptDelta`) — makes release feel alive
        // instead of dead-looking during the round-trip to first audio.
        isThinking = true
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        Task { await session.stopTalking() }
    }

    /// The ✕: always ends the session outright (holding already covers
    /// interruption, so there's no separate interrupt-vs-end branch).
    private func handleClose() {
        switch connection {
        case .idle, .error:
            break
        case .connecting, .live:
            disconnect()
        }
    }

    private func streamTranscript() async {
        for await delta in session.transcriptDeltas {
            await MainActor.run {
                appendTranscriptDelta(delta)
            }
        }
    }

    // MARK: - Word-paced subtitle reveal
    //
    // Transcript deltas arrive much FASTER than the audio plays — dumping
    // them straight into the box put the text a full sentence ahead of the
    // voice (Hugh, 2026-07-12: "make sure we have the word boundary so when
    // it's speaking we know exactly what line it's on"). So deltas land in
    // `pendingSpeech`, and a reveal loop pops one word at a time at roughly
    // speech pace (Clicky's char-pacing trick, ~45ms/char clamped 90–320ms
    // per word). When the audio has stopped (`session.isSpeaking == false`)
    // the remainder flushes fast so the box never lags a finished voice.
    // ponytail: paced estimate, not true audio-timestamp alignment — the
    // Realtime API doesn't emit per-word playback timestamps over WebRTC.

    @State private var pendingSpeech = ""
    @State private var revealTask: Task<Void, Never>?

    private func appendTranscriptDelta(_ delta: String) {
        isThinking = false  // first sign of the tutor's response — see endHold()
        pendingSpeech += delta
        startRevealLoopIfNeeded()
    }

    private func startRevealLoopIfNeeded() {
        guard revealTask == nil else { return }
        revealTask = Task { @MainActor in
            while !pendingSpeech.isEmpty && !Task.isCancelled {
                let word = popNextWord()
                currentLine += word
                completeLineIfSentenceEnded(word)
                let ms = session.isSpeaking
                    ? min(max(Double(word.count) * 45, 90), 320)
                    : 25 // audio done — drain the rest quickly
                try? await Task.sleep(nanoseconds: UInt64(ms * 1_000_000))
            }
            revealTask = nil
        }
    }

    /// Pops through the next space (word + its trailing whitespace).
    private func popNextWord() -> String {
        if let spaceIdx = pendingSpeech.firstIndex(of: " ") {
            let end = pendingSpeech.index(after: spaceIdx)
            let word = String(pendingSpeech[..<end])
            pendingSpeech.removeSubrange(..<end)
            return word
        }
        let word = pendingSpeech
        pendingSpeech = ""
        return word
    }

    private func completeLineIfSentenceEnded(_ word: String) {
        guard word.contains(where: { ".!?".contains($0) }) else { return }
        subtitleLines.append(currentLine.trimmingCharacters(in: .whitespaces))
        currentLine = ""
        if subtitleLines.count > 12 {
            subtitleLines.removeFirst(subtitleLines.count - 12)
        }
    }

    // MARK: - Student transcript stream

    /// Consumes `session.userTranscript` for the life of one connection —
    /// same finish-on-`endSession()` shape as `streamAudioLevels`/
    /// `streamTranscript` below, so this loop ends on its own with no extra
    /// teardown code needed here.
    private func streamUserTranscript() async {
        for await utterance in session.userTranscript {
            await MainActor.run {
                studentTranscript = utterance
            }
        }
    }

    // MARK: - Waveform (real audio levels)

    /// Consumes `session.audioLevel` for the life of one connection; the
    /// stream finishes on `endSession()`, so this loop just ends on its own
    /// when the session goes away.
    private func streamAudioLevels() async {
        for await level in session.audioLevel {
            await MainActor.run {
                pushLevel(CGFloat(level))
            }
        }
    }

    /// Attack/decay easing so individual samples don't make the bars
    /// flicker: rises fast toward a louder sample, falls back slowly —
    /// same shape as a VU meter. Each eased sample pushes into the ring
    /// buffer, oldest falls off, so the bars scroll like a waveform.
    private static let attack: CGFloat = 0.5
    private static let decay: CGFloat = 0.15

    private func pushLevel(_ target: CGFloat) {
        let rate = target > smoothedLevel ? Self.attack : Self.decay
        smoothedLevel += (target - smoothedLevel) * rate
        barLevels.removeFirst()
        barLevels.append(smoothedLevel)
    }

    private func resetWaveform() {
        smoothedLevel = Self.idleBarLevel
        barLevels = Array(repeating: Self.idleBarLevel, count: Self.barCount)
    }
}

private enum ConnectionState: Equatable {
    case idle
    case connecting
    case live
    case error
}

/// Liquid Glass on iOS 26, `.ultraThinMaterial` fallback below it -- this
/// project's deployment target (17.0) predates the SDK it's built with.
private extension View {
    @ViewBuilder
    func glassBackground(cornerRadius: CGFloat, tint: Color? = nil) -> some View {
        if #available(iOS 26.0, *) {
            self
                .glassEffect(
                    tint.map { Glass.regular.tint($0) } ?? Glass.regular,
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
        } else {
            self
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(tint ?? .clear)
                )
        }
    }

    @ViewBuilder
    func voiceGlassID(in namespace: Namespace.ID) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffectID("voiceChrome", in: namespace)
        } else {
            self
        }
    }
}

#Preview {
    ZStack {
        Color.gray.opacity(0.2).ignoresSafeArea()
        VStack {
            HStack {
                Spacer()
                VoiceBarView(session: PreviewTutorSession())
            }
            Spacer()
        }
        .padding()
    }
}

private final class PreviewTutorSession: TutorSession {
    var isSpeaking: Bool = false
    var isConnected: Bool = false
    var transcriptDeltas: AsyncStream<String> { AsyncStream { _ in } }
    var userTranscript: AsyncStream<String> { AsyncStream { _ in } }
    var audioLevel: AsyncStream<Float> { AsyncStream { _ in } }
    func connect() async throws {}
    func pushImage(_ jpeg: Data) async {}
    func pushEvent(_ json: String) async {}
    func startTalking() async {}
    func stopTalking() async {}
    func endSession() {}
}
