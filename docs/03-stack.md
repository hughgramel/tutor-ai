# Stack: options, and what we picked

**Decision context:** 3 people, one weekend, one Swift-capable dev, output is a shipped
demo + a screen recording good enough to post on X.

**Decision rule:** the ink *is* the product. Anything that degrades ink feel loses,
because a stuttering stroke in a 60-second video kills the whole pitch.

---

## THE STACK

| Layer | Pick | Why |
|---|---|---|
| **Client** | **Native iPadOS, Swift, PencilKit (`PKCanvasView`)** | Only option with 5/5 ink. Real palm rejection, ~9ms hardware latency. |
| **AI writes ink** | **`PKStroke` built from Bézier paths, revealed via substroke slicing** | iOS 27 API. "Watch it hand-write" is native, not a hack. |
| **Voice** | **LiveKit Agents (Python) → OpenAI `gpt-realtime-2.1`** | Speech-to-speech, sub-second, strong mid-turn tool calling. LiveKit ships `agent-starter-swift`. |
| **Eyes / brain** | **Claude Opus 4.8 (vision)**, called as a tool from the voice agent | Reads messy handwritten math, *and reasons about it in the same call*. |
| **Ink reading** | Canvas snapshot → Claude vision. Stroke bounding boxes sent alongside. | No OCR SDK. Zero integration. |
| **Problem source** | PDFKit (native, free) for worksheets; Claude generates problems otherwise | Both, per your call. |
| **Storage / auth** | **None.** All in-memory, single session. | It's a weekend demo. Add when there's a second user. |

### The multi-model split (stolen from HeyClicky)

Do **not** use one model for everything. Three roles:

- **Mouth + ears** → `gpt-realtime-2.1`. Owns turn-taking, barge-in, and *deciding when to
  call a tool*. Cheap, fast, never thinks hard.
- **Eyes + brain** → **Claude Opus 4.8**. Called as a tool. Gets a canvas snapshot + stroke
  bboxes. Returns: what the student did, where they went wrong, what to say, and **what to
  write and where**. Slow, expensive, only fires when needed.
- **Hands** → local Swift. Turns the brain's structured output into real strokes.

This is why voice stays fast even though the vision call takes 2 seconds — the realtime
model can say *"okay, let me look at what you've got…"* while Claude is still thinking.
**That filler line is a feature, not a hack.** It's what a real tutor does.

---

## The one hard part

**Getting an AI to write legible, natural-looking math ink in the right place.**
Everything else is plumbing. Approach:

**Rendering it (the "wow"):**
- ❌ KaTeX/MathJax → image. Reads as typeset. Kills the effect. Rejected.
- ❌ LLM emits raw stroke coordinates. LLMs are bad at precise glyph geometry. Rejected.
- ❌ Handwriting synthesis models (DiffInk, Graves RNN). Real research, but trained on
  prose, not math notation, and none ship as an API. Not a weekend.
- ✅ **Handwriting font → glyph outlines → Bézier → `PKStroke` → animate the reveal.**
  Use a hand-drawn OFL font (**Excalifont**, or Caveat) for character shapes. On web the
  equivalent is SVG `stroke-dashoffset` animation (see `tegaki`, `vara.js`) — on PencilKit
  you get it natively via substroke slicing.
- ✅ **Annotations** (circle the mistake, underline, arrow, checkmark) → generate as
  wobbly freehand strokes directly. These are easy, and they're half the emotional impact.

**Placing it (the unglamorous part that will actually break):**
- Do **not** ask the LLM for absolute pixel coordinates from a screenshot. It will misplace
  them. Every time.
- Instead: the client already knows every student stroke's **bounding box**. Send those
  with the snapshot. The LLM returns an **anchor**, not a position:
  `{ "action": "circle", "target": "bbox_7" }` · `{ "action": "write", "latex": "x = 5", "anchor": "below:bbox_7" }`
- The client computes real pixels from real bboxes. **The AI never guesses geometry.**

