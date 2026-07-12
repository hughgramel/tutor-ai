# Gate 4 — Architecture

**Status: DRAFT.** Options and tradeoffs. Nothing decided until Hugh says so.

> Supersedes `docs/03-stack.md`, which was written before we read the HeyClicky
> source and the PencilKit API. **Two of its recommendations were wrong.** See
> "Corrections" at the bottom.

---

## 🔴 The finding that changes the plan

**Font glyphs are the wrong way to make the AI write.**

The plan was: handwriting font → glyph outlines → strokes. **It doesn't work.**
A font glyph is a **filled shape** — a closed outline you fill in, not a path a pen
travels. Trace the outline and you get **calligraphy, not handwriting** — a hollow
letter being inked around its edge. Tools that do this properly (Tegaki) use fonts
built with *skeleton* data, which Excalifont and Caveat don't have.

And it gets worse: **no handwriting font has decent math glyphs.** No radical, no
fraction bar, no exponent positioning. Excalifont and Caveat are Latin text fonts.

### The way out — and it's cheaper than the thing that doesn't work

**Don't use a font. Hand-author the strokes.**

We picked **quadratics**. Count the glyphs we actually need:

```
0 1 2 3 4 5 6 7 8 9   x   =  +  -  ±  ( )  √  ²  ⁄
```

**That's about 22 glyphs.** Draw each one **once**, by hand, as an array of points.
Store them. Add per-instance jitter (±10% size, small positional noise) so no two
renders are identical.

- It is **genuinely handwritten**, because a human hand actually wrote it.
- It solves the math-symbol gap for free — you just *draw* a radical.
- It's a couple of hours with an iPad, not a research problem.
- **It cannot look like calligraphy**, because it isn't tracing an outline.

> **This is the single highest-leverage decision in the build.** It converts the
> riskiest unknown into an afternoon of tracing.

**Layout** (where each glyph goes — fractions, exponents) is still real work.
**SwiftMath** (`mgriebling/SwiftMath`) typesets LaTeX and exposes a display tree with
per-glyph **position + glyph ID**. Walk it, and substitute *our* hand-drawn stroke for
each glyph instead of the font's. It solves the hard layout problem and we ignore its
rendering.

---

## DECIDED: `gpt-realtime` over WebRTC, with real barge-in

Performance over cost. Barge-in is the demo.

```
                          ┌──────────── the student writes ────────────┐
                          │                                            │
iPad ──WebRTC──▶ gpt-realtime ◀── canvas snapshot pushed PROACTIVELY ──┘
   (barge-in)          │              (on stroke-end, debounced)
                       │
                       └──▶ inline tags in the audio transcript ──▶ canvas draws
```

### The move that makes it fast: watch, don't fetch

**`conversation.item.create` accepts an `input_image` content part (base64 data URL), and
it is NOT gated on a user turn.** You can push an image into a live session at any moment.

So: **snapshot the canvas on stroke-end (debounced) and push it in as the student writes.**
By the time they say *"I'm stuck,"* the model has been watching the page for thirty seconds.
No tool call. No fetch. No stall. It just answers.

**This matters more than it looks, because a tool call HALTS SPEECH.** The model cannot
keep talking past a function call until you return `function_call_output` and re-trigger
`response.create`. So the obvious design — *"call a read_canvas tool when the student asks"* —
doesn't merely cost 1–3 seconds, **it stops the tutor mid-sentence to go look at the page.**
Exactly the wrong feel.

> **The difference between a tutor who picks up your paper and one who has been watching
> over your shoulder. Build the second one.**

### What we get for free
- **Barge-in.** Server VAD fires `input_audio_buffer.speech_started`, and **on WebRTC the
  server auto-truncates the in-flight response** — it tracks how much audio actually played.
  We don't hand-roll interruption.
- **Streaming transcript** — the tags arrive in it (see below).

### What it costs
- **A token-mint backend.** You cannot ship an API key in a binary. `POST /v1/realtime/client_secrets`
  mints a ~1-minute ephemeral token. One Cloudflare Worker. ~20 minutes.
- **Echo cancellation.** See gotchas. This is the real risk.
- 💸 `gpt-realtime`: ~$0.07–0.15/min. **Take it.** (`gpt-realtime-mini` is ~⅓ if cost bites.)

### The one unknown — test this Friday
**Nobody has benchmarked `gpt-realtime` on messy handwritten math.** Realtime models are
tuned for *speed*, not vision. Unverified for our exact use case.

