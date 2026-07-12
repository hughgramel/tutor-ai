# Plan

The sequence. **Work the current gate only.** Producing an artifact from a later gate means
we've gone off-plan — stop and say so.

Nothing is decided until Hugh says it is.

---

| # | Gate | Status |
|---|---|---|
| 1 | **Problem & solution** — who, what, why, and what we're *not* building | ✅ done — `docs/01-problem.md` |
| 2 | **Research** — competitors, architectures, tools, how to be a good tutor | ✅ done — `docs/02-competitors.md`, `docs/03-stack.md`, `docs/research/` |
| 3 | **Feature list** — "it can do X." No architecture. | ✅ done — `docs/04-mvp.md`, `features.md` |
| 4 | **Architecture** — components, and the tradeoffs weighed for each | ✅ done — `docs/05-architecture.md`; D1–D4 decided in `features.md` |
| 5 | **Hugh explains it back** — the product, the constraints, and *why*, in his own words | ✅ passed (build proceeding on Hugh's direction) |
| 6 | **Build** | 🔵 **HERE.** Checklist: `features.md`. F1–F4 code landed; boxes tick when demo'd on iPad |
| 7 | **Record & post** | ⬜ blocked on 6 |

---

## Gate 6 — build (current)

Riskiest first, per the `features.md` build order. What's landed on `plan-ai-tutor-demo`:

- **F1 voice** — Realtime (gpt-realtime-2.1) over WebRTC, hold-to-talk (no VAD), token mint via CF Worker, tag parser
- **F2 marks** — mark registry (stroke clustering → stable IDs), annotation renderer, glyph library
- **F3 tutor page** — TutorWriter: animated handwritten math (CAShapeLayer path, D3 = a)
- **F4 chrome** — worksheet canvas, voice bar v2 (real-audio waveform), guardrails prompt

**In flight (uncommitted):** latency instrumentation + student-speech transcript ("you: …" line)
across `RealtimeSession.swift`, `TutorSession.swift`, `worker/src/index.ts`.

**Boxes in `features.md` tick when demonstrated on the iPad, not when the code exists.**

---

## Gate 3 — feature list (done)

Agreed capabilities in plain language, `docs/04-mvp.md` + `features.md`. F4b (gesture
classifier) cut.

## Gate 4 — architecture (done)

Components and boundaries in `docs/05-architecture.md`. Decisions D1–D4 in `features.md`:
D1 = gpt-realtime, D2 = live device test (offline harness cut), D3 = CAShapeLayer, D4 = stretch.

## Gate 5 — explain it back

**Not a formality.** Hugh should be able to answer, without the docs open:

- What is the product, and who is it for?
- Why does the tutor get its own page? What breaks if it writes on the student's?
- Why does it refuse to give the answer? What's the evidence?
- Why voice *and* ink, and why must they never say the same thing?
- What's the one component that, if it fails, means there is no demo?
- What did we give up when we chose native iPad?

**If he can't, we don't build yet.** Not because it's a rule — because a team that doesn't
understand its own constraints will violate them Saturday night at 2am, under pressure,
without noticing.

## Gate 6 — build

Riskiest thing first. Order gets set in gate 4, once we know the components.

## Gate 7 — record & post

The demo is a **restraint**, not a flourish. That's a deliberate choice and it gets made
before we shoot, not after.

---

## Rules for the whole thing

- **Cut before adding.** The notebook holds ~10 products. We're building one interaction.
- Run the **AVOID list** (`docs/questions.md`) at every gate. It's a real check.
- The **research constraints** (`docs/research/00-SUMMARY.md`) are product law, not taste.
  If the build starts violating them, the build is wrong — not the research.