---

## Options we considered and rejected

**Canvas / platform**

| Option | Ink | AI-draw | Speed | Wow | Verdict |
|---|---|---|---|---|---|
| Native Swift + PencilKit | 5 | 5 | 3 | 5 | ✅ **picked** |
| React web in iPad Safari (tldraw / perfect-freehand) | 3 | 5 | 5 | 3 | Fastest to build, but Safari **drops strokes on fast handwriting** (open bugs in both tldraw and Excalidraw) and palm rejection leaks. The ink is the product. No. |
| PWA / add-to-home-screen | 3 | 5 | 5 | 3.5 | Same WebKit engine. Zero ink improvement. Cosmetic only. |
| Swift shell + WKWebView canvas | 3 | 5 | 4 | 3.5 | Same WebKit ink as Safari. All the native friction, none of the native ink. Pointless. |
| Custom Metal / CoreGraphics renderer | 5 | 4 | 1 | 5 | Reimplementing Apple's predicted-touch pipeline in 48h. No. |
| Flutter / React Native | 3–4 | 3 | 2 | 3 | No first-party Pencil pressure. RN wrappers just re-expose PencilKit — a bridge layer for zero gain. No. |
| Electron/Mac + Wacom | 4 | 5 | 4 | 2 | Emergency fallback only. No Pencil = no story. |

**Voice**

| Option | Verdict |
|---|---|
| **LiveKit Agents + OpenAI Realtime** | ✅ **picked.** Only combo with one low-latency speech-to-speech model, proven mid-turn tool calling, *and* ready-made Swift + React clients off one backend. |
| Raw OpenAI Realtime WebRTC in Swift | Fewer moving parts, but you own `AVAudioSession`, ICE, and reconnect logic yourself. Viable fallback if LiveKit fights us. |
| Gemini Live API | Cheaper (~$0.005/min in). But **function calling is synchronous** — audio can freeze while `draw_on_canvas` runs. That is *exactly* our use case. Disqualifying. |
| Pipecat *(your original note, p1)* | Excellent and vendor-agnostic, but you assemble the STT/LLM/TTS/turn-detection pipeline yourself. One bad VAD setting silently kills barge-in at 2am. Wrong tool for a 48h build. |
| Vapi / Retell | Telephony-shaped. Tool calls come back as webhooks — an extra hop to get a draw command into the canvas. Fighting the abstraction. |
| ElevenLabs Agents | Best voice quality, but it's a voice platform bolted onto TTS — you still assemble the orchestration. |
| Cartesia | Fastest TTS (~40ms) but it's *only* TTS. Picking it means building Pipecat anyway. |

**Reading the ink**

| Option | Verdict |
|---|---|
| **Vision LLM on a canvas snapshot** | ✅ **picked.** 2026 accuracy on handwriting is genuinely good (~1.2–1.4% CER on IAM). Zero integration. And it *reasons while it reads* — it catches the error, it doesn't just transcribe. |
| Mathpix OCR | Purpose-built handwriting→LaTeX, ~$0.002/image. **Keep as a fallback**: if vision struggles on dense multi-line work, feed Mathpix's LaTeX to Claude as *extra context* — don't replace the vision call. |
| MyScript iink | Best raw accuracy (stroke dynamics, ~250 math symbols) — but enterprise licensing. Can't get a key by Saturday. |
| Apple Vision framework | Solid text OCR, but **no math notation parsing**. Math Notes uses a separate on-device VLM we can't call. |
| Raw stroke JSON → LLM | Real research direction (ink tokenizers), not hackathon-ready. Stretch goal. |

---

## Cost sanity check

- Realtime voice: **~$0.04–0.10/min** (mini variant ~⅓ that).
- Claude vision call: only fires on tool-call, not continuously. **Snapshot on demand, never on a loop** — that's HeyClicky's cost lever and it's the right one.
- A 10-minute tutoring session ≈ **well under $2**. Fine for a demo, needs a real look before we charge $15/mo.