**The fallback that doesn't change the app's shape:** if its reading is too weak, **Claude
Opus 4.8 becomes a background vision worker.** It reads the snapshot, and we inject its
*description* into the session as **text**, via the same `conversation.item.create` — still
proactive, still no stall. The realtime model borrows Claude's eyes without ever waiting on
them.

**First thing to test: hand it your worst handwriting.**

---

## 🎯 Spatial context — the model never emits a coordinate

The established answer (tldraw, Excalidraw MCP, and the whole GUI-agent literature): a
**dual channel** — a raster image for *seeing*, a structured ID registry for *pointing*.
Nobody trusts a model to emit fresh pixel coordinates. Neither will we.

**And we get the hard part for free.** Set-of-Mark prompting (Yang et al., 2023) — overlay
numbered marks on segmented regions, have the model answer with the *number* — normally
requires you to segment the image first. **PencilKit already hands us the objects.** Every
stroke is a `PKStroke` with a `renderBounds`. The segmentation is done before we start.

### IN — what we send, on stroke-end
1. **A downscaled snapshot** with **numeric labels burned in** beside each stroke-group bbox.
2. **A JSON sidecar:** `[{id: 7, bbox: [x,y,w,h], line: 2}, ...]`

### OUT — what the model emits, inline in its speech
```
"Okay, so [CIRCLE:7] right here you dropped the sign — let me show you.
 [NEWPAGE] [WRITE:x^2+6x+5=0|below:last] ..."
```

| Tag | Means | Allowed on |
|---|---|---|
| `[CIRCLE:7]` `[UNDERLINE:7]` `[ARROW:4→7]` | annotate mark #7 | ✅ student's page |
| `[NEWPAGE]` `[WRITE:latex\|below:7]` | write | ✅ **AI's page only** |
| `[PLOT:y=(x-2)^2-1]` | plot | ✅ AI's page |
| `[WAIT:5]` | shut up | — |
| ~~erase~~ | | ❌ **doesn't exist** |

> **The model says *what*. The client computes *where*.** It references mark #7; the client
> already knows mark #7's real `renderBounds` and does the geometry. **A coordinate is never
> spoken, so a coordinate can never be misplaced.**

### Corollary: never ask it to draw the parabola
It emits the **equation** (`[PLOT:y=(x-2)^2-1]`); the client plots it. LLMs are measurably
bad at freeform curve geometry (SVGenius, arXiv 2506.03139 — they lose the internal
coordinate system as complexity rises) and *very* good at algebra they already know. Plot it
client-side and add hand-drawn wobble. Same rule as the circles.

---

## 🎯 Steal this regardless of the path: inline tags, not tool calls

**HeyClicky does not use JSON tool calling.** Claude is prompted to emit **tags inline
in its streaming text** — `[POINT:x,y:label]` — and the app **string-parses them out of
the stream** and fires the animation immediately.

```
Claude streams:  "Okay, so [CIRCLE:stroke_7] right here you dropped the sign —
                  let me show you. [NEWPAGE] [WRITE:x^2+6x+5=0|below:last] ..."
                          ▲                    ▲
                  ink fires HERE       ink fires HERE
                  (mid-sentence, while the voice is still talking)
```

**Why this matters more for us than it did for them:** the research says the ink and the
voice must be **temporally contiguous** — the tutor says *"we complete the square"* **while
the square appears.** With real tool calling, the AI finishes its turn, returns a struct,
*then* you draw. **With tags, the ink appears mid-sentence.** The sync *is* the product,
and this is how you get it.

It's a string parser. Not an architecture.

## The tool surface (whatever the transport)

The rules from `docs/04-mvp.md` are enforced **in the client**, not the prompt:

| Tag | Target |
|---|---|
| `[CIRCLE:stroke_7]` `[UNDERLINE:...]` `[ARROW:...]` | ✅ the student's page — **annotate only** |
| `[NEWPAGE]` `[WRITE:latex\|anchor]` | ✅ the **AI's own page** — never the student's |
| `[WAIT:5]` | silence is a first-class instruction |
| ~~erase~~ | **does not exist** |

**The AI never emits pixel coordinates.** It anchors to `stroke_N` — and the client
already knows every stroke's real bounding box (`PKStroke.renderBounds`, which correctly
includes ink width). The client does the geometry. *The model never guesses where things are.*

---

## PencilKit — the API, confirmed

**Reading the student's ink**
- `canvasView.drawing.strokes` → `[PKStroke]`
- `stroke.renderBounds` → the bbox, **including ink width**. Use this, not a hand-rolled
  bbox from raw points.
