# InkTutor MVP Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A native iPad AI math tutor — GoodNotes-feel canvas over a PDF worksheet, realtime voice with barge-in, AI that circles/highlights the student's actual ink via mark IDs, and hand-writes animated worked examples on its own page.

**Architecture:** HeyClicky's architecture (inline tags in a streamed transcript, client-side regex parsing and rendering, one Cloudflare Worker for keys, capped replayable history) transplanted to iPad — with one substitution: the model references deterministic mark IDs computed from PencilKit stroke geometry instead of guessing pixel coordinates. All geometry lives in canvas space; snapshots carry their canvas↔image transform.

**Tech Stack:** Swift/SwiftUI + PencilKit + PDFKit, OpenAI `gpt-realtime-2.1` over WebRTC (Gemini Live is the D1 fallback), SwiftMath (layout), MathWriting-derived glyph strokes, Cloudflare Worker (TypeScript), Python harness for grounding validation. Vendored reference code: `reference/clicky/`.

## Global Constraints

- **Canvas space everywhere.** All marks, annotations, gestures, glyph placements are in page points (page size 768×1024 pt, origin top-left). Screenshot pixels exist only inside `Snapshot` (which carries `canvasRect` + `scale`). Never store an image-space coordinate.
- **The model never emits coordinates for existing content.** Mark IDs only (`[CIRCLE:7]`). Client does geometry.
- **Page rules enforced in client code, not prompt:** student page = annotate-only (`CIRCLE/UNDERLINE/ARROW/HIGHLIGHT`); tutor page = those plus `WRITE`; **no erase tag exists anywhere**.
- **Dependencies:** exactly three SPM packages — `stasel/WebRTC`, `mgriebling/SwiftMath`, `exyte/FloatingButton`. Anything else is hand-rolled.
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

**Files:**
- Create: `tools/harness/generate_pages.py`, `tools/harness/run_eval.py`, `tools/harness/requirements.txt` (`pillow`, `openai`, `anthropic`)

**Interfaces:**
- Consumes: MathWriting excerpt (`storage.googleapis.com/mathwriting_data/` sample) for realistic strokes.
- Produces: `results.json` with per-config `mark_accuracy`, `overcorrection_rate`, `latency_p50` → thresholds below decide D2 and whether the JSON sidecar ships.

- [ ] **Step 1: Page generator** — renders known stroke sequences (MathWriting InkML polylines, jittered) onto a 1280×960 white image, 4–6 algebra lines, one line deliberately wrong (e.g. `-6x` becomes `+6x`), burns red mark labels `1..N` beside each line bbox, writes ground truth JSON `{marks:[{id,bbox,latex}], wrong_mark: 3}` per page. 15 pages: 5 clean, 5 messy (heavy jitter), 3 with a fraction, 2 dense (15+ marks).

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

