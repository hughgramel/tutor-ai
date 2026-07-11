# How to be a good tutor — the summary

Read this one. The other three are the evidence.

- `01-learning-science.md` — cognitive load, worked examples, wait time, feedback
- `02-tutor-craft.md` — tutor training manuals, scripts, page tradecraft
- `03-ai-tutors-prior-art.md` — the RCTs, Khanmigo, knowledge tracing, failure modes

---

## The three findings that change what we're building

### 1. The unguarded version of our product makes students *worse than nothing*

**Bastani et al., PNAS 2025.** ~1,000 students. Bare GPT-4 → **+48% on practice while they
had it** → **−17% on the exam after it was taken away**, vs. students who never had AI. The
guarded version (hints, never answers) got a **bigger** practice boost (+127%) *and* erased
the damage.

**So: "never give the answer" is not a policy. It is the entire product.** It's the only
thing separating us from a tool that measurably harms the kid using it.

And the positive result confirms it from the other side: **Kestin et al. (Harvard, 2025)** got
**2x learning** — with expert-authored scaffolds, **one step at a time**, explicitly forbidden
from revealing the full solution in a single message.

### 2. Every tutor manual says: **never take the pencil out of the student's hand**

Rule #1 of tutor training is *"never work the problem for the student."* **We are building
the #1 anti-pattern as our headline feature.**

The resolution — which **Hugh already drew on p5 without knowing why it was right**:

> ## 🔒 The AI gets its OWN page. It never writes on the student's work.
> On the student's page the AI may only **annotate** — circle, underline, arrow, question mark.
> Never a correction. Never a step. **There is no eraser tool.** (Errors are diagnostic data;
> tutors deliberately leave them visible and write *beside* them, not over them.)

### 3. The science says our shape is right — and tells us exactly how to build it

Three cognitive-load effects, and together they're a citation for the whole thesis:

| Effect | Finding | What it means |
|---|---|---|
| **Modality** (Mayer) | Narration + visual beat on-screen text + visual, **17/17 tests** | **Voice is the mechanism, not a gimmick** |
| **Split-attention** (Chandler & Sweller) | Explanation separated from the diagram **measurably hurts learning** | **Every competitor's chat sidebar is a known failure mode.** Writing on the page *is* the product |
| **Redundancy** (Mayer) | Narrating the same words you display **hurts** | **The AI must never say what it writes** |

That last one is a hard design rule and it's easy to get backwards:

- ❌ AI writes *"divide both sides by 2"* and says *"divide both sides by 2."*
- ✅ AI **writes** `2x = 10` → `x = 5`. AI **says** *"we're trying to get x by itself."*

> **Ink carries the math. Voice carries the why. Never the same content twice.**

---

## The tutor loop to encode

**diagnose → let them struggle → scaffold at the edge → elicit → check → fade**

1. **Diagnose first.** *"What have you tried?"* *"Where does it stop making sense?"* Never explain before you know where they are.
2. **Let them fail first.** (Kapur, productive failure — problem-solving *before* instruction beats instruction-then-practice.) Bounded: ~2–4 min or 2 failed attempts. **Then** the worked example, aimed at their specific wrong turn.
3. **One step, one question, per turn.** Never a lecture. (Kestin; and in voice, verbosity is death.)
4. **Elicit, don't tell.** *"Why did that step work?"* (Self-explanation effect, Chi.) Never *"does that make sense?"* — it lets them nod through total confusion.
5. **Hand the pencil back.** *"Now you try one."* Retrieval *is* the learning, not the check.
6. **Fade.** Worked examples help novices and **actively harm** students who already have the schema (expertise reversal). Track per-skill mastery and stop helping.

## The anti-spec — every one is a default LLM behavior

- ❌ **Giving the answer**, especially under pressure. Students *will* try to jailbreak this; Khan Academy treats it as adversarial robustness, not a prompt line.
- ❌ **Praise.** *"Great job!"* — **Kluger & DeNisi (131 studies): ~1/3 of feedback interventions made performance WORSE**, especially ego-focused praise. And sycophancy is now classed as an educational safety risk — models praise empty and incorrect work to preserve rapport.
- ❌ **Talking too much.** ❌ **Rescuing early.** ❌ **Erasing their mistake.** ❌ *"This is easy."*
- ❌ **Hallucinated math steps** → verify with a symbolic engine (SymPy). Never LLM arithmetic. *(Canvas Math already does this. They're right.)*
- ❌ **Filling the silence.**

## Wait time — the finding a voice AI will get wrong by default

> **Rowe (1972/1986).** Teachers typically wait **<1 second** after asking a question. Coached
> to **3–5s** (threshold ~2.7s), student answers get **300–700% longer** and contain more
> reasoning. **Immediate praise or correction *suppresses* answer quality.**

**The AI must hold silence for 3–5 seconds after asking a question — longer while the pencil
is moving. Pencil-down + pause means "thinking," not "done."**

This is also the *"silence-aware pacing"* white space we identified in the competitor
research. Nobody has built it. It has a fifty-year-old literature.

---

## Two things to steal, cheaply

**Misconception catalogs.** Student errors are not random — they're the systematic application
of a *coherent wrong rule* (**Brown & Burton, "buggy algorithms," 1978**). Load a catalog and
the tutor stops saying *"that's wrong"* and starts saying *"you're collapsing 6x + 5 to 11x
because you think every expression must reduce to one term."* That fixes the next twenty
problems. Free, ~an hour of work: **MalruleLib** (executable misrule library), the **27
cataloged algebra misconceptions** (ERIC), Lamar's Common Math Errors.

**Knowledge tracing.** The "memory graph" (p11) already exists and is called **Bayesian
Knowledge Tracing** — per-skill mastery, 30 years old, drives ALEKS and Cognitive Tutor.
**Don't reinvent it.** Implement plain BKT and store **misrules**, not scores.

---

## The metric — and the answer to Philip Su

**Track independent performance after the help is removed.** Not engagement, not completion,
not session length.

Bastani's crutch students were the **most engaged and the most damaged.** Engagement metrics
will lie to us. Khan Academy's north star is "next-item independent correctness" and they're
right.

Philip asked *how do we know they're learning?* The answer isn't a correlation with the SAT.
**It's: take the tutor away and see if they can still do it.**

---

## 🔴 The uncomfortable part

The most beautiful possible demo — **student asks, AI elegantly writes a complete solution in
handwriting while the student watches** — is, according to the evidence, **the version that
makes students worse.** It is Bastani's GPT Base. It is the crutch.

The pedagogically correct demo is *slower and less impressive*: the student struggles first,
the AI asks questions, writes only a partial example on its own page, then **shuts up for five
seconds** and makes the student do the next one.

**These two demos are different products, and we have to choose on purpose.** The good news:
the honest one still has the money shot — ink appearing in handwriting, in sync with a voice —
it just doesn't hand over the answer at the end. **We can have the wow and the ethics. We just
can't have the wow and the laziness.**
