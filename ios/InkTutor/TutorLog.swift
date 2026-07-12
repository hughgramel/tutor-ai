import Foundation
import os

/// Observability for the realtime session: every line goes to `os.Logger`
/// (so `log stream --predicate 'subsystem == "com.tutorai.inktutor"'` or
/// Console.app shows it live) and is mirrored into a small in-memory ring
/// buffer for a future on-device debug view. Deliberately lazy — no
/// persistence, no file export, no settings. Restart the app and it's gone.
final class TutorLog {
    static let shared = TutorLog()

    struct Entry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let text: String
    }

    /// Per-response token usage, accumulated for the life of the session.
    /// Field names mirror the Realtime API's `input_token_details` /
    /// `output_token_details` / `cached_tokens_details` (verified against
    /// developers.openai.com/api/docs on 2026-07-12 — see `recordResponseDone`).
    struct SessionTokenTotals {
        var inputText = 0
        var inputAudio = 0
        var inputImage = 0
        var inputCached = 0
        var outputText = 0
        var outputAudio = 0
        var totalTokens = 0
    }

    /// Snapshot of the ring buffer for a debug UI to read. Not reactive
    /// (no Combine/@Published) — a debug view can poll it; that's the whole
    /// point of keeping this lazy.
    var entries: [Entry] {
        lock.lock(); defer { lock.unlock() }
        return buffer
    }

    var sessionCost: Double {
        lock.lock(); defer { lock.unlock() }
        return _sessionCost
    }

    var sessionTokens: SessionTokenTotals {
        lock.lock(); defer { lock.unlock() }
        return _sessionTokens
    }

    private let logger = Logger(subsystem: "com.tutorai.inktutor", category: "realtime")
    private let lock = NSLock()
    private var buffer: [Entry] = []
    private var _sessionCost: Double = 0
    private var _sessionTokens = SessionTokenTotals()
    private var transcriptDeltaCount = 0

    // ponytail: ring buffer capped at 200 entries. This is a live debug
    // aid, not an audit trail — oldest lines just fall off.
    private let ringCapacity = 200
    // ponytail: transcript deltas arrive many times a second while the
    // model is speaking; logging every one would drown everything else.
    // Sample every Nth and let the running count speak for the rest.
    private let transcriptSampleRate = 20

    private init() {}

    // MARK: - Public logging surface

    func lifecycle(_ event: String) {
        logger.info("lifecycle: \(event, privacy: .public)")
        record("lifecycle: \(event)")
    }

    func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        record(message)
    }

    func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        record("ERROR: \(message)")
    }

    /// Call for every data-channel SEND: item creates (image/text), session
    /// updates, anything passed through `RealtimeSession.send`.
    func sent(type: String, byteCount: Int) {
        info("send \(type) (\(byteCount) bytes)")
    }

    /// Call for every data-channel RECEIVE, before any app-level handling.
    /// `raw` is the fully decoded JSON object for that event.
    func received(type: String, raw: [String: Any]) {
        if type.hasSuffix("transcript.delta") {
            recordTranscriptDelta(type: type)
            return
        }
        if type.hasPrefix("response.function_call") || isFunctionCallItemEvent(type: type, raw: raw) {
            logToolCall(type: type, raw: raw)
            return
        }
        if type == "response.done" {
            recordResponseDone(raw: raw)
            return
        }
        info("recv \(type)\(summarize(raw))")
    }

    // MARK: - Transcript sampling

    private func recordTranscriptDelta(type: String) {
        lock.lock()
        transcriptDeltaCount += 1
        let count = transcriptDeltaCount
        lock.unlock()
        guard count % transcriptSampleRate == 0 else { return }
        info("recv \(type) (aggregate: \(count) deltas this session)")
    }

    // MARK: - Tool calls (logged in full — never truncated/summarized)

    private func isFunctionCallItemEvent(type: String, raw: [String: Any]) -> Bool {
        guard type == "response.output_item.done" || type == "conversation.item.created" else { return false }
        guard let item = raw["item"] as? [String: Any] else { return false }
        return (item["type"] as? String) == "function_call"
    }

    private func logToolCall(type: String, raw: [String: Any]) {
        info("recv \(type) [tool call] \(compactJSON(raw))")
    }

    // MARK: - Cost tracking

    // gpt-realtime-2.1 price table, USD per 1M tokens, verified against
    // developers.openai.com/api/docs/pricing on 2026-07-12 (not pulled from
    // the API — OpenAI returns token counts, not prices).
    private static let audioInRatePerToken = 32.00 / 1_000_000
    private static let audioOutRatePerToken = 64.00 / 1_000_000
    private static let textInRatePerToken = 4.00 / 1_000_000
    private static let textOutRatePerToken = 24.00 / 1_000_000  // transcript stream is billed text output
    private static let imageInRatePerToken = 5.00 / 1_000_000
    private static let cachedInRatePerToken = 0.40 / 1_000_000

    /// `raw` is the full `response.done` event. Usage lives at
    /// `response.usage` per the Realtime API's event-wraps-resource
    /// convention (mirrors `response.created`, `conversation.item.created`,
    /// etc.) — field names verified via developers.openai.com/api/docs
    /// (realtime-costs guide + server-events reference) on 2026-07-12:
    /// usage.{total_tokens, input_tokens, output_tokens,
    /// input_token_details.{text_tokens, audio_tokens, image_tokens,
    /// cached_tokens, cached_tokens_details.{text_tokens, audio_tokens,
    /// image_tokens}}, output_token_details.{text_tokens, audio_tokens}}.
    private func recordResponseDone(raw: [String: Any]) {
        let response = raw["response"] as? [String: Any]
        guard let usage = (response?["usage"] as? [String: Any]) ?? (raw["usage"] as? [String: Any]) else {
            info("recv response.done (no usage block)")
            return
        }

        let inputDetails = usage["input_token_details"] as? [String: Any] ?? [:]
        let cachedDetails = inputDetails["cached_tokens_details"] as? [String: Any] ?? [:]
        let outputDetails = usage["output_token_details"] as? [String: Any] ?? [:]

        let inText = inputDetails["text_tokens"] as? Int ?? 0
        let inAudio = inputDetails["audio_tokens"] as? Int ?? 0
        let inImage = inputDetails["image_tokens"] as? Int ?? 0
        let inCachedTotal = inputDetails["cached_tokens"] as? Int ?? 0
        let cachedText = cachedDetails["text_tokens"] as? Int ?? 0
        let cachedAudio = cachedDetails["audio_tokens"] as? Int ?? 0
        let cachedImage = cachedDetails["image_tokens"] as? Int ?? 0
        let outText = outputDetails["text_tokens"] as? Int ?? 0
        let outAudio = outputDetails["audio_tokens"] as? Int ?? 0
        let totalTokens = usage["total_tokens"] as? Int ?? 0

        // Non-cached portion of each input modality at its full rate, plus
        // the cached portion (any modality) at the flat cached rate.
        let cost =
            Double(max(0, inText - cachedText)) * Self.textInRatePerToken +
            Double(max(0, inAudio - cachedAudio)) * Self.audioInRatePerToken +
            Double(max(0, inImage - cachedImage)) * Self.imageInRatePerToken +
            Double(inCachedTotal) * Self.cachedInRatePerToken +
            Double(outAudio) * Self.audioOutRatePerToken +
            Double(outText) * Self.textOutRatePerToken

        lock.lock()
        _sessionTokens.inputText += inText
        _sessionTokens.inputAudio += inAudio
        _sessionTokens.inputImage += inImage
        _sessionTokens.inputCached += inCachedTotal
        _sessionTokens.outputText += outText
        _sessionTokens.outputAudio += outAudio
        _sessionTokens.totalTokens += totalTokens
        _sessionCost += cost
        let runningCost = _sessionCost
        lock.unlock()

        let line = String(
            format: "recv response.done usage: in(text=%d audio=%d image=%d cached=%d) out(text=%d audio=%d) cost=$%.4f session_total=$%.4f",
            inText, inAudio, inImage, inCachedTotal, outText, outAudio, cost, runningCost
        )
        info(line)
    }

    // MARK: - Helpers

    private func summarize(_ raw: [String: Any]) -> String {
        var parts: [String] = []
        if let itemId = raw["item_id"] as? String { parts.append("item=\(itemId)") }
        if let responseId = raw["response_id"] as? String { parts.append("response=\(responseId)") }
        if let error = raw["error"] as? [String: Any] {
            parts.append("error=\(error["message"] as? String ?? "\(error)")")
        }
        return parts.isEmpty ? "" : " (\(parts.joined(separator: ", ")))"
    }

    private func compactJSON(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return "\(object)" }
        return String(data: data, encoding: .utf8) ?? "\(object)"
    }

    private func record(_ text: String) {
        lock.lock()
        buffer.append(Entry(timestamp: Date(), text: text))
        if buffer.count > ringCapacity {
            buffer.removeFirst(buffer.count - ringCapacity)
        }
        lock.unlock()
    }
}
