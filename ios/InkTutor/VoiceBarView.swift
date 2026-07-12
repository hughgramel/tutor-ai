import SwiftUI

/// Top-right voice chrome (Hugh, 2026-07-12): idle glass box with a mic/
/// sparkle icon + label -> tap connects the realtime session and the box
/// collapses into a compact waveform pill you talk to -> tap again ends the
/// session and it expands back to idle. A subtitle box streams the tutor's
/// words under the pill while connected.
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

    /// Fake amplitude bars while connected — real metering is a later pass.
    /// ponytail: driven by a timer, not the actual mic/output signal.
    @State private var barLevels: [CGFloat] = [0.3, 0.5, 0.3, 0.5, 0.3]
    @State private var waveformTimer: Timer?

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
        .onChange(of: session.isSpeaking) { _, _ in } // keeps the pill re-evaluating amplitude while live
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
                waveformPill
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
        Button(action: handleTap) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 16, weight: .semibold))
                Text("Ask your tutor")
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

    private var waveformPill: some View {
        Button(action: handleTap) {
            HStack(spacing: 4) {
                ForEach(0..<barLevels.count, id: \.self) { i in
                    Capsule()
                        .fill(.primary.opacity(0.75))
                        .frame(width: 3, height: 16 * barLevels[i])
                }
            }
            .frame(width: 56, height: 32)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .glassBackground(cornerRadius: 22)
        .voiceGlassID(in: glassNamespace)
        .opacity(connection == .connecting ? 0.55 : 1.0)
        .scaleEffect(connection == .connecting ? 0.97 : 1.0)
        .animation(
            connection == .connecting
                ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
                : .default,
            value: connection
        )
        .onAppear(perform: startWaveformTimer)
        .onDisappear(perform: stopWaveformTimer)
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

    // MARK: - Actions

    private func handleTap() {
        switch connection {
        case .idle, .error:
            connect()
        case .connecting, .live:
            disconnect()
        }
    }

    private func connect() {
        connection = .connecting
        subtitleLines = []
        currentLine = ""
        Task {
            do {
                try await session.connect()
                await MainActor.run { connection = .live }
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
        stopWaveformTimer()
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

    // MARK: - Fake waveform

    private func startWaveformTimer() {
        stopWaveformTimer()
        waveformTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { _ in
            Task { @MainActor in
                let active = session.isSpeaking
                barLevels = barLevels.map { _ in
                    active ? CGFloat.random(in: 0.3...1.0) : CGFloat.random(in: 0.15...0.4)
                }
            }
        }
    }

    private func stopWaveformTimer() {
        waveformTimer?.invalidate()
        waveformTimer = nil
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
    var transcriptDeltas: AsyncStream<String> { AsyncStream { _ in } }
    func connect() async throws {}
    func pushImage(_ jpeg: Data) async {}
    func pushEvent(_ json: String) async {}
    func endSession() {}
}
