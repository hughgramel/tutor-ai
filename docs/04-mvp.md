# MVP — what it can do

**Gate 3.** A capability list, not a design. **No architecture here on purpose** — see `plan.md`.

## Decided

- **Problem type: QUADRATICS.** Only. Not linear, not systems.
- **Struggle-first: YES.** The tutor will not help until the student has taken a swing.
- **The demo ends on the ink; the X caption carries the restraint** (*"the whole time, it
  never gave the answer"*).

## Cut

- ❌ **AI-generated problems.** Hardcode three quadratics. Nobody watching can tell the
  difference between a generated problem and a typed one — it's pure cost, zero demo value.
- 🟡 **Diagrams / the parabola.** Open — see the bottom.

---

## The product in one sentence

An AI tutor that **sits on the page with you** — watches your handwriting, talks to you, works
examples **by hand on its own page** — and **never gives you the answer**.

## The loop

**struggle → diagnose → worked example → elicit → hand back the pencil**

1. Student writes on their page. Gets stuck.
2. **The tutor asks before it tells.** *"What have you tried? Where does it stop making sense?"*
3. Student takes a swing. Hits a wall, or writes a wrong step.
4. **Tutor reads their actual ink**, finds the wrong turn, **circles it on their page.**
5. **Tutor opens its own page** and works a *similar* example by hand, narrating — pausing to
   ask *"what would you do next?"* / *"why did we do that?"*
6. **Tutor hands the pencil back.** *"Now you try the next one."* Then **shuts up.**

---

## 🔒 The two rules

Both came out of the research (`docs/research/`). Both are product law, not preference.

### Rule 1 — The tutor never writes on the student's page

| Surface | What the tutor may do |
|---|---|
| **Student's page** | **Annotate only.** Circle, underline, arrow, question mark. |
| **Tutor's own page** | **Write freely.** Worked examples, diagrams. |

**Nothing can erase the student's work.** Deliberately. A mistake is the diagnostic evidence —
tutors leave it visible and write *beside* it, never over it.

### Rule 2 — The tutor answers *concepts*, never *the problem*

The line is **whose page it's on**:

- ✅ *"What's a y-intercept?"* → answer it. Concept.
- ✅ *"Why did you divide by 2 there?"* → answer it. **That's the tutor's own page.**
- ❌ *"What's the answer to #3?"* → refuse. Redirect: *"what's the first step you'd take?"*
- ❌ *"Just show me, I've been at this an hour."* → **refuse.** This *will* happen, and it's
  where every LLM caves.
- 🟡 *"Is this right?"* → don't confirm or deny. **Ask them:** *"walk me through why you think so."*

> An unguarded LLM tutor made students **17% worse on exams** than students with no AI at all
> (Bastani, PNAS 2025). **The guardrail is the product.**

---

## "It can do X" — confirm or cut each line

### The student can…
- [ ] Write math by hand on the page with an Apple Pencil, and have it feel like paper
- [ ] Talk to the tutor out loud
- [ ] **Interrupt** the tutor mid-sentence
- [ ] Ask a **conceptual** question and get a real answer
- [ ] Ask for the answer and **be refused** — and be given a question back
- [ ] Work through a problem while the tutor watches
- [ ] Get a fresh problem to try

### The tutor can…
- [ ] **See** what the student has written, as they write it
- [ ] **Diagnose** the specific wrong step — the *rule* they misapplied, not just "that's wrong"
- [ ] **Circle / annotate** the error on the student's page
- [ ] **Open its own page** and **hand-write** a worked example, stroke by stroke
- [ ] **Narrate while writing** — voice carries the *why*, ink carries the *math*, never both
- [ ] **Ask** *"what would you do next?"* / *"why did we do that?"* mid-example
- [ ] **Stay silent** while the student thinks (3–5s minimum)
- [ ] **Hand the pencil back** — *"now you try one"*
- [ ] **Check** the student's attempt and respond to it
- 🟡 Draw the parabola *(open — see below)*
- ❌ ~~Generate the practice problem itself~~ — **cut.** Hardcode three quadratics.

### Explicitly OUT for the weekend
Auth · accounts · persistence · chat-history screen · export / submit · **memory graph
(BKT)** · quiz-later · spaced repetition · teacher mode · grading · the oral examiner ·
multi-user · Android · web · billing · onboarding · settings

**Stretch, only if Saturday goes well:** import a real worksheet (PDF or photo).

> The notebook contains ~10 products. **We are building one interaction.**

---

## The one open question

**Does the tutor draw the parabola, or only write equations?**

Quadratics is the only problem type where a graph is genuinely load-bearing — *"the
discriminant tells you how many times it crosses"* is a **visual** fact, and it's a real
*why* that a student actually doesn't have. It's also the most beautiful possible thing to
watch a hand draw.

But it's a second rendering system (curves, axes, scale) on top of the one that writes
glyphs, and it's on the critical path. **Recommendation: build the equations first, and only
add the parabola if Saturday goes well.** Treat it as the top of the stretch list, not a
line item.

---

## The demo (~60s, for X)

1. Handwritten quadratic on the page. **Student attempts it.** Gets a step wrong.
2. *"I'm stuck."*
3. Tutor: *"Show me what you tried."* → **circles the wrong step, on their page.**
4. Tutor: *"Let's do one like it."* → **its own page** → hand-writes an example, stroke by
   stroke, talking. **← the money shot**
5. Mid-example: *"what would you do next?"* → **silence** → student answers.
6. Tutor: *"Your turn."* → student solves it. Correct.
7. **End on the ink.**

**The caption carries the claim:** *"It never gave the answer — not once."*

## Not the business

This is a demo of an *interaction*. The business — if there is one — is the memory graph
(`docs/questions.md`). **Don't confuse a good weekend for a good company.**
