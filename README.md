# slopathon — AI math tutor

An AI tutor that **sits on the page with you**. iPad + Apple Pencil. It watches your
handwriting, talks to you, works examples **by hand on its own page** — and **never gives you
the answer.**

Every competitor either **solves for you** (Photomath) or **chats at you** (Khanmigo).
Nobody has an AI that **picks up the pencil next to you.**

## Read in this order

| Doc | What |
|---|---|
| [`docs/01-problem.md`](docs/01-problem.md) | Problem, persona, and what we're *not* building |
| [`docs/research/00-SUMMARY.md`](docs/research/00-SUMMARY.md) | **How to be a good tutor.** The three findings that shaped the product |
| [`docs/04-mvp.md`](docs/04-mvp.md) | **The weekend.** Scope, the two hard rules, build order, owners |
| [`docs/02-competitors.md`](docs/02-competitors.md) | Landscape + architectures worth stealing |
| [`docs/03-stack.md`](docs/03-stack.md) | Every tool option, the rejects, and why |
| [`docs/questions.md`](docs/questions.md) | What we don't know. Living |
| [`docs/00-notebook-transcript.md`](docs/00-notebook-transcript.md) | The original notebook, transcribed |

## The two rules that define the product

**1. The AI never writes on the student's page.** It gets its own. On the student's page it
may only *annotate* — circle, arrow, question mark. No corrections. **No eraser tool** — a
mistake is diagnostic evidence, and tutors leave it visible.

**2. The AI answers *concepts*, never *the problem*.** An unguarded LLM tutor made students
**17% worse on exams** than students who had no AI at all (Bastani et al., PNAS 2025). The
guardrail isn't a safety feature. It's the product.

## The stack

Native iPadOS (Swift + PencilKit) · LiveKit Agents + OpenAI Realtime for voice ·
Claude Opus 4.8 for vision + pedagogy · handwriting font → Bézier → `PKStroke`, revealed
stroke by stroke.
