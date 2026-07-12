# Features — build checklist

**DRAFT.** Nothing here is decided until Hugh confirms. Check a box when the feature is
*demonstrated working on the iPad*, not when the code exists. Capabilities trace to
`docs/04-mvp.md`; stack candidates come from the 2026-07-12 research pass (4 reports,
summarized in `docs/05-architecture.md` + this file).

Platform: **native iPad, Swift + PencilKit.** (Confirmed by Hugh 2026-07-12 — "design
library for swift." The "DOM" is not a DOM: it's the PKStroke list + a derived mark
registry. See F5.)

---

## F1 — Voice: talk to the tutor

- [ ] Student talks out loud, tutor answers in voice
- [ ] Student can **interrupt mid-sentence** and the tutor stops (barge-in)
- [ ] Tutor's speech streams as text too (feeds F4 subtitles + F2 tag parser)
- [ ] Tutor refuses to give the answer; asks a question back (prompt + demo script)

**Stack candidate:** OpenAI `gpt-realtime-2.1` over WebRTC — only single-vendor option
with barge-in + mid-session image push + streaming transcript (`response.output_audio_transcript.delta`).
**Cost:** no iOS SDK — hand-rolled WebRTC + SDP + ephemeral tokens (`/v1/realtime/client_secrets`, one CF Worker).
**Challenger:** Gemini Live via Firebase AI Logic — native Swift SDK (no WebRTC by hand), 5–10x cheaper,
but Live API is *Preview* in the SDK and image input is frame-based (≤1fps video model), not discrete push.

**Validate (Friday, timeboxed 2h):** spike both from Swift. Pass = round-trip voice + one
canvas snapshot understood + transcript deltas arriving. Pick whichever passes; OpenAI wins ties.

## F2 — The tutor sees the page and marks it while talking

- [ ] Tutor sees the student's ink as they write (snapshot on stroke-end, debounced, pushed proactively — no tool-call stall)
- [ ] Tutor **circles / underlines / arrows** a specific spot on the student's page, mid-sentence
- [ ] Marks land on the right spot (client does geometry from mark ID — model never emits coordinates)
- [ ] Annotate-only on the student's page; **nothing can erase student ink**

**Stack candidate:** Set-of-Mark dual channel — snapshot with numbered labels + JSON sidecar
`[{id, bbox, line}]`; model replies with inline tags `[CIRCLE:7]` parsed from the transcript stream.
This is the converged industry pattern (tldraw agent, Excalidraw MCP) — and we're better off than
they are: PencilKit gives ground-truth bboxes (`PKStroke.renderBounds`), nothing is inferred.

**⚠️ Research finding that needs a decision:** VLMs silently "auto-correct" the student's
wrong step in 42–66% of handwritten-math reads (stronger models do it *more*), and the best
model located handwritten errors at 57% vs 84% human. **Open decision D2:** does the LLM find
the wrong line, or does deterministic code find it (on-device ink recognition + symbolic check)
and the LLM only talk about it?

**Validate (the harness Hugh asked for):** ~15 synthetic `PKDrawing` pages built from scripted
point arrays (ground truth exact by construction), one deliberately wrong line each, incl. a
fraction, an exponent, a dense page. Fire at the API in 3 configs — image-only / image+marks /
image+marks+JSON. Measure: mark-selection accuracy, over-correction rate, latency.
Thresholds: ≥90% mark accuracy clean (≥75% messy) → ship image+marks; over-correction >20% → D2 goes deterministic.
One person, a few hours, Friday night.

## F3 — The tutor's own page: handwritten worked example

