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
        if isHolding { return "listening" }
        if isThinking { return "…" }
        return nil
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 10) {
            if isConnected && !subtitleLines.isEmpty {
                subtitleBox
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if isConnected && !studentTranscript.isEmpty {
                studentTranscriptLine
                    .transition(.opacity)
            }

            if let pillCaption {
                Text(pillCaption)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }

            morphingChrome
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
    @ViewBuilder
    private var morphingChrome: some View {
        let content = Group {
            switch connection {
            case .idle, .error:
                idleBox
            case .connecting, .live:
                // Spacing widened 8 -> 10 (Hugh, device testing, 2026-07-12:
                // ✕ wasn't reliably closing the session) — extra separation
                // from the pill's touch area, on top of the closeButton hit
                // target fix below.
                HStack(spacing: 10) {
                    waveformPill
                    closeButton
                }
            }
        }

        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 16) {
                content
            }
        } else {
            content
        }
    }

    // MARK: - Idle state

    /// Idle: a static mini-waveform as the icon — the button previews the
    /// interaction it starts — plus a soft top sheen for the glossy read.
    private static let idleWaveHeights: [CGFloat] = [7, 13, 18, 11, 6]

    private var idleBox: some View {
        Button(action: connect) {
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
            .padding(.horizontal, 18)
            .padding(.vertical, 13)
        }
        .buttonStyle(.plain)
        .glassBackground(cornerRadius: 26, tint: connection == .error ? .red.opacity(0.15) : nil)
        .overlay(
            // glossy sheen: bright top edge fading out mid-capsule
            Capsule()
                .fill(LinearGradient(colors: [.white.opacity(0.35), .clear],
                                     startPoint: .top, endPoint: .center))
                .allowsHitTesting(false)
        )
        .clipShape(Capsule())
        .voiceGlassID(in: glassNamespace)
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
    private var waveformPill: some View {
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
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .glassBackground(cornerRadius: 22)
        .voiceGlassID(in: glassNamespace)
        .opacity(connection == .connecting ? 0.55 : 1.0)
        .scaleEffect(isHolding ? 1.12 : (connection == .connecting ? 0.97 : 1.0))
        .animation(
            connection == .connecting
                ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
                : .spring(response: 0.25, dampingFraction: 0.7),
            value: connection
        )
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isHolding)
        .animation(.easeOut(duration: 0.08), value: barLevels)
        .onAppear(perform: resetWaveform)
        .onLongPressGesture(minimumDuration: 0.01, maximumDistance: 60, perform: {}, onPressingChanged: handlePress)
    }

    // MARK: - Close button

    /// Visible glass chip stays 32x32 (unchanged look); the tappable area
    /// is padded out to 44x44 to clear Apple's HIG minimum touch target
    /// (Hugh, device testing, 2026-07-12: ✕ wasn't reliably registering).
    private var closeButton: some View {
        Button(action: handleClose) {
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
        .glassBackground(cornerRadius: 16)
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
    }

    private func barHeight(for level: CGFloat) -> CGFloat {
        let minHeight: CGFloat = 4
        let maxHeight: CGFloat = 20
        let clamped = min(max(level, 0), 1)
        return minHeight + clamped * (maxHeight - minHeight)
    }

    // MARK: - Subtitles

    private var subtitleBox: some View {
        VStack(alignment: .trailing, spacing: 3) {
            ForEach(Array(subtitleLines.suffix(3).enumerated()), id: \.offset) { index, line in
                Text(line)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .opacity(subtitleOpacity(forDistanceFromEnd: subtitleLines.suffix(3).count - 1 - index))
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
                await MainActor.run { connection = .live }
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
        resetWaveform()
        resetGestureState()
    }

    private func resetGestureState() {
        isHolding = false
        isThinking = false
    }

    // MARK: - Pill gesture: hold-to-talk

    /// Fires on every press-down and press-up of the pill. Press-down
    /// starts a hold, press-up ends it — no tap-length classification, no
    /// double-tap. Barge-in (interrupting a speaking tutor) is just
    /// holding while it talks; `RealtimeSession.startTalking` handles that.
    private func handlePress(_ pressing: Bool) {
        guard connection == .live else { return }
        if pressing {
            beginHold()
        } else {
            endHold()
        }
    }

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

    private func appendTranscriptDelta(_ delta: String) {
        isThinking = false  // first sign of the tutor's response — see endHold()
        currentLine += delta
        // A line break lands whenever the delta contains sentence-ending
        // punctuation followed by a space -- good enough for subtitle
        // cadence without needing full sentence parsing.
        if delta.contains(where: { ".!?".contains($0) }) {
            subtitleLines.append(currentLine.trimmingCharacters(in: .whitespaces))
            currentLine = ""
            if subtitleLines.count > 12 {
                subtitleLines.removeFirst(subtitleLines.count - 12)
            }
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
