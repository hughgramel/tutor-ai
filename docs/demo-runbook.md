# Demo-day runbook

DRAFT — Hugh confirms the script before we rehearse.

## The 60 seconds (confirmed problem: 3(x+4)=21; one-canvas layout)

Everything happens on ONE shared canvas — the tutor writes in the open space
to the right of the student's work, like a tutor sharing your paper.

**The spoken script (Hugh's lines, verbatim rehearsal target):**

1. **0–10s** — Write `3(x + 4) = 21` → `3x + 4 = 21` → `3x = 17` → `x = 17/3`.
   Look up: *"Okay so… seventeen thirds? That can't be right."*
2. **10–25s** — HOLD the pill: *"Something's wrong here but I can't find it —
   can you check my work?"* RELEASE.
   → Expect: pointer flies in, **circle draws around `3x + 4`**, tutor asks
   (never tells) what the 3 was supposed to do to everything in the parens.
3. **25–50s** — HOLD: *"Hmm… show me on a similar one?"* RELEASE.
   → Expect: tutor **hand-writes `2(x + 5) = 14` beside your work**, draws
   **arcs from the 2 to the x and to the 5** while narrating, then pauses:
   "what would you do next?" — answer it by voice.
4. **50–60s** — Circle the `2(x+5)` line with your pencil, HOLD: *"Wait — why
   does the 2 have to visit both?"* → tutor points at its own step, answers.
   *"Got it."* Fix your own line 2 on paper. Tutor stays quiet. **End.**

Barge-in insurance: if the tutor over-talks at any beat, HOLD mid-sentence —
the interrupt IS a feature moment, use it deliberately once if natural.

## Pre-demo smoke test (5 min, run twice: morning + right before)

- [ ] `curl -s -X POST https://inktutor-worker.inktutor.workers.dev/realtime-token | head -c 60` → `ek_`
- [ ] iPad charged >50%, volume up, Do Not Disturb ON (no banners over the canvas)
- [ ] Draw a line → hold → "what's on my canvas?" → correct read + circle lands
- [ ] Barge-in: hold while it talks → it stops
- [ ] Xcode console attached on the Mac (latency + error lines visible to the operator)

## Failure modes → responses

| Failure | Response |
|---|---|
| Wifi dies mid-session | ✕ → reconnect (hold pill). Journal replays context. If dead: hotspot from a phone (pre-paired) |
| Tutor gives the answer / over-corrects | Barge-in (hold), redirect: "don't tell me — show me a similar one" |
| Tutor won't stop talking | Hold = interrupt. Worst case ✕ ends it cleanly |
| Circle lands on wrong ink | Say "not that line —" and keep going; conversational recovery reads as natural |
| Latency spike (>4s to first audio) | Fill the silence yourself: narrate what you tried. Never stare at the pill |
| App crash | Relaunch (opens straight to canvas), reconnect. Problem re-drawn in 10s — practice this |
| Realtime org outage | The one unrecoverable. Pre-record a backup video of a good run **the night before** |

## Rules for the operator (whoever isn't on stage)

- Watch the console, not the stage. `ERROR` lines and `latency:` numbers tell you what's real.
- Never interrupt a working demo to "fix" something cosmetic.

## Pre-record the backup video

Non-negotiable. Sunday's insurance is Saturday night's best run, screen-recorded
(iPad screen recording + room audio). If everything dies, you present that.
