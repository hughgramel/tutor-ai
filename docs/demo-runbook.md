# Demo-day runbook

DRAFT — Hugh confirms the script before we rehearse.

## The 60 seconds (proposed, pending Hugh's yes)

Problem: `3(x + 4) = 21`, distributed wrong as `3x + 4 = 21` → grind to `x = 17/3`.

1. **0–10s** Write the problem, make the mistake, reach the ugly fraction. Frown.
2. **10–25s** Hold pill: "this looks wrong but I can't see where." Tutor diagnoses,
   **circles `3x + 4`** on the student page, asks what the 3 was supposed to do.
3. **25–50s** Tutor: "let me show you a similar one" → popup opens, **hand-writes
   `2(x + 5)` with distribution arcs** from the 2 to each term while narrating.
4. **50–60s** Student circles a line of the tutor's ink, asks "why both?" — tutor
   highlights its own step and answers. "Now you try yours." `[WAIT]`.

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
