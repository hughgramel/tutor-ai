# OpenAI Realtime API — turn detection & audio input

Distilled from `developers.openai.com/api/docs/guides/realtime-vad` +
`/realtime-conversations` (fetched 2026-07-12). Not from memory. Model in use:
`gpt-realtime-2.1`, WebRTC transport. Session config nests everything under
`session.audio.input.*`.

## Three turn-detection modes

`session.audio.input.turn_detection`:

| Mode | `type` | How it decides the turn ended | Auto-replies? |
|---|---|---|---|
| **Manual** (what we use now) | `null` | It doesn't. Client sends `input_audio_buffer.commit` then `response.create`. | No — client triggers |
| **Server VAD** | `server_vad` | Silence/energy threshold. Chunks on a gap. | Yes (if `create_response`) |
| **Semantic VAD** | `semantic_vad` | A classifier reads the *words* and scores "is the user done." Trailing "ummm…" → longer wait; a definitive sentence → replies fast. | Yes (if `create_response`) |

### server_vad params
- `threshold` (0–1) — activation loudness. Higher = needs louder audio, **for noisy rooms**.
- `prefix_padding_ms` — audio kept before detected speech start.
- `silence_duration_ms` — silence before it calls the turn over. Shorter = snappier, more false cutoffs.
- `create_response` (bool) — auto-fire a reply on turn end.
- `interrupt_response` (bool) — allow the user's speech to interrupt a speaking model.

### semantic_vad params
- `eagerness`: `low` | `medium` | `high` | `auto` (=medium). Tunes the max wait timeout.
  - `high` — replies ASAP, interrupts more.
  - `low` — lets the user ramble uninterrupted; larger transcript chunks.
- `create_response`, `interrupt_response` — same as server_vad.
- **No `threshold`.** You cannot raise a loudness gate on semantic VAD.

## Manual mode (our current path)
- `turn_detection: null` → server never auto-commits. Client owns the turn.
- `input_audio_buffer.commit` — commit buffered audio + kick off input transcription.
- `response.create` — start generation.
- This is the documented push-to-talk pattern. What we do on hold-release.

## Barge-in / interruption (WebRTC)
- Server **auto-truncates** unplayed output audio on user interruption — it knows how much
  has actually played. No client `conversation.item.truncate` needed (that's the WebSocket path).
- So on WebRTC, our manual `response.cancel` on hold-start is belt-and-suspenders; the server
  already handles truncation. Worth confirming on device which one actually stops the audio.

## Input noise reduction — NOT YET FETCHED / NOT SET IN OUR WORKER
- `session.audio.input.noise_reduction` exists (`near_field` / `far_field`) but the VAD/
  conversations guides above didn't carry the details. **We do not set it today.** This is the
  most likely "using it wrong" for the ambient-noise problem — see analysis. Fetch the audio
  guide and decide near_field (device held close) vs far_field before any VAD spike.

## Limits
- Max session length: **60 min**. No documented idle auto-disconnect.