- [ ] Tutor opens its own page (`[NEWPAGE]`) — never writes on the student's
- [ ] Writes a worked quadratic **in handwriting, stroke by stroke, animated**, synced with narration
- [ ] Math looks right: fractions, √, ², ± laid out correctly
- [ ] Student can ask about any part of it and get a real answer (concept questions are fair game on the tutor's page)
- [ ] Tutor pauses mid-example to ask "what would you do next?" and **stays silent** (`[WAIT:5]`)
- 🟡 Stretch: `[PLOT:y=…]` — client-side parabola with hand wobble (top of stretch list, per Gate 3)

**Stack candidate (glyphs):** extract ~22 exemplar glyph strokes from **Google MathWriting**
(InkML point sequences, real pen dynamics; CC BY-NC-SA — fine for demo, blocker for a product)
+ hand-author the stragglers (fraction bar, maybe √). **Layout:** SwiftMath's `subDisplays`
tree (public `position`/`width`/`ascent` per atom — verified in source); substitute our strokes
for its font glyphs. **Animation — open decision D3:**
- (a) `CAShapeLayer.strokeEnd` per subpath — stable since iOS 4, flat-vector look, ~2 days total
- (b) synthetic `PKStroke` progressive reveal — real pencil ink texture matching the student's, iOS 14+, ~1 day extra
- iOS 27's parametric substroke API exists but is beta — post-hackathon upgrade only.

**Validate:** render `x = (-b ± √(b²-4ac)) / 2a` animated on device; the test is Hugh watching
it and saying "that reads as handwriting," not a metric.

## F4 — Canvas: GoodNotes-feel + AI chrome

- [ ] Paper-like page, Apple Pencil ink that feels right (PKCanvasView + PKToolPicker — free; variable stroke width comes from PKInk `.pen` + pencil force, built in)
- [ ] **Pinch zoom in/out — essential** (PKCanvasView inside its own UIScrollView zoom; marks/overlays must track zoom)
- [ ] PDF worksheet underlay (PDFKit page rendered behind the canvas; snapshot to AI composites PDF + ink)
- [ ] Page flip / at least 2 pages (student's, tutor's)
- [ ] AI button bottom-right (exyte/FloatingButton, MIT, maintained)
- [ ] Subtitles box bottom-right above the button: tutor's words stream in, scroll up (hand-rolled, ~50–80 lines: `ScrollViewReader` + transcript deltas)
- [ ] Dark-mode trap handled: force `.light` + explicit ink color or snapshots go blank

**Research verdict on cloning:** nothing clone-ready exists. The only real open-source
GoodNotes alternative (saber-notes/saber, 4.6k★) is Flutter — UX reference only. No repo
anywhere renders AI output as simulated ink; **that piece is ours to build.** Start from bare
`PKCanvasView` (~50-line SwiftUI bridge), not someone's 1-star hackathon repo.

**Validate:** hand the iPad to someone; if they start writing without instructions, pass.

## F4b — Student reference gestures — ❌ CUT (Hugh, 2026-07-13)

No gesture classifier in the MVP. The student's circle is ink; it arrives in the next
snapshot and the model sees it there — no structured event needed. The wow moment
survives: circle + ask out loud works through snapshot + voice. Original taxonomy kept
below as stretch reference only.

- [ ] **Circle/oval**: new stroke whose endpoints nearly meet + encloses area → `user_referenced {kind:circle, markIds}` (marks whose bbox center falls inside the loop)
- [ ] **Highlight**: stroke drawn with the highlighter tool overlapping marks → `{kind:highlight, markIds}`
- [ ] **Underline**: short, flat stroke directly under a mark's bbox → `{kind:underline, markIds}`
- [ ] Works on BOTH pages (student circling the tutor's work is the wow moment)
- [ ] Ambiguous gesture → still log it with `markIds:[]` + bbox; the model sees it in the next snapshot anyway

**Validate:** scripted strokes through the classifier in unit tests; on-device sanity pass.

## Output tag additions (Hugh, 2026-07-12)

- [ ] `[HIGHLIGHT:7]` — translucent highlighter swipe over mark 7, allowed on **both** pages (annotate-class, erases nothing)

## 💰 Cost sheet (from verified 2026-07 pricing)

| Thing | Cost |
|---|---|
| gpt-realtime-2.1, live session | ~$0.05–0.15/min realistic (cached); worst case ~$0.46/min |
| → 10-min tutoring session | **~$0.50–1.50** |
| → weekend of dev + testing | ~$20–50 |
| gpt-realtime-2.1-mini | ~⅓ of the above |
| Gemini Live (if D1 flips) | ~$0.005–0.02/min → 10-min session ~$0.10–0.25 |
| Claude Opus 4.8 vision fallback | ~$0.01–0.02 per snapshot read (~1.1k tok/image) |
| MathWriting, SwiftMath, FloatingButton, Worker free tier | $0 |
| Apple dev account | $0 (7-day free provisioning) or $99/yr for TestFlight |

## 🎬 The wow moment (decided target, demo is built around it)

The 04-mvp money shot stays (tutor hand-writes while narrating). The **differentiator vs
HeyClicky** added on top: **two-way ink pointing** —

> Student circles a step in the TUTOR's handwritten example: "wait, why did you divide by
> 2 here?" → tutor highlights its own line, draws an arrow back to the earlier step it came
> from, and explains — while talking, no pause.

Nobody has shown mutual ink-to-ink reference (Clicky points at your screen; you can't
point back). Both directions ride machinery we're building anyway (F2 + F4b).

## F5 — The representation (the "DOM")

Not a feature the user sees — the contract everything above shares:

- **One coordinate system: canvas space** (page points, origin top-left of the page,
  fixed page size). All marks, annotations, glyph placements, and journal events are
  stored in canvas space. **Screenshot pixel space exists only at the snapshot boundary**
  — each snapshot carries `{canvasRect, scale}` so image↔canvas is a reversible affine
  transform. This is the deliberate break from Clicky/computer-use, and it's what makes
  zoom free: overlays live inside the zooming view at page coordinates, so a highlight
  drawn at zoom 1.0 is still on the right ink at zoom 3.0. (Hugh, 2026-07-12.)
- **Source of truth:** `PKDrawing.strokes` per page (vector, exact, already canvas-space)
- **Derived, on stroke-end:** stroke groups → mark registry `[{id, bbox, line}]` (client-side, deterministic, canvas-space bboxes)
- **To the AI:** downscaled snapshot with mark labels burned in + the registry as JSON text
- **From the AI:** inline tags referencing mark IDs only — `[CIRCLE:7]`, `[WRITE:latex|below:7]`, `[NEWPAGE]`, `[WAIT:5]`. No coordinates, ever. No erase — the tag doesn't exist.
- **Enforced in the client,** not the prompt: student-page = annotate-only, tutor-page = write.

Known weak point: stroke→group clustering breaks on fractions/exponents (a numerator and
denominator are two spatial groups, one semantic unit). The F2 harness's fraction/exponent
pages exist to measure exactly this.

---

## Decisions Hugh owns (blocking build order)

| # | Decision | Options | Research lean |
|---|---|---|---|
| D1 | Voice provider | gpt-realtime (raw WebRTC) vs Gemini Live (Swift SDK, Preview) | Spike both Friday, 2h box |
| D2 | Who finds the error | LLM reads the page vs deterministic check + LLM talks | Harness decides; lean deterministic if over-correction >20% |
| D3 | Ink render path | CAShapeLayer (safe) vs synthetic PKStroke (prettier) | Start (a), upgrade to (b) if Saturday allows |
| D4 | Parabola | in or stretch | Stretch (Gate 3 position, unchanged) |

## Build order (proposal — riskiest first)

1. F2 validation harness + D1 voice spike (Friday — both are go/no-go findings)
2. F3 glyph pipeline (MathWriting → CGPath → animated on device) — the money shot
3. F1 voice loop end-to-end with tag parsing
4. F2 live marks on student page
5. F4 chrome (button, subtitles, pages) — last, it's the least risky