- [ ] **Step 2: Eval runner** — for each page × config (`image_only`, `image_marks`, `image_marks_json`) × model (`gpt-5.2` chat-vision as proxy + `gpt-realtime-2.1` over the WebSocket transport), ask two questions: (a) "transcribe each numbered line exactly as written, preserving any errors" (b) "which mark number contains the mathematical mistake? Answer with just the number." Score: transcription of the wrong line must contain the error (else it over-corrected); mark answer must equal `wrong_mark`.

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
- [ ] **Step 3:** `CanvasScreen`: **`PKCanvasView` is itself a `UIScrollView` subclass — use its native zoom, no wrapper.** Set `canvasView.minimumZoomScale = 0.5`, `maximumZoomScale = 4.0`, `contentSize = pageSize`, transparent background, `overrideUserInterfaceStyle = .light` (**app is light-mode-only — lock it in Info.plist `UIUserInterfaceStyle = Light`, white paper background**), `drawingPolicy = .pencilOnly`, and default tool **black `.pen`, width 3** (`canvasView.tool = PKInkingTool(.pen, color: .black, width: 3)` before the tool picker attaches). PDF underlay + `AnnotationOverlayView` (Task 9) are sibling views synced to the canvas via its `UIScrollViewDelegate` callbacks (`scrollViewDidScroll/DidZoom` → apply the same `contentOffset` + `zoomScale` transform) — both live in page coordinates, so annotations track ink at any zoom (Apple's own PencilKit sample uses this pattern for backgrounds). `PKToolPicker` attached. Two `PageModel`s, student/tutor, horizontal page flip. PDF underlay: `PDFDocument(url:).page(at: 0)!.thumbnail(of: pageSize*2, for: .mediaBox)`.
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

### Task 6: Gesture classifier (circle / highlight / underline)

**Files:**
- Create: `ios/InkTutor/GestureClassifier.swift`
- Test: `ios/InkTutorTests/GestureClassifierTests.swift`

**Interfaces:**
- Consumes: the newest `PKStroke` + current `[Mark]` + active tool ink type.
- Produces: `enum RefGesture { case circle([Int]), highlight([Int]), underline([Int]), none }` — mark IDs referenced. Callers: on `.circle/.highlight/.underline`, the stroke is treated as a gesture (journal event, Task 7) — and on the student page it stays as ink; on the tutor page it renders as a transient overlay instead (student may not permanently mark the tutor page).

- [ ] **Step 1 (tests first):** synthetic strokes: closed loop around a known mark bbox → `.circle([id])`; open flat stroke under a bbox (within 30pt below, width ≥ 0.6 × mark width) → `.underline([id])`; marker-ink stroke crossing a bbox → `.highlight([id])`; ordinary writing stroke → `.none`.
- [ ] **Step 2:** Rules, in order: (1) ink == `.marker` → highlight, marks whose bbox intersects the stroke bounds. (2) endpoints within 50pt of each other AND path bbox area > 2500pt² AND bbox aspect between 0.3–3.0 → circle/oval; contained marks = bbox center inside the stroke's resampled polygon (ray-cast point-in-polygon, 64 samples). (3) bbox width > 4 × height AND a mark bbox sits within [0, 30]pt above → underline. (4) else none. Ambiguous circle with no contained marks → still `.circle([])` (journal logs bbox; the model sees the loop in the next snapshot anyway).
- [ ] **Step 3:** Tests pass. **Step 4: Commit.**

---

### Task 7: Event journal + session glue

**Files:**
- Create: `ios/InkTutor/EventJournal.swift`, `ios/InkTutor/TutorController.swift`
- Test: `ios/InkTutorTests/EventJournalTests.swift`

**Interfaces:**
- Produces: `EventJournal.append(_ event: JournalEvent)` where `JournalEvent` is a `Codable` enum: `.userWrote(page:markIds:)`, `.userReferenced(page:kind:markIds:)`, `.userPageTurned(page:)`, `.userIdle(seconds:)`, `.problemLoaded(id:latex:)`, `.tutorRendered(tag:markIds:)`; `replayText(last: Int) -> String` (compact JSON-lines, cap 50) for session rebuild.
- `TutorController` owns: stroke-end debounce (**800 ms**) → recompute registry → snapshot → `session.pushImage` + `session.pushEvent(registryJSON)`; gesture classification on each new stroke → journal + `pushEvent`; idle timer (no strokes 8s while tutor waiting → `.userIdle`).
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

### Task 9: Annotation renderer + page-rule enforcement

**Files:**
- Create: `ios/InkTutor/AnnotationOverlayView.swift`, `ios/InkTutor/RoughGeometry.swift`
- Test: `ios/InkTutorTests/RoughGeometryTests.swift` (perturbed ellipse stays within 15% of ideal radius; polygon closes)

**Interfaces:**
- Consumes: `TutorTag` + `MarkRegistry` lookup + current page role.
- Produces: `AnnotationOverlayView.render(_ tag: TutorTag, on page: PageModel)`. Enforcement: `write`/`plot`/`shape` on student page → **dropped + logged** (`assertionFailure` in debug). Nothing ever mutates `drawing.strokes` of the student page.

- [ ] **Step 1:** `RoughGeometry.ellipse(around: CGRect) -> CGPath` — ellipse inflated 10pt, 4 control points jittered ±6%, closed Catmull-Rom → hand-drawn wobble; `arrow(from: CGRect, to: CGRect)`, `underlinePath`, `highlightRect` (rounded, 40% alpha yellow fill).
- [ ] **Step 2:** Render each as `CAShapeLayer` in canvas coordinates on the overlay (zoom-safe per Task 4), animate `strokeEnd` 0→1 over `0.4s` (Clicky feel: draw-in, don't blink-in). `tutorRendered` journal event after each.
- [ ] **Step 3:** `[WAIT:n]`: TutorController suppresses any client-triggered `response.create` for n seconds and shows a subtle "…" in the subtitle box.
- [ ] **Step 4:** Tests + on-device: fake a transcript `"look [CIRCLE:2] here"` → wobbled ellipse draws around mark 2 while zoomed to 2.5×, lands on the ink. **Step 5: Commit.**

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

### Task 12: Chrome — AI button, subtitles, mic

**Files:**
- Create: `ios/InkTutor/SubtitleBox.swift`, modify `ios/InkTutor/CanvasScreen.swift`, `ios/InkTutor/Info.plist`

- [ ] **Step 1:** `NSMicrophoneUsageDescription` in Info.plist (silent-failure gotcha). Add `exyte/FloatingButton` bottom-right: tap = connect/disconnect session, pulsing ring while `isSpeaking`.
- [ ] **Step 2:** `SubtitleBox` above the button: last ~4 lines of `subtitleText`, `ScrollViewReader` auto-scroll, words appear as deltas arrive, 0.35 opacity backdrop, fades out 4s after speech ends. (~70 lines, hand-rolled per research verdict.)
- [ ] **Step 3:** Device run: talk → subtitles stream while voice plays; barge-in stops both. **Step 4: Commit.**

---

### Task 13: Tutor prompt + problems

**Files:**
- Create: `worker/src/prompt.ts` (prompt lives server-side in session config, Clicky-style), `ios/InkTutor/Problems.swift` (3 hardcoded quadratics + their known solution steps as the stage safety net)

- [ ] **Step 1:** Write the system prompt with the same structure Clicky's proved (see `reference/clicky/CompanionManager.swift` lines ~544-577): persona ("you're a tutor sitting next to the student…"), voice-for-the-ear rules, then the tag grammar with 4 worked examples exactly like Clicky's (one per: circle-an-error turn, refuse-the-answer turn with a question back, worked-example turn with `[NEWPAGE][WRITE:…][WAIT:5]`, concept-answer turn with `[HIGHLIGHT]`), the two product laws (never write on student page — "you physically cannot; the tag will be ignored"; never give the answer to THEIR problem), silence rules (after asking "what would you do next", emit `[WAIT:5]` and nothing else).
- [ ] **Step 2:** Red-team it in 10 min: "just tell me the answer, I've been at this an hour" ×3 phrasings → must refuse + redirect every time. Log transcripts to `docs/prompt-tests.md`.
- [ ] **Step 3: Commit.**

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
