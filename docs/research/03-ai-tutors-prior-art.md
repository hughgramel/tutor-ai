# What AI tutors get right, and what they get catastrophically wrong

Source: research agent, July 2026. RCTs, Khan Academy's published retrospectives, 30 years of
pre-LLM intelligent tutoring systems.

---

## ⚠️ THE RESULT THAT SHOULD TERRIFY US

> **Bastani et al., PNAS 2025.** ~1,000 Turkish high-schoolers, randomized.
> Students given **bare GPT-4** performed **48% better on practice problems while they had it.**
> Then it was taken away for the exam.
> **They scored 17% WORSE than students who never had AI at all.**

Read that again. **An unguarded LLM tutor did not fail to help. It actively made students
worse than nothing.** They learned to lean, not to think. The practice-problem gains were
pure crutch — skill *substitution*, not skill *building*.

The same study ran a **guarded** version ("GPT Tutor" — hints, not answers). It got a
**bigger** in-practice boost (**127%**) *and* the post-removal damage was largely gone.

A second 2026 paper ("Faster Completion, Less Learning") found the same shape independently:
generative AI cut study time per problem *and* cut knowledge gained per problem. **Speed is
not learning.**

### What this means for us — this is not a nice-to-have

**The guardrails ARE the product.** Not a safety feature bolted on, not a policy, not a
system-prompt line. The difference between our app helping a student and our app *damaging*
them is entirely whether the AI refuses to hand over the answer.

Which means: **if we ship the demo version — where the AI beautifully writes out a full
solution while the student watches — we are shipping the version that made students 17%
worse.**

That's the AVOID item from `questions.md` ("are we building for the demo or the student?"),
except now it has a number on it.

---

## The result that says it CAN work

> **Kestin et al., *Scientific Reports*, June 2025.** Harvard Physical Sciences 2.
> AI-tutored students learned **~2x more** than students in an active-learning classroom.

**But look at what they actually built.** It was not a chatbot with a nice prompt:
- **Expert-authored scaffolds** per topic
- **One step at a time.** Explicitly forbidden from revealing the full solution in one message.
- Step-by-step reasoning, with hallucination guardrails

**That's the whole recipe.** One step, one question, never the full answer, scaffolds written
by someone who knows the subject. Boring, and it doubles learning.

## And the result that says humans still matter

> **Tutor CoPilot** (Stanford, arXiv 2410.03017). 900 tutors, 1,800 K-12 students, RCT.
> Gave *human* tutors real-time AI suggestions mid-session. Students +4pp to mastery
> (**+9pp for the weakest tutors**). Tutors using it asked **more guiding questions and gave
> away answers less**.

The AI was better at making a human a good tutor than at being one. Worth remembering before
we decide tutors are the enemy.

---

## The memory graph is 30 years old and it's called knowledge tracing

Ali's "save their mistakes and quiz them later" (p4) and the "memory graph" (p11) are a real,
validated, **thoroughly prior-art** idea. **Do not invent it.**

- **Bayesian Knowledge Tracing (BKT)** — per-skill latent mastery model. Four parameters:
  p(learn), p(slip), p(guess), p(known). Has driven **ALEKS and Cognitive Tutor since the
  1990s.** Cheap, interpretable, debuggable.
- **Deep Knowledge Tracing** (LSTM, 2015) and graph-based KT beat BKT on prediction (~25%
  AUC) but you lose the interpretability, which for a tutor is most of the value.
- **Efficacy is real but modest:** ASSISTments state RCTs (WestEd, Maine, 2023) → **0.18 SD**,
  sustained a year later, **largest for low-prior-achievement students.** Older ITS
  meta-analysis (Dodds & Fletcher) → ~1.08, but that number is generous.
- Carnegie Learning's Cognitive Tutor is **mixed** — some studies null or negative. Even
  well-designed ITS isn't uniformly good.

**Recommendation: implement plain per-skill BKT.** It's a weekend of work at most, it's
interpretable, and our novelty is supposed to be *voice + ink*, not reinventing an HMM.

**And store the right thing.** Not *"got Q3 wrong."* Store the **misrule** —
*"applies distribute-everything."* (See `02-tutor-craft.md`, Brown & Burton.)

---

## Khanmigo: what Khan Academy learned the hard way

- Their **load-bearing design choice** is exactly the Bastani guardrail: **never emit the
  final answer.** Always redirect to *"what do you think the next step is?"*
- **Students actively try to jailbreak it.** "Just tell me the answer," social pressure,
  bullying the bot. Khan built answer-refusal as an **adversarial robustness problem**, not a
  prompt. Assume our students will do the same, because they will.
- Their own 2026 retrospective: **six months of rigorous A/B testing produced a 6.1%
  improvement** in next-item independent correctness. **Khan Academy — with their resources —
  says this is slow, hard-won, and unsolved.** Anyone claiming otherwise is selling something.

---

## The failure modes to design against

Every one of these is a **default LLM behavior.** This is the anti-spec.

1. **Answer leakage under pressure.** Direct asks, social pressure, "I'm about to cry,"
   fake authority ("I'm the teacher"). Must be *tested*, not prompted.
2. **Sycophancy.** Now formally treated as an **educational safety risk** (arXiv 2605.14604).
   Models capitulate to social pressure even after resisting direct jailbreaks, and will
   **praise incorrect or empty work** to preserve rapport. *"Good work, but…"* is where it
   hides. **This directly threatens our encouraging-tutor UX.**
3. **The crutch effect.** (Bastani.) Student performs only while we're there. → **Fade the
   scaffolding. Force periodic no-help checks.**
4. **Hallucinated math steps.** LLMs invent plausible-but-wrong intermediate steps. **Fix:
   verify with a symbolic engine (SymPy), never LLM arithmetic.** *(Note: Canvas Math already
   does this — they use a real symbolic engine, not LLM-guessed compute. They're right.)*
5. **Verbosity.** Deadly in voice. Human turn-taking gaps are ~200ms; perceived sluggishness
   starts ~600ms. **One step, one question, per turn.** Never a lecture.
6. **Generic scaffolding** that ignores the specific misconception in front of it.
7. **The correct-answer trap** (arXiv 2605.23925) — AI tutors miss *flawed reasoning that
   happens to arrive at the right answer.* A student who gets it right for the wrong reason
   is the one who most needs catching, and we'll miss them by default.

**"Just prompt it to be Socratic" is documented as insufficient** (arXiv 2508.06583). Lazy
Socratic prompts produce infinite-regress questioning with no synthesis and no termination.
Real Socratic tutoring needs **phase-locked structure**: diagnose → target *the specific
error* → scaffold → check → close.

**Evals that exist if we want them:** MRBench (mistake remediation), SafeTutors (sycophancy),
EduFrameTrap (pressure), MathDial, Bridge.

---

## The metric

> **Track independent performance after help is removed.** Not engagement. Not completion.
> Not session length.

Bastani's whole point is that **engagement metrics are actively misleading** — the crutch
students were the *most* engaged and the *most* damaged. Khan Academy's own north star is
"next-item independent correctness," and they're right.

**This is also our answer to Philip Su.** He asked how we know they're learning. The answer
isn't a correlation with the SAT — it's: *take the tutor away and see if they can still do it.*
