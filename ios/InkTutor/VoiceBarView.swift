import SwiftUI

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

    private var isConnected: Bool { connection == .live || connection == .connecting }

    var body: some View {
        VStack(alignment: .trailing, spacing: 10) {
            if isConnected && !subtitleLines.isEmpty {
                subtitleBox
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            morphingChrome
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: connection)
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
                HStack(spacing: 8) {
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

    private var idleBox: some View {
        Button(action: connect) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 16, weight: .semibold))
                Text("Ask AI")
                    .font(.system(size: 15, weight: .medium))
            }
            .foregroundStyle(connection == .error ? .red : .primary)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
        .glassBackground(cornerRadius: 22, tint: connection == .error ? .red.opacity(0.15) : nil)
        .voiceGlassID(in: glassNamespace)
    }

    // MARK: - Waveform pill

    /// No `Button` here — `onLongPressGesture(minimumDuration: 0.01, ...)`
    /// is used purely for its `onPressingChanged` press-down/press-up
    /// edges, which map directly onto hold-to-talk start/stop.
    private var waveformPill: some View {
        HStack(spacing: 3) {
            ForEach(Array(barLevels.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(.primary.opacity(0.8))
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
        .scaleEffect(isHolding ? 1.04 : (connection == .connecting ? 0.97 : 1.0))
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

    private var closeButton: some View {
        Button(action: handleClose) {
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
        .glassBackground(cornerRadius: 16)
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

    // MARK: - Connection lifecycle

    private func connect() {
        guard connection == .idle || connection == .error else { return }
        connection = .connecting
        subtitleLines = []
        currentLine = ""
        resetWaveform()
        resetGestureState()
        Task {
            do {
                try await session.connect()
                await MainActor.run { connection = .live }
                Task { await streamAudioLevels() }
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

    private func beginHold() {
        guard !isHolding else { return }
        isHolding = true
        Task { await session.startTalking() }
    }

    private func endHold() {
        guard isHolding else { return }
        isHolding = false
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
    var audioLevel: AsyncStream<Float> { AsyncStream { _ in } }
    func connect() async throws {}
    func pushImage(_ jpeg: Data) async {}
    func pushEvent(_ json: String) async {}
    func startTalking() async {}
    func stopTalking() async {}
    func endSession() {}
}
