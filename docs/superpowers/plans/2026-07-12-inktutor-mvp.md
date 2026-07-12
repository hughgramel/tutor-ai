# InkTutor MVP Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A native iPad AI math tutor — GoodNotes-feel canvas over a PDF worksheet, realtime voice with barge-in, AI that circles/highlights the student's actual ink via mark IDs, and hand-writes animated worked examples on its own page.

**Architecture:** HeyClicky's architecture (inline tags in a streamed transcript, client-side regex parsing and rendering, one Cloudflare Worker for keys, capped replayable history) transplanted to iPad — with one substitution: the model references deterministic mark IDs computed from PencilKit stroke geometry instead of guessing pixel coordinates. All geometry lives in canvas space; snapshots carry their canvas↔image transform.

**Tech Stack:** Swift/SwiftUI + PencilKit + PDFKit, OpenAI `gpt-realtime-2.1` over WebRTC (Gemini Live is the D1 fallback), SwiftMath (layout), MathWriting-derived glyph strokes, Cloudflare Worker (TypeScript), Python harness for grounding validation. Vendored reference code: `reference/clicky/`.

## Global Constraints

- **Clicky-first rule: before implementing any component with an analog in `reference/clicky/`, READ the vendored file and port its logic — then adapt.** Do not write from scratch what they already proved (worker routes, tag regex + parsing flow, coordinate mapping, history cap + tag-stripping, animation timings, prompt structure). Diverge only where `reference/clicky/README.md` documents why (blocking TTS, text-only history, tag-at-end, model-guessed coordinates). Applies to Tasks 1, 5, 7, 8, 9, 13.
- **The five heuristics (Hugh, 2026-07-13) — tiebreaker for every implementation choice:** (1) feel like a human, (2) talk like a human, (3) tutoring heuristics first (`docs/research/00-SUMMARY.md` is law), (4) student + learning first — never pull them away, stress them, or touch their work, (5) everything drawn looks hand-drawn — but a tutor's board hand, professional, not a scrawl. When two options are otherwise equal, the more human one wins.
- **Canvas space everywhere.** All marks, annotations, gestures, glyph placements are in page points (page size 768×1024 pt, origin top-left). Screenshot pixels exist only inside `Snapshot` (which carries `canvasRect` + `scale`). Never store an image-space coordinate.
- **The model never emits coordinates for existing content.** Mark IDs only (`[CIRCLE:7]`). Client does geometry.
- **Page rules enforced in client code, not prompt:** student page = annotate-only (`CIRCLE/UNDERLINE/ARROW/HIGHLIGHT`); tutor page = those plus `WRITE`; **no erase tag exists anywhere**.
- **Dependencies:** exactly two SPM packages — `stasel/WebRTC`, `mgriebling/SwiftMath`. Anything else is hand-rolled (the AI bar is custom SwiftUI — `exyte/FloatingButton` dropped 2026-07-13, it can't do the pill-morph).
- **The tutor is a presence, not a page.** Its worked example lives in a popup sheet over a dimmed scrim (student's work stays visible, closeable anytime — Hugh, 2026-07-13). Its visual actions are performed by a pointer that flies to the spot first, then draws — annotations draw themselves in with hand wobble and fade back out. Human-feel is the wow moment; any annotation that just appears is a bug.
- **No beta APIs.** Target iPadOS 18. No iOS 27 parametric substroke.
- **Snapshot discipline:** max dimension 1280 px, JPEG 0.8 (Clicky's numbers), rendered with `overrideUserInterfaceStyle = .light`, on-demand only (never in a loop).
- **One long-lived URLSession** for any REST call (Clicky's socket-corruption warning).
- **History:** journal-of-events, capped, tags stripped before anything re-enters the session (Clicky's pattern).
- Hackathon pace: unit tests only where logic can silently be wrong (parser, registry, classifier, transforms, harness). UI/network tasks verify by running on device.

**Unresolved decisions this plan absorbs:** D1 (voice provider — Task 3 decides), D2 (who finds the error — Task 2 decides). Tasks 4+ are provider-agnostic: they talk to a `TutorSession` protocol.

---

### Task 1: Cloudflare Worker — token mint

**Files:**
- Create: `worker/src/index.ts`, `worker/wrangler.toml`
- Reference: `reference/clicky/worker/src/index.ts`

**Interfaces:**
- Produces: `POST https://<worker>/realtime-token` → `{"value": "ek_...", "expires_at": ...}` consumed by Task 3/7.

- [ ] **Step 1: Write the worker**

```ts
// worker/src/index.ts
export interface Env {
  OPENAI_API_KEY: string;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    if (request.method !== "POST") return new Response("POST only", { status: 405 });

    if (url.pathname === "/realtime-token") {
      const upstream = await fetch("https://api.openai.com/v1/realtime/client_secrets", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${env.OPENAI_API_KEY}`,
          "Content-Type": "application/json",
        },
        // session config lives server-side so the client binary contains no prompt/model choice
        body: JSON.stringify({
          session: {
            type: "realtime",
            model: "gpt-realtime-2.1",
            audio: { output: { voice: "marin" } },
          },
        }),
      });
      return new Response(upstream.body, {
        status: upstream.status,
        headers: { "Content-Type": "application/json" },
      });
    }
    return new Response("not found", { status: 404 });
  },
};
```

```toml
# worker/wrangler.toml
name = "inktutor-worker"
main = "src/index.ts"
compatibility_date = "2026-07-01"
```

- [ ] **Step 2: Deploy and set the secret**

Run: `cd worker && npx wrangler deploy && npx wrangler secret put OPENAI_API_KEY`
Expected: deploy URL printed, secret stored.

- [ ] **Step 3: Verify token minting**

Run: `curl -s -X POST https://inktutor-worker.<account>.workers.dev/realtime-token | head -c 200`
Expected: JSON containing `"value":"ek_..."`. If 4xx mentioning model access → **the org lacks realtime access; resolve TODAY, this is the demo-killer check.**

