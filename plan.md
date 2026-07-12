# Plan

The sequence. **Work the current gate only.** Producing an artifact from a later gate means
we've gone off-plan — stop and say so.

Nothing is decided until Hugh says it is.

---

| # | Gate | Status |
|---|---|---|
| 1 | **Problem & solution** — who, what, why, and what we're *not* building | ✅ done — `docs/01-problem.md` |
| 2 | **Research** — competitors, architectures, tools, how to be a good tutor | ✅ done — `docs/02-competitors.md`, `docs/03-stack.md`, `docs/research/` |
| 3 | **Feature list** — "it can do X." No architecture. | 🔵 **HERE.** `docs/04-mvp.md`, awaiting Hugh's confirm/cut |
| 4 | **Architecture** — components, and the tradeoffs weighed for each | ⬜ blocked on 3 |
| 5 | **Hugh explains it back** — the product, the constraints, and *why*, in his own words | ⬜ blocked on 4 |
| 6 | **Build** | ⬜ blocked on 5 |
| 7 | **Record & post** | ⬜ blocked on 6 |

---

## Gate 3 — feature list (current)

**Goal:** an agreed list of *capabilities*, in plain language. What the student can do. What
the tutor can do. What we are explicitly not doing.

**Not in scope for this gate:** how any of it works. No components, no data formats, no tool
schemas, no libraries. That's gate 4.

**Done when:** every line in `docs/04-mvp.md` is confirmed or cut, and the four open scope
decisions are made.

## Gate 4 — architecture (next)

**Goal:** name the components and the boundaries between them. **For each one, weigh the
tradeoff out loud** — the option we picked, the options we didn't, and what it costs.

`docs/03-stack.md` holds *candidate* tools and a recommendation. **It is a proposal, not a
decision.** Re-open all of it here.

**Done when:** Hugh can name every component, say what it does, and say what we gave up to
get it.

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