- Grouping strokes into "lines"/equations: **no built-in.** Cluster on temporal order
  first, spatial proximity second. Fractions and exponents break naive Y-clustering.

**Snapshotting for Claude** — `PKDrawing.image(from:scale:)`
- ⚠️ **Background is transparent, and PencilKit's default ink flips to near-white in dark
  mode.** Flatten onto white without handling this and *the student's work disappears.*
  → Force `canvasView.overrideUserInterfaceStyle = .light` and set ink color explicitly.
- Main-thread bound. **Snapshot on demand, never in a loop** — it's also the cost lever.

**Writing the AI's ink** — confirmed
```swift
let points = coords.map { PKStrokePoint(location: $0, timeOffset: t, size: sz,
                                        opacity: 1, force: 1, azimuth: 0, altitude: .pi/2) }
let path   = PKStrokePath(controlPoints: points, creationDate: Date())
let stroke = PKStroke(ink: PKInk(.pen, color: .black), path: path)
canvas.drawing = PKDrawing(strokes: canvas.drawing.strokes + [stroke])  // PKDrawing is immutable
```
Use **`.pen`** — constant width, closest to handwriting. `.marker` is flat, `.pencil` is noisy.

**Animating the reveal** — *"watch it write"*
- iOS 27 added a **parametric subscript**: `stroke[0.0...t]` returns a substroke.
  Drive `t` on a `CADisplayLink`. (WWDC26 session 203. The exact symbol is **unverified**
  — check the SDK header before relying on it.)
- **Fallback if it isn't there:** slice the `[PKStrokePoint]` array progressively and
  rebuild. Same effect, ten more lines.
- **Safer fallback:** animate a `CAShapeLayer`'s `strokeEnd` 0→1 on an overlay, then commit
  the real `PKStroke` at the end. Decouples the animation from PencilKit entirely.

**Annotations** (circle the error) — **easy, and half the emotional payoff.**
Generate an ellipse/arrow geometrically around `renderBounds`, then apply rough.js's
perturbation (jitter the endpoints and two points near the 50%/75% marks, curve through
them). Ports to Swift in a few lines.

---

## The rest

- **Claude:** no official Swift SDK. Plain `URLSession` POST to `api.anthropic.com/v1/messages`,
  canvas snapshot as a base64 image block. **No dependency.**
  `claude-opus-4-8` — $5/$25 per Mtok.
- **Keys:** ship none in the binary. **One Cloudflare Worker** proxying every vendor —
  exactly what HeyClicky does (3 routes: `/chat`, `/tts`, `/transcribe-token`).
- **Math verification:** LLMs hallucinate steps. A **~20-line SymPy service**
  (`simplify(a - b) == 0`) is the only real option — Swift math libs are *evaluators*, not
  a CAS, and can't tell you two forms are equivalent. **Hardcode the 3 demo problems as a
  stage safety net regardless.**
- **One long-lived `URLSession`.** HeyClicky's warning: a session per request corrupts the
  OS connection pool → *"Socket is not connected."*
- **Steal their TLS warmup** — pre-open the HTTPS connection before you need it.

## Gotchas that will eat Saturday night

1. **Echo cancellation (Path A only).** Set `AVAudioSession` to `.playAndRecord` + `.voiceChat`
   **before** starting the session, or the AI hears its own voice and interrupts itself —
   indistinguishable from a real barge-in. There's a 2–5s adaptation lag at session start.
   **This is a build item, not polish.** (Path B has none of this.)
2. **Dark mode eats the ink** on snapshot. See above.
3. **`NSMicrophoneUsageDescription`** must be in Info.plist or audio silently fails.
4. **Confirm the OpenAI org has realtime-model access** before demo day — some accounts
   gate it behind spend tiers. (Path A only.)

---

## Corrections to `docs/03-stack.md`

Both came from reasoning about press coverage instead of reading source. Logged so we
don't repeat them.

1. **"Use LiveKit."** ❌ LiveKit does not connect a client to OpenAI. It routes
   iPad → LiveKit edge → **a backend agent process you write and deploy** → OpenAI. It
   doesn't remove a backend, it adds one, plus a service. **Cut.**
2. **"HeyClicky is GPT-Realtime + Claude + Codex, multi-model router, always-on VAD."**
   ❌ **Fiction, from the press.** The actual repo is push-to-talk, AssemblyAI + Claude +
   ElevenLabs, no VAD, no tool calling, two SPM dependencies.
3. **"AssemblyAI and ElevenLabs are dead weight."** ❌ They are literally what the viral
   app ships. They're only dead weight *if* we choose Path A.