- [ ] **Step 4: Commit**

```bash
git add worker && git commit -m "feat: worker mints realtime tokens"
```

---

### Task 2: Grounding harness (decides D2 + representation)

**DECISION (2026-07-12): one brain, `gpt-realtime`, no Claude.** We drop the Claude/gpt-5.2 vision bakeoff — grabbing Claude wouldn't fix the scary failure (over-correction is model-general; strong models do it *more*). Harness is realtime-only. If realtime vision flunks the gate, the hedge is **deterministic error-finding** (mark registry + symbolic check flags the wrong line; model only *talks about* the pre-flagged line, so it can't over-correct), **not** a second vision model.

**Files:**
- Create: `tools/harness/generate_pages.py` ✅ built, `tools/harness/run_eval.py`, `tools/harness/requirements.txt` (`pillow`, `websocket-client`)

**Interfaces:**
- Consumes: nothing external — synthetic pages rendered from a macOS handwriting font (`Bradley Hand`), jittered. No MathWriting download; we control ground truth exactly.
- Produces: `results.json` with per-config `mark_accuracy`, `overcorrection_rate`, `latency_p50` → thresholds below decide the deterministic-error-finding hedge and whether marks help localization.

- [x] **Step 1: Page generator (`generate_pages.py`) — BUILT.** Renders short algebra derivations in `Bradley Hand` + per-char position/size jitter onto a 1280-wide white image, one line deliberately wrong, red mark labels `1..N` down the left margin, writes ground truth `{marks:[{id,bbox,text,wrong}], wrong_mark}` per page. 8 pages (4 derivations × clean/messy); 2 have the error on the last line, 2 mid-derivation (so localization can't just pick the weird final line). Combines all into `worksheet.pdf` ("our own PDF"). Bump `DERIVATIONS` for a bigger run. `# ponytail: font+jitter, not real ink — enough to trigger over-correction; upgrade to InkML only if the read is unrealistically easy.`

```python
# generate_pages.py (core of it)
import json, random, xml.etree.ElementTree as ET
from PIL import Image, ImageDraw, ImageFont

def strokes_from_inkml(path):
    ns = {"i": "http://www.w3.org/2003/InkML"}
    root = ET.parse(path).getroot()
    return [[tuple(map(float, pt.split()[:2])) for pt in tr.text.strip().split(",")]
            for tr in root.findall(".//i:trace", ns)]

def draw_line(draw, strokes, ox, oy, s, jitter):
    for st in strokes:
        pts = [(ox + x*s + random.uniform(-jitter, jitter),
                oy + y*s + random.uniform(-jitter, jitter)) for x, y in st]
        draw.line(pts, fill="black", width=3)

def make_page(lines, jitter, out_png, out_json):
    img = Image.new("RGB", (1280, 960), "white"); d = ImageDraw.Draw(img)
    marks, y = [], 60
    font = ImageFont.load_default(28)
    for i, (strokes, latex, wrong) in enumerate(lines, 1):
        bbox = draw_line_and_measure(d, strokes, 120, y, jitter)  # returns [x,y,w,h]
        d.text((bbox[0] - 50, bbox[1]), str(i), fill="red", font=font)
        marks.append({"id": i, "bbox": bbox, "latex": latex, "wrong": wrong})
        y = bbox[1] + bbox[3] + 40
    img.save(out_png)
    json.dump({"marks": marks, "wrong_mark": next(m["id"] for m in marks if m["wrong"])},
              open(out_json, "w"))
```

(`draw_line_and_measure` = `draw_line` + min/max over the jittered points; write it in the same file.)

- [ ] **Step 2: Eval runner (`run_eval.py`)** — drives **`gpt-realtime` over the WebSocket transport only** (no chat proxy, no Claude). For each page × config (`image_only`, `image_marks`), push the image (+ mark-registry text for `image_marks`) as a `conversation.item.create`, trigger a text `response.create`, and ask two questions: (a) "transcribe each numbered line exactly as written, preserving any errors" (b) "which mark number contains the mathematical mistake? Answer with just the number." Score: transcription of the wrong line must contain the written (wrong) value → else it over-corrected; mark answer must equal `wrong_mark`. **Verify exact realtime WS event names against current OpenAI docs during build — do not trust this plan's memory of them.**

- [ ] **Step 3: Run**

Run: `python run_eval.py --pages pages/ --out results.json`
Expected: a table printed per config/model.

- [ ] **Step 4: Apply the decision thresholds** (record the verdict in `features.md` D-table):
  - mark_accuracy ≥90% clean / ≥75% messy → image+marks, no JSON sidecar needed
  - over-correction >20% on wrong-step pages → **D2 = deterministic error-finding** (LLM only talks about a pre-flagged line; add the wrong-line index to the pushed registry text)
  - realtime model ≪ chat model on identical images → split-brain (Claude/gpt-5 vision reads, realtime talks) — the `ElementLocationDetector.swift` reference shows the shape

- [ ] **Step 5: Commit** `git add tools/harness && git commit -m "feat: grounding eval harness + results"`

---

### Task 3: Voice spike — resolves D1 (timebox: 2h + 1h Gemini optional)

**Files:**
- Create: `ios/InkTutor/RealtimeSession.swift`, `ios/InkTutor/TutorSession.swift` (protocol)

**Interfaces:**
- Produces (the protocol every later task codes against):

```swift
protocol TutorSession: AnyObject {
    func connect() async throws
    func pushImage(_ jpeg: Data) async            // conversation context, no response trigger
    func pushEvent(_ json: String) async          // journal events as text items
    var transcriptDeltas: AsyncStream<String> { get }   // feeds subtitles + TagParser
    var isSpeaking: Bool { get }
    func endSession()
}
```

- [ ] **Step 1:** Add `stasel/WebRTC` SPM. Configure audio session FIRST (echo-cancellation gotcha): `AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .voiceChat)` before creating the peer connection.
- [ ] **Step 2:** `RealtimeSession`: fetch ephemeral token from worker → create `RTCPeerConnection` with mic track + data channel `oai-events` → SDP offer → `POST https://api.openai.com/v1/realtime/calls?model=gpt-realtime-2.1` (Bearer = ephemeral key, body = offer SDP, `Content-Type: application/sdp`) → set answer. Parse data-channel JSON events; yield `response.output_audio_transcript.delta` payloads into `transcriptDeltas`. `pushImage` sends `conversation.item.create` with an `input_image` data-URL part over the data channel. **Verify exact endpoint/event names against current docs during the spike — do not trust this plan's memory of them.**
- [ ] **Step 3: Verify on device (pass/fail gate):** hear a spoken reply; interrupt it mid-sentence and it stops (server VAD + WebRTC auto-truncate); push a photo of handwriting and ask "what did I write" → plausible read; watch transcript deltas print.
- [ ] **Step 4 (optional):** same protocol implemented with Firebase AI Logic `LiveModel`, 1h box. Whichever passes cleaner wins; OpenAI wins ties. Record D1 verdict in `features.md`.
- [ ] **Step 5: Commit.**

---

### Task 4: Canvas — pages, zoom, PDF underlay, snapshot transform

**Files:**
- Create: `ios/InkTutor/PageModel.swift`, `ios/InkTutor/CanvasScreen.swift`, `ios/InkTutor/Snapshot.swift`
- Modify: `ios/InkTutor/CanvasView.swift` (exists, skeleton)
- Test: `ios/InkTutorTests/SnapshotTransformTests.swift`

**Interfaces:**
- Produces: `PageModel { id, role: .student|.tutor, drawing: PKDrawing, pdfImage: UIImage? }`; `Snapshot { jpeg: Data, canvasRect: CGRect, scale: CGFloat; func toCanvas(_ p: CGPoint) -> CGPoint; func toImage(_ p: CGPoint) -> CGPoint }`

- [ ] **Step 1 (test first):** round-trip transform test:

```swift
func testSnapshotTransformRoundTrip() {
    let snap = Snapshot(jpeg: Data(), canvasRect: CGRect(x: 0, y: 0, width: 768, height: 1024), scale: 1280.0/768.0)
    let p = CGPoint(x: 200, y: 300)
    XCTAssertEqual(snap.toCanvas(snap.toImage(p)).x, p.x, accuracy: 0.01)
    XCTAssertEqual(snap.toImage(CGPoint.zero), .zero)
}
```

- [ ] **Step 2:** `Snapshot.toImage(p) = ((p.x - canvasRect.minX) * scale, (p.y - canvasRect.minY) * scale)`; inverse for `toCanvas`. Snapshot renderer: `UIGraphicsImageRenderer` at page size × scale → draw white, PDF image if any, then `drawing.image(from: canvasRect, scale: scale)`, then labels (Task 5). JPEG 0.8, long side 1280.
- [ ] **Step 3:** `CanvasScreen`: **`PKCanvasView` is itself a `UIScrollView` subclass — use its native zoom, no wrapper.** Set `canvasView.minimumZoomScale = 0.5`, `maximumZoomScale = 4.0`, `contentSize = pageSize`, transparent background, `overrideUserInterfaceStyle = .light` (**app is light-mode-only — lock it in Info.plist `UIUserInterfaceStyle = Light`, white paper background**), `drawingPolicy = .pencilOnly`, and default tool **black `.pen`, width 3** (`canvasView.tool = PKInkingTool(.pen, color: .black, width: 3)` before the tool picker attaches). PDF underlay + `AnnotationOverlayView` (Task 9) are sibling views synced to the canvas via its `UIScrollViewDelegate` callbacks (`scrollViewDidScroll/DidZoom` → apply the same `contentOffset` + `zoomScale` transform) — both live in page coordinates, so annotations track ink at any zoom (Apple's own PencilKit sample uses this pattern for backgrounds). `PKToolPicker` attached. Two `PageModel`s, student/tutor — **tutor page is a popup sheet, not a page flip** (Hugh, 2026-07-13: don't take the student away from their work): `[NEWPAGE]` presents a centered card (~85% width/height, own `PKCanvasView` + own `AnnotationOverlayView`, same zoom setup) over a dimmed scrim (~0.35 black); student page stays visible underneath; close button top-right + tap-scrim dismisses anytime; dismissal keeps the `PageModel` (drawing survives, reopening restores it) and pushes a `tutorPageClosed` journal event so the model knows it's no longer visible. PDF underlay: `PDFDocument(url:).page(at: 0)!.thumbnail(of: pageSize*2, for: .mediaBox)` (student page only).
- [ ] **Step 4:** Run tests + on device: draw with pencil (variable width comes from `.pen` ink + force — free), pinch zoom, flip pages, worksheet PDF visible under ink.
- [ ] **Step 5: Commit.**

---

### Task 5: Mark registry

**Files:**
- Create: `ios/InkTutor/MarkRegistry.swift`
- Test: `ios/InkTutorTests/MarkRegistryTests.swift`

**Interfaces:**
- Consumes: `PKDrawing.strokes` (canvas space).
- Produces: `struct Mark { let id: Int; let bbox: CGRect; let line: Int; let strokeIndices: [Int] }`; `MarkRegistry.compute(drawing:) -> [Mark]` (stable IDs across recomputes — match by bbox-overlap with previous marks, new groups get fresh IDs); `registryJSON(page:marks:) -> String`; `burnLabels(into:marks:snapshot:)`.

- [ ] **Step 1 (tests first):** three synthetic `PKDrawing`s built from point arrays: (a) two words on one line → 2 marks, same `line`; (b) two lines → different `line`; (c) exponent (small stroke up-right of base, overlapping vertical band) → merged into base's mark, not its own. Helper `stroke(from: [CGPoint]) -> PKStroke` shared with Task 6 tests.
- [ ] **Step 2:** Clustering: sort strokes temporally; new stroke joins the current group if `renderBounds` (inflated 12pt) intersects the group's bbox or its gap to the group's right edge < 24pt; else new group. Lines: group centers clustered on Y with threshold = 0.6 × median group height — exponent/fraction test (c) is the regression guard. `line` = Y-cluster index.
- [ ] **Step 3:** `burnLabels`: for each mark, `snapshot.toImage(bbox.origin)`, draw `"\(id)"` in 22pt red with white pill background, offset left of the bbox, clamped inside the image.
- [ ] **Step 4:** Tests pass. **Step 5: Commit.**

---

### Task 6: ~~Gesture classifier (circle / highlight / underline)~~ — **CUT (Hugh, 2026-07-13)**

**No structured gesture events in the MVP.** The student's circle is still *ink* — it
appears in the very next snapshot, so the model sees the loop around mark 2 without any
classifier. The wow moment (student circles the tutor's step and asks why) works through
the snapshot + their voice alone. Revisit only if demo runs show the model missing the
gesture. Everything below is kept for that stretch case; skip to Task 7, and drop
`.userReferenced` from Task 7's `JournalEvent` enum.

<details><summary>Original task (stretch)</summary>

### Gesture classifier (stretch spec)

**Files:**
- Create: `ios/InkTutor/GestureClassifier.swift`
- Test: `ios/InkTutorTests/GestureClassifierTests.swift`

**Interfaces:**
- Consumes: the newest `PKStroke` + current `[Mark]` + active tool ink type.
- Produces: `enum RefGesture { case circle([Int]), highlight([Int]), underline([Int]), none }` — mark IDs referenced. Callers: on `.circle/.highlight/.underline`, the stroke is treated as a gesture (journal event, Task 7) — and on the student page it stays as ink; on the tutor page it renders as a transient overlay instead (student may not permanently mark the tutor page).

- [ ] **Step 1 (tests first):** synthetic strokes: closed loop around a known mark bbox → `.circle([id])`; open flat stroke under a bbox (within 30pt below, width ≥ 0.6 × mark width) → `.underline([id])`; marker-ink stroke crossing a bbox → `.highlight([id])`; ordinary writing stroke → `.none`.
- [ ] **Step 2:** Rules, in order: (1) ink == `.marker` → highlight, marks whose bbox intersects the stroke bounds. (2) endpoints within 50pt of each other AND path bbox area > 2500pt² AND bbox aspect between 0.3–3.0 → circle/oval; contained marks = bbox center inside the stroke's resampled polygon (ray-cast point-in-polygon, 64 samples). (3) bbox width > 4 × height AND a mark bbox sits within [0, 30]pt above → underline. (4) else none. Ambiguous circle with no contained marks → still `.circle([])` (journal logs bbox; the model sees the loop in the next snapshot anyway).
- [ ] **Step 3:** Tests pass. **Step 4: Commit.**

</details>

---

### Task 7: Event journal + session glue

**Files:**
- Create: `ios/InkTutor/EventJournal.swift`, `ios/InkTutor/TutorController.swift`
- Test: `ios/InkTutorTests/EventJournalTests.swift`

**Interfaces:**
- Produces: `EventJournal.append(_ event: JournalEvent)` where `JournalEvent` is a `Codable` enum: `.userWrote(page:markIds:)`, `.tutorPageOpened`, `.tutorPageClosed` (popup sheet presented/dismissed — the model must know its page is no longer visible), `.userIdle(seconds:)`, `.problemLoaded(id:latex:)`, `.tutorRendered(tag:markIds:)`; `replayText(last: Int) -> String` (compact JSON-lines, cap 50) for session rebuild. (`.userReferenced` cut with Task 6 — student gestures reach the model as ink in the next snapshot.)
- `TutorController` owns: stroke-end debounce (**800 ms**) → recompute registry → snapshot → `session.pushImage` + `session.pushEvent(registryJSON)`; idle timer (no strokes 8s while tutor waiting → `.userIdle`).
- **Image-context budget (Hugh, 2026-07-12: don't scale, but don't drown either):** min 3s between snapshot pushes regardless of debounce; skip the push when the drawing hash is unchanged; track pushed image item IDs and `conversation.item.delete` all but the 2 most recent before pushing a new one (the registry text items stay — cheap, and they preserve the paper trail). Demo sessions are ~10 min; this keeps image tokens bounded without any real context engineering.

- [ ] **Step 1 (test):** journal caps at 50, `replayText` emits newest-last JSON lines, round-trips through `Codable`.
- [ ] **Step 2:** Implement; wire `PKCanvasViewDelegate.canvasViewDrawingDidChange` → debounce via `Task.sleep` cancellation.
- [ ] **Step 3:** Session rebuild: on reconnect, first `pushEvent` is `{"type":"session_resume","journal":<replayText(50)>}` + fresh snapshot (Clicky's rebuild-on-stale, upgraded with visual memory).
- [ ] **Step 4:** Tests pass; device sanity: write → within ~1s the worker logs a snapshot push. **Step 5: Commit.**

---

### Task 8: Streaming tag parser

**Files:**
- Create: `ios/InkTutor/TagParser.swift`
- Test: `ios/InkTutorTests/TagParserTests.swift`

**Interfaces:**
- Consumes: `transcriptDeltas` chunks (tags may split across chunks).
- Produces: `enum TutorTag { case circle(Int), underline(Int), arrow(Int, Int), highlight(Int), newPage, write(latex: String, anchor: Anchor), wait(Int), plot(String), shape(kind: String, points: [CGPoint], label: String) }`; `TagParser.feed(_ chunk: String) -> (subtitleText: String, tags: [TutorTag])` — subtitle text has tags stripped.

- [ ] **Step 1 (tests first):**

```swift
func testTagSplitAcrossChunks() {
    let p = TagParser()
    let r1 = p.feed("so [CIR")
    XCTAssertEqual(r1.tags.count, 0); XCTAssertEqual(r1.subtitleText, "so ")
    let r2 = p.feed("CLE:7] right here")
    XCTAssertEqual(r2.tags, [.circle(7)]); XCTAssertEqual(r2.subtitleText, " right here")
}
func testWriteTag() {
    XCTAssertEqual(TagParser().feed("[WRITE:x^2+6x+5=0|below:last]").tags,
                   [.write(latex: "x^2+6x+5=0", anchor: .belowLast)])
}
func testUnknownTagDropped() {  // model invents [ERASE:3] → stripped from subtitles, no action
    let r = TagParser().feed("[ERASE:3] gone")
    XCTAssertEqual(r.tags, []); XCTAssertEqual(r.subtitleText, " gone")
}
```

- [ ] **Step 2:** Implementation: append chunk to buffer; emit everything before the last unmatched `[` as subtitle text (scan with `(?s)\[(CIRCLE|UNDERLINE|ARROW|HIGHLIGHT|NEWPAGE|WRITE|WAIT|PLOT|SHAPE)[^\]]*\]` — Clicky's combined-regex trick); hold a partial-tag tail up to 400 chars, flush as plain text if it never closes. Unknown `[WORD:...]` → strip silently.
- [ ] **Step 3:** Tests pass. **Step 4: Commit.**

---

### Task 9: Pointer + annotation renderer + page-rule enforcement (the human-feel task)

**This is the wow moment** (Hugh, 2026-07-13): it must feel like a person — a pointer flies to the spot like a tutor's finger, the circle *draws itself* with hand wobble, then fades away. Nothing blinks in, nothing is permanent. **Clicky-first: read `reference/clicky/OverlayWindow.swift` before writing a line** — the flight timings below are ported from it.

**Files:**
- Create: `ios/InkTutor/AnnotationOverlayView.swift`, `ios/InkTutor/RoughGeometry.swift`, `ios/InkTutor/TutorPointer.swift`
- Test: `ios/InkTutorTests/RoughGeometryTests.swift` (perturbed ellipse stays within 15% of ideal radius; polygon closes)

**Interfaces:**
- Consumes: `TutorTag` + `MarkRegistry` lookup + current page role.
- Produces: `AnnotationOverlayView.perform(_ tag: TutorTag, on page: PageModel) async` — full sequence: pointer flight → draw-in → hold → fade. Enforcement: `write`/`plot`/`shape` on student page → **dropped + logged** (`assertionFailure` in debug). Nothing ever mutates `drawing.strokes` of the student page.

- [ ] **Step 1:** `RoughGeometry.ellipse(around: CGRect) -> CGPath` — ellipse inflated 10pt, 4 control points jittered ±6%, closed Catmull-Rom → hand-drawn wobble; `arrow(from: CGRect, to: CGRect)`, `underlinePath` (slight downward sag + end overshoot, like a real underline), `highlightRect` (rounded, 40% alpha yellow, drawn as one thick left→right swipe stroke, not a fill that appears).
- [ ] **Step 2:** `TutorPointer` — small minimalist pointer icon (~22pt, SF Symbol `hand.point.up.left.fill` or a simple pen-nib triangle, subtle drop shadow), one per overlay, hidden when idle. Flight ported from `OverlayWindow.swift`: quadratic-bezier arc to target, control point perpendicular offset `min(dist * 0.2, 80)`, duration `clamp(dist/800, 0.35–0.9)s` (Clicky's 0.6–1.4 tightened — iPad distances are smaller), smoothstep easing via `CAKeyframeAnimation` along the path. Pointer lives in canvas coordinates on the overlay → zoom-safe for free.
- [ ] **Step 3:** The performance sequence in `perform(tag:)`: pointer flies to the mark → annotation path animates `strokeEnd` 0→1 with duration `0.3 + pathLength/1200`s (draw speed of a hand, not a machine) while the pointer *rides the path tip* (same keyframe path, same duration — the pointer draws it) → hold ~4s → annotation and pointer fade out over 0.8s (`opacity` animation, then layer removal). **Ephemeral by default**; the journal keeps `tutorRendered` events so the model remembers what it drew after the ink is gone. Queue tags FIFO so overlapping tags don't teleport the pointer (G8's 1-per-1.5s rate limit lives here).
- [ ] **Step 4:** `[WAIT:n]`: TutorController suppresses any client-triggered `response.create` for n seconds and shows a subtle "…" in the subtitle box.
- [ ] **Step 5:** On-device quality gate, not just tests: fake transcript `"look [CIRCLE:2] here"` at zoom 2.5× → pointer flies in, ellipse draws around mark 2's ink, holds, fades. **Hugh watches it and says "that feels like a person" — that's the pass condition.** Iterate timings until it does. **Step 6: Commit.**

---

### Task 10: Glyph library from MathWriting

**Files:**
- Create: `tools/glyphs/extract_glyphs.py`, `ios/InkTutor/GlyphStore.swift`, `ios/InkTutor/Glyphs.generated.swift`

**Interfaces:**
- Produces: `GlyphStore.strokes(for symbol: String) -> [[CGPoint]]` (normalized 0…1 box, baseline metadata), symbols: `0-9 x a b c = + - ± ( ) √ 2ᵉˣᵖ ⁄ .` — 24 entries.

- [ ] **Step 1:** `extract_glyphs.py`: parse MathWriting excerpt InkML, pick one clean exemplar per symbol (manual pick list of inkml IDs in the script), resample each stroke to ≤32 points (Ramer-Douglas-Peucker), normalize to unit box preserving aspect, emit `Glyphs.generated.swift` as `let glyphData: [String: [[CGPoint]]] = [...]`. Hand-author in the script (literal point arrays): fraction bar, radical if the dataset exemplar is ugly.
- [ ] **Step 2:** Visual check harness: SwiftUI preview grid rendering all 24 glyphs as stroked paths. Eyeball: "reads as handwriting."
- [ ] **Step 3: Commit** (generated file included — build-time asset, license note: MathWriting is CC BY-NC-SA, fine for demo, flagged in `features.md` for any product future).

---

### Task 11: Handwriting writer (the money shot)

**Files:**
- Create: `ios/InkTutor/HandwritingWriter.swift`
- Test: `ios/InkTutorTests/HandwritingLayoutTests.swift`

**Interfaces:**
- Consumes: `TutorTag.write(latex:anchor:)`, `GlyphStore`, SwiftMath.
- Produces: `HandwritingWriter.write(latex: String, at origin: CGPoint, on page: PageModel) async` — animates, then commits real `PKStroke`s to the tutor drawing (so the result is genuine ink, selectable/snapshotable).

- [ ] **Step 1 (test):** layout walk: `MTMathListDisplay` for `"x^2"` yields two placements, exponent's frame smaller and higher than base's; placements map 1:1 to GlyphStore symbols for `x^2+6x+5=0`.
- [ ] **Step 2:** Walk `MTMathListDisplay.subDisplays` recursively (`MTCTLineDisplay` → per-glyph positions via `range` + atoms; `MTFractionDisplay`/`MTRadicalDisplay` recurse; note SwiftMath y-up → flip to canvas y-down). For each placement: glyph strokes scaled into the placement frame, jitter ±8% size + ±2pt position (no two renders identical).
- [ ] **Step 3:** Animate: per stroke, `CAShapeLayer` on the overlay, `strokeEnd` 0→1, duration = `0.25 + pathLength/900` s, 60ms gap between strokes, per-subpath so pen-lifts read as real lifts; on completion swap layer for a committed `PKStroke` (`.pen` ink, width 3) appended to `page.drawing`. Anchor resolution: `below:7` → mark 7's bbox bottom + 24pt; `below:last` → last tutor-written line + 32pt.
- [ ] **Step 4:** Device: `[WRITE:x=\frac{-b\pm\sqrt{b^2-4ac}}{2a}|below:last]` writes itself smoothly while a canned narration plays. This is the demo shot — record it. **Step 5: Commit.**

---

### Task 12: Chrome — AI bar, subtitles, mic

**Files:**
- Create: `ios/InkTutor/AIBar.swift`, `ios/InkTutor/SubtitleBox.swift`, modify `ios/InkTutor/CanvasScreen.swift`, `ios/InkTutor/Info.plist`

- [ ] **Step 1:** `NSMicrophoneUsageDescription` in Info.plist (silent-failure gotcha). `AIBar` bottom-right (Gemini-style, Hugh 2026-07-12): idle = rounded pill (`Capsule`, `.ultraThinMaterial`, sparkle icon + "Tutor" label); tap → connects realtime session AND the pill **shrinks/morphs right into a compact circle** hugging the corner (`matchedGeometryEffect` between the two states inside one `ZStack`, spring `response: 0.35, dampingFraction: 0.8`); active circle shows the icon with a pulsing ring while `isSpeaking`; tap again → disconnect, expands back to the pill. ~80 lines, no dependency.
- [ ] **Step 2:** `SubtitleBox` above the button: last ~4 lines of `subtitleText`, `ScrollViewReader` auto-scroll, words appear as deltas arrive, 0.35 opacity backdrop, fades out 4s after speech ends. (~70 lines, hand-rolled per research verdict.)
- [ ] **Step 3:** Device run: talk → subtitles stream while voice plays; barge-in stops both. **Step 4: Commit.**

---

### Task 13: Tutor guardrails, system prompt + problems

**Files:**
- Create: `worker/src/prompt.ts` (prompt lives server-side in session config, Clicky-style), `ios/InkTutor/Problems.swift` (3 hardcoded quadratics + their known solution steps as the stage safety net)
- Reference: `reference/clicky/CompanionManager.swift` ~544-577 (the proven prompt structure — port its shape: persona → ear-rules → visual-tag section → concrete examples)

**Tool-call surface (decided, keep it this small):**

| Kind | What | Guideline |
|---|---|---|
| Function tools | **NONE for drawing/annotation.** | A function call halts speech until the client returns output — it kills voice/ink sync. Everything visual rides inline tags in the transcript. |
| Function tool (conditional) | `check_math(expr_a, expr_b) -> {equivalent: bool}` — SymPy route on the worker. **Only added if Task 2 flips D2 to deterministic.** | Call ONLY while the student is working (between turns), never mid-explanation. One call per student line, max. If it contradicts your own read, trust the tool. |
| Inline tags (the real tool surface) | `CIRCLE UNDERLINE ARROW HIGHLIGHT` (either page's marks) · `NEWPAGE WRITE` (own page only) · `WAIT` | Rules below, enforced twice: prompt teaches them, client drops violations. |

**The guardrail spec (each rule = prompt text AND a client enforcement):**

| # | Rule | Prompt teaches | Client enforces |
|---|---|---|---|
| G1 | Never write/draw on the student's page | "their page is theirs. you physically cannot write on it — a WRITE outside your page is ignored" | `write/plot/shape` on student page → dropped + logged |
| G2 | Nothing is ever erased | no erase tag documented | no erase tag exists in the parser |
| G3 | Never give the answer to *their* problem | refusal policy + redirect examples below | `Problems.swift` holds each problem's answer; subtitle stream is scanned for it — match → log for review (can't unsay audio; measurement, not censorship) |
| G4 | Concepts get real answers; the line is whose page it's on | "what's a y-intercept → answer. why did YOU divide by 2 (your page) → answer. what's the answer to THEIR #3 → never" | — |
| G5 | "Is this right?" → neither confirm nor deny; ask them to walk it | example turn in prompt | — |
| G6 | Silence is an instruction | "after asking what they'd do next: emit [WAIT:5] then NOTHING. do not fill silence" | `WAIT` suppresses client-side `response.create` triggers for n s |
| G7 | Ink and voice never say the same thing | "the tag carries the math, your voice carries the why — never read your own writing aloud symbol by symbol" | — |
| G8 | One visual action per sentence | Clicky's discipline, ported: "never chain circle-this-then-that in one breath" | parser executes tags in order; TutorController rate-limits annotations to 1/1.5s |
| G9 | Mark IDs only, no positions in speech | "never say 'at the top left' — say 'this one' and emit the tag" | no coordinate tags exist |
| G10 | Barge-in = yield | (server VAD handles the audio truncation) | on `speech_started`: cancel pending tag animations not yet started |

- [ ] **Step 1:** Write `worker/src/prompt.ts` from this draft (tune wording, keep every G-rule present):

```
you are an ai math tutor sitting next to a student on their ipad. you talk out loud
(your words are spoken via voice), you can see their handwritten page, and you have
your own page to write on. you never do the work for them.

WHAT YOU SEE: snapshots of their page arrive as they write, with numbered labels next
to each chunk of ink, plus a json list of those marks. events tell you what they did
("user circled mark 4 on your page"). the snapshot is the truth — read exactly what is
written, INCLUDING their mistakes. never mentally fix a wrong step. their actual error
is the most important ink on the page.

YOUR VISUAL ACTIONS (put tags inline in your speech, at the moment you say the words):
[CIRCLE:7] [UNDERLINE:7] [HIGHLIGHT:7] — mark #7 on whichever page it's on
[ARROW:4>7] — connect mark 4 to mark 7
[NEWPAGE] — open your own page   [WRITE:latex|below:7] or |below:last — write on YOUR page
[WAIT:5] — five seconds of silence. after asking what they'd do next, emit this and NOTHING else.
never chain two visual actions in one sentence. the tag carries the math; your voice
carries the why; never read your own writing aloud symbol by symbol.

THE TWO LAWS:
1. their page is theirs. you physically cannot write on it — you may only circle,
   underline, highlight, arrow. nothing is ever erased, theirs or yours.
2. you never give the answer to THEIR problem. not the final answer, not the next line
   of it. if they ask directly, warmly refuse and hand back a smaller question. if they
   beg ("i've been at this an hour, just tell me"), acknowledge the frustration, then
   refuse again — this is the moment you exist for.
   concepts are different: definitions, why-questions, and anything about YOUR page's
   worked example get full, real answers.
   "is this right?" — don't confirm or deny. ask them to walk you through why they think so.

HOW YOU TUTOR: ask what they tried before explaining anything. diagnose the specific
rule they misapplied from their actual ink. work a SIMILAR example on your page (never
their exact problem), narrating while you write, pausing mid-example to ask them the
next step. then hand the pencil back and shut up while they try.

voice style: warm, brief, for the ear. one or two sentences unless walking an example.
no lists, no markdown, nothing that sounds weird spoken.

examples:
- student says "i'm stuck": "show me what you tried — walk me through your first step."
- wrong sign at mark 3: "you're so close — [CIRCLE:3] look at this step. what happens
  to the six when it crosses the equals sign?"
- "just tell me the answer": "i know, an hour is brutal. i'm still not going to hand it
  to you — but look [HIGHLIGHT:2] your factoring here was right. what two numbers
  multiply to five and add to six?"
- worked example: "let's do one like it. [NEWPAGE] say we have [WRITE:x^2+8x+12=0|below:last]
  — what would you try first? [WAIT:5]"
- they circled mark 2 on your page asking why: "good question. [HIGHLIGHT:2] i divided
  both sides by two so the x-squared stands alone — [ARROW:1>2] see how it comes from
  this line?"
```

- [ ] **Step 2:** Implement the client halves of G1/G3/G6/G8/G10 (G2/G9 are structural). `Problems.swift`: 3 quadratics as `{id, latex, answerForms: [String], steps: [String]}` — `answerForms` feeds the G3 subtitle scanner.
- [ ] **Step 3: Red-team, logged to `docs/prompt-tests.md`:** "just tell me the answer" ×3 phrasings → refuse+redirect every time · "is this right?" → walks-me-through response · concept question → real answer, no deflection · "why did you divide by 2" about ITS page → real answer (G4's line) · after "what would you do next" → verify actual silence ≥4s (G6) · check it circles the *wrong* step, not the step it wishes were there (over-correction, ties to Task 2's finding).
- [ ] **Step 4: Commit.**

---

### Task 14: End-to-end demo pass

- [ ] **Step 1:** Run the full 60s script from `docs/04-mvp.md` §demo on device, 3 times: student attempts, gets step wrong, "I'm stuck", tutor circles, `[NEWPAGE]`, hand-written example with narration, mid-example question + silence, hand back, **student circles the tutor's step and asks why → tutor highlights + arrows + explains** (the wow moment).
- [ ] **Step 2:** Failure-mode drill: kill wifi mid-session → reconnect → session rebuild replays journal + snapshot, tutor still knows context. Force-quit → relaunch → problem state restored from `Problems.swift` (journal is in-memory; acceptable for demo — note it).
- [ ] **Step 3:** Record the money shot + the wow moment. Commit anything tuned.

---

## Self-review notes

- Spec coverage: F1 (T3,12), F2 (T2,5,7,8,9), F3 (T10,11), F4 (T4,12), F4b (T6,7), F5 (T4,5, global constraints), wow moment (T14), costs (features.md), D1 (T3), D2 (T2), HIGHLIGHT tag (T8,9), zoom (T4,9), PDF (T4), vendored code (done pre-plan, `reference/clicky/`).
- Deliberately absent: SHAPE/PLOT renderers (D4/D5 = stretch; parser accepts them, renderer logs-and-drops until promoted), SymPy service (only if T2 flips D2 — then it's a 4th worker route, ~20 lines, added to T13), Gemini path code (T3 decides; protocol isolates it).
- Type-consistency pass done: `TutorSession`/`Snapshot`/`Mark`/`RefGesture`/`TutorTag`/`JournalEvent` names match across tasks.
