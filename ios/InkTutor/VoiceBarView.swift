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
    /// Wiring Step 5: the screen's one `TutorCoordinator` — its
    /// `subtitleStream` (tag-stripped) replaces `session.transcriptDeltas`
    /// as this view's transcript source, and `start()` begins consuming
    /// `session.transcriptDeltas` on the coordinator's side the moment the
    /// connection goes live.
    let coordinator: TutorCoordinator

    @State private var connection: ConnectionState = .idle
    /// Full conversation history this session — tutor lines (completed
    /// sentences from the reveal loop) interleaved with the student's
    /// completed utterances, oldest first. Compact mode shows only the
    /// tutor's own lines (`tutorLines`, same look as before this addendum);
    /// expanded mode shows all of it. A tiny `{role, text}` struct instead
    /// of two parallel arrays, since ordering across roles now matters.
    @State private var chatHistory: [ChatLine] = []
    @State private var currentLine: String = ""
    /// Student's last completed utterance, from `session.userTranscript` —
    /// the low-opacity "you: ..." line below the tutor's subtitle box.
    /// Replaced (not appended) on every completed transcription; also fed
    /// into `chatHistory` (unchanged role in the full-history view).
    @State private var studentTranscript: String = ""
    /// Tap-to-expand state for the subtitle box (addendum, 2026-07-12).
    @State private var isExpanded = false
    /// Set by a drag inside either scroll view; cleared when a new tutor
    /// response starts (`endHold()`) or the box is toggled — "don't yank
    /// the user back down after they've scrolled up, until the next
    /// response starts or they scroll back" (a real scroll-position read
    /// isn't needed for that rule, just this one flag).
    @State private var userScrolledAway = false
    @Namespace private var glassNamespace

    private static let bottomAnchorID = "subtitle-bottom"
    private static let chatHistoryCap = 100

    private var tutorLines: [ChatLine] { chatHistory.filter { $0.role == .tutor } }

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
        // Only surface "connecting" when the user is actively pressing —
        // the launch auto-connect happens silently in the background.
        if connection == .connecting && pressQueuedHold { return "connecting — hold on" }
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

            if isConnected && (!chatHistory.isEmpty || !currentLine.isEmpty) {
                subtitleContainer
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            // Redundant with the expanded panel's own interleaved student
            // lines, so only shown in compact mode.
            if isConnected && !studentTranscript.isEmpty && !isExpanded {
                studentTranscriptLine
                    .transition(.opacity)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: connection)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isExpanded)
        .animation(.easeInOut(duration: 0.2), value: studentTranscript)
        .animation(.easeInOut(duration: 0.15), value: pillCaption)
        // Auto-connect at launch (Hugh, 2026-07-12: the tap-to-connect step
        // + its "keep holding" wait was pure friction — the session opens in
        // the background while the app settles, so the first hold is
        // instantly live). The idle "Ask AI" box remains only as the
        // reconnect affordance after ✕ or an error.
        .onAppear { connect() }
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
    /// Mic glyph, not a waveform (Hugh, 2026-07-12: the waveform belongs to
    /// the live state only — idle shows what the button DOES: hold to talk).
    private var idleContent: some View {
        HStack(spacing: 8) {
            Image(systemName: "mic.fill")
                .font(.system(size: 15, weight: .semibold))
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
        Image(systemName: "stop.fill")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: 32, height: 32)
            .glassBackground(cornerRadius: 16)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .onTapGesture {
                TutorLog.shared.lifecycle("stop tapped")
                handleStop()
            }
    }

    private func barHeight(for level: CGFloat) -> CGFloat {
        let minHeight: CGFloat = 4
        let maxHeight: CGFloat = 20
        let clamped = min(max(level, 0), 1)
        return minHeight + clamped * (maxHeight - minHeight)
    }

    // MARK: - Subtitles (compact ⇄ expanded, addendum 2026-07-12)

    /// One line of session chat history — either the tutor's (from the
    /// reveal loop, completed on sentence boundaries) or the student's
    /// (from `session.userTranscript`, one completed utterance each).
    private struct ChatLine: Identifiable {
        enum Role { case tutor, student }
        let id = UUID()
        let role: Role
        let text: String
    }

    @ViewBuilder
    private var subtitleContainer: some View {
        if isExpanded {
            expandedPanel
        } else {
            subtitleBox
        }
    }

    /// Compact mode: same footprint/look as before, but now a scrollable
    /// window (tutor lines only) instead of a fixed last-2-lines slice, so
    /// the user can scroll back through recent lines without leaving
    /// compact mode. Tap anywhere to expand into the full-history panel.
    private var subtitleBox: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    // Uniform grey, whole lines only (Hugh, 2026-07-12: the
                    // emphasized live line + word-by-word reveal distracted —
                    // lines appear complete, once spoken; the word-paced loop
                    // still runs underneath purely for timing).
                    ForEach(tutorLines) { line in
                        Text(line.text)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                    }
                    Color.clear.frame(height: 1).id(Self.bottomAnchorID)
                }
                .simultaneousGesture(DragGesture(minimumDistance: 10).onChanged { _ in userScrolledAway = true })
            }
            .frame(maxHeight: 90)
            .onChange(of: currentLine) { scrollToBottomIfPinned(proxy) }
            .onChange(of: tutorLines.count) { scrollToBottomIfPinned(proxy) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 260, alignment: .leading)
        .glassBackground(cornerRadius: 16)
        .onTapGesture { toggleExpanded() }
    }

    /// Expanded mode: the full session history, tutor + student interleaved.
    /// Grows downward/leftward from below the chrome (chrome itself stays
    /// put — this is just another item further down the same trailing-
    /// aligned VStack the compact box already lived in).
    private var expandedPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Conversation")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .contentShape(Rectangle())
            .onTapGesture { toggleExpanded() }

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(chatHistory) { line in
                            chatLineView(line)
                        }
                        // (No live currentLine here either — whole lines only,
                        // same as compact mode.)
                        Color.clear.frame(height: 1).id(Self.bottomAnchorID)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .simultaneousGesture(DragGesture(minimumDistance: 10).onChanged { _ in userScrolledAway = true })
                }
                .onChange(of: currentLine) { scrollToBottomIfPinned(proxy) }
                .onChange(of: chatHistory.count) { scrollToBottomIfPinned(proxy) }
            }
        }
        .frame(width: 340, height: min(UIScreen.main.bounds.height * 0.45, 420))
        .glassBackground(cornerRadius: 18)
    }

    @ViewBuilder
    private func chatLineView(_ line: ChatLine) -> some View {
        switch line.role {
        case .tutor:
            Text(line.text)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
        case .student:
            Text("you: \(line.text)")
                .font(.system(size: 13, design: .default).italic())
                .foregroundStyle(.primary)
                .opacity(0.55)
                .multilineTextAlignment(.leading)
        }
    }

    private func toggleExpanded() {
        isExpanded.toggle()
        userScrolledAway = false
    }

    private func scrollToBottomIfPinned(_ proxy: ScrollViewProxy) {
        guard !userScrolledAway else { return }
        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
        }
    }

    private func appendChatLine(role: ChatLine.Role, text: String) {
        chatHistory.append(ChatLine(role: role, text: text))
        if chatHistory.count > Self.chatHistoryCap {
            chatHistory.removeFirst(chatHistory.count - Self.chatHistoryCap)
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
            .multilineTextAlignment(.leading)
            .frame(maxWidth: 260, alignment: .leading)
            .padding(.horizontal, 14)
    }

    // MARK: - Connection lifecycle

    private func connect() {
        guard connection == .idle || connection == .error else { return }
        connection = .connecting
        chatHistory = []
        currentLine = ""
        studentTranscript = ""
        isExpanded = false
        userScrolledAway = false
        resetWaveform()
        resetGestureState()
        Task {
            do {
                try await session.connect()
                await MainActor.run {
                    connection = .live
                    // Begin routing session.transcriptDeltas through the
                    // coordinator's TagParser right away — subtitles below
                    // read coordinator.subtitleStream, not raw deltas.
                    coordinator.start()
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
        // Stops the coordinator's transcript-routing loop so a later
        // reconnect's `coordinator.start()` doesn't no-op (it guards on
        // `transcriptTask == nil`, which naturally-finished-but-uncancelled
        // tasks don't satisfy).
        coordinator.stop()
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
            // Pressing during the (usually launch-time) connect queues the
            // hold to begin the instant we're live; releasing abandons it.
            pressQueuedHold = pressing
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
        // The next tutor response is about to start — re-pin the subtitle
        // scroll views to the bottom even if the user had scrolled away
        // reading the last one.
        userScrolledAway = false
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        Task { await session.stopTalking() }
    }

    /// The stop button (Hugh, 2026-07-12: was an end-session ✕) — kills the
    /// AI's in-flight response and clears queued subtitle text; the session
    /// itself stays connected (auto-connect world: teardown is app exit).
    private func handleStop() {
        guard connection == .live else { return }
        revealTask?.cancel()
        revealTask = nil
        pendingSpeech = ""
        isThinking = false
        Task { await session.stopSpeaking() }
    }

    private func streamTranscript() async {
        // Wiring Step 5: `coordinator.subtitleStream` — not the raw
        // `session.transcriptDeltas` — is the source here. It's the same
        // delta-shaped stream (one chunk per underlying delta), just already
        // run through `TagParser` so `[CIRCLE:7]`-style tags never reach the
        // subtitle box.
        for await text in coordinator.subtitleStream {
            await MainActor.run {
                appendTranscriptDelta(text)
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
    // speech pace. When the audio has stopped (`session.isSpeaking == false`)
    // the remainder flushes fast so the box never lags a finished voice.
    // ponytail: paced estimate, not true audio-timestamp alignment — the
    // Realtime API doesn't emit per-word playback timestamps over WebRTC.
    //
    // Addendum (2026-07-12), two refinements on top of the above:
    // 1. Anchor to audio start — deltas arrive BEFORE playback starts, so
    //    popping on the very first delta made text lead the voice at the
    //    start of every response. The loop now waits for
    //    `session.isSpeaking == true` before popping the first word of a
    //    response (bounded wait — a response with no audio at all, e.g. a
    //    hypothetical text-only reply, still drains instead of hanging).
    // 2. Self-calibrating pace — `TutorLog.shared.lastSpeechPaceMsPerChar`
    //    (measured from the previous completed response's real audio
    //    duration vs. transcript length, see `RealtimeSession`) replaces the
    //    old hardcoded 45ms/char, falling back to 45 until a response has
    //    completed at least once this app launch. Each response calibrates
    //    the next.

    @State private var pendingSpeech = ""
    @State private var revealTask: Task<Void, Never>?

    private func appendTranscriptDelta(_ delta: String) {
        isThinking = false  // first sign of the tutor's response — see endHold()
        pendingSpeech += delta
        startRevealLoopIfNeeded()
    }

    /// When the speaker was last actually producing sound — set from the
    /// measured WebRTC output level in `streamAudioLevels`, NOT from the
    /// `output_audio_buffer.started` event (`session.isSpeaking`), which was
    /// flagged unverifiable on this transport and, when it doesn't fire,
    /// let text flow at token speed (Hugh, 2026-07-12: "highlighting is
    /// still as tokens come in, not as the voice speaks").
    @State private var lastAudioEnergyAt: Date = .distantPast

    /// True while sound is measurably coming out of the speaker (with a
    /// small grace window so inter-word gaps don't stall the reveal).
    private var audioLive: Bool {
        session.isSpeaking || Date().timeIntervalSince(lastAudioEnergyAt) < 0.45
    }

    private func startRevealLoopIfNeeded() {
        guard revealTask == nil else { return }
        revealTask = Task { @MainActor in
            while !pendingSpeech.isEmpty && !Task.isCancelled {
                guard audioLive else {
                    // No sound right now. Two cases: audio hasn't started yet
                    // (or paused mid-response) → hold the text; dead air for
                    // >1.5s with words still queued → response is over or
                    // truncated, drain fast so the box never lags a finished
                    // voice.
                    if Date().timeIntervalSince(lastAudioEnergyAt) > 1.5 && !isThinking {
                        while !pendingSpeech.isEmpty && !Task.isCancelled {
                            let word = popNextWord()
                            currentLine += word
                            completeLineIfSentenceEnded(word)
                            try? await Task.sleep(nanoseconds: 25_000_000)
                        }
                        break
                    }
                    try? await Task.sleep(nanoseconds: 40_000_000)
                    continue
                }
                let word = popNextWord()
                currentLine += word
                completeLineIfSentenceEnded(word)
                let msPerChar = TutorLog.shared.lastSpeechPaceMsPerChar ?? 45
                let ms = min(max(Double(word.count) * msPerChar, 90), 320)
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
        appendChatLine(role: .tutor, text: currentLine.trimmingCharacters(in: .whitespaces))
        currentLine = ""
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
                appendChatLine(role: .student, text: utterance)
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
                // Bars react ONLY while the pill is held (Hugh, 2026-07-12:
                // no waveform activity while idle or while the tutor talks —
                // it's a "your voice" meter, not an output visualizer).
                // Feeding the idle level through the normal attack/decay path
                // lets active bars settle to flat instead of snapping.
                pushLevel(isHolding ? CGFloat(level) : Self.idleBarLevel)
                // While NOT holding, nonzero energy = the tutor's voice is
                // actually audible right now — the subtitle reveal gates on
                // this measured signal (see startRevealLoopIfNeeded).
                if !isHolding && level > 0.02 {
                    lastAudioEnergyAt = Date()
                }
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
    VoiceBarPreviewHost()
}

/// Wraps the coordinator construction in a `View.body` — `TutorCoordinator`
/// is `@MainActor`, and `body` is the one place in this file guaranteed to
/// already be main-actor-isolated (via the `View` protocol requirement),
/// rather than relying on the `#Preview` macro's own isolation.
private struct VoiceBarPreviewHost: View {
    private let session = PreviewTutorSession()

    var body: some View {
        let coordinator = TutorCoordinator(
            session: session,
            studentPage: PageModel(role: .student),
            tutorPage: PageModel(role: .tutor),
            pageSize: CGSize(width: 768, height: 1024),
            performer: PreviewAnnotationPerformer(),
            openTutorPage: {},
            writeHandler: { _, _ in [] }
        )
        return ZStack {
            Color.gray.opacity(0.2).ignoresSafeArea()
            VStack {
                HStack {
                    Spacer()
                    VoiceBarView(session: session, coordinator: coordinator)
                }
                Spacer()
            }
            .padding()
        }
    }
}

private final class PreviewAnnotationPerformer: AnnotationPerforming {
    func perform(_ annotation: Annotation, on page: PageModel) {}
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
    func stopSpeaking() async {}
    func stopTalking() async {}
    func endSession() {}
}
