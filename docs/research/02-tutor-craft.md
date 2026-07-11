# Tutor tradecraft

Source: university tutoring-center manuals (CRLA/ITTPC, Stanford NSSA, Miami Dade, Sonoma
State, Lone Star), working tutors, Brown & Burton's buggy-algorithm literature.

---

## ⚠️ THE FINDING THAT CONTRADICTS OUR PRODUCT

**Rule #1 in every tutor training manual is: *never work the problem for the student. The
pencil stays in the student's hand.***

- *"Function as a guide, not a problem-solver… never work problems for students."* — Miami Dade CRLA-derived TutorTIPs
- *"I never work a full problem in tutoring."* — working math tutor
- The reason: **if the tutor holds the pencil, the tutor is the one thinking.**

**Our entire pitch is "the AI picks up the pencil."** Read literally, we are building the
#1 anti-pattern in tutoring, and shipping it as the headline feature.

### The resolution — and Hugh already drew it on p5

The rule and the worked-example effect only *look* contradictory. Reconciled:

| Situation | What the evidence says |
|---|---|
| Student is a **novice** at this problem type | Studying a **worked example** beats floundering (Sweller & Cooper). **The AI should write.** |
| Student has **already attempted and hit a wall** | *Now* deliver the example, aimed at their wrong turn (Kapur, productive failure). **The AI should write.** |
| Student is **working their own problem** | **The AI must NOT write.** The pencil is theirs. Guide only. |
| Student has **shown 2–3 correct steps** on this skill | Worked examples now *hurt* (expertise reversal). **Stop writing. Hand it back.** |

**So the rule isn't "never write." It's: *the AI writes on its own page; the student's page
stays the student's.***

Which is **exactly what the notebook says on p5**:

> *"Hey, can you work through an example of this?" → **Agent creates a new page.** Agent uses
> handwriting to start working through it with you. User can jump in. Tutor can guide you,
> **ask you to work through one yourself.**"*

That design is right, and the reason it's right is the worked-example effect + expertise
reversal. **This is a hard architectural constraint, not a UI preference:**

> ## 🔒 THE AI GETS ITS OWN PAGE. IT DOES NOT WRITE ON THE STUDENT'S WORK.
> The only marks the AI is ever allowed to make on the student's page are **annotations** —
> circle the error, underline, arrow, question mark. **Never a correction. Never a step.**

---

## (a) The rules good tutors follow

1. **Diagnose before teaching.** *"What have you tried?"* / *"Where exactly does it stop
   making sense?"* — before explaining anything. Students have partial knowledge that tutors
   bulldoze past.
2. **The Five-Step Method** (CRLA-derived): (1) student explains their procedure → (2)
   reinforce what's *right* → (3) ask guiding questions **before** any direct explanation →
   (4) check by having them **re-explain** → (5) never work the problem for them.
3. **Check understanding with production, not recognition.** Never accept a nod.
4. **Build the relationship first** so the student is willing to expose confusion. The
   "I don't know" freeze is a safety response.
5. **Close with a summary said by the student**, not the tutor.
6. **Treat wrong answers as coherent rules, not noise.** ← the big one, see below.

## (b) Anti-patterns → this is our negative prompt

Every one of these is a **default LLM behavior**. This list is the system prompt.

- ❌ **Talking too much.** Lecturing kills active processing.
- ❌ **Doing the work for them.** The tutor is not "the expert re-teaching the lecture."
- ❌ **Rescuing too early** — jumping in at the first sign of struggle. (Kills productive failure.)
- ❌ **"Does that make sense?"** — a yes/no question that lets a student nod through total
  confusion. Replace with **"Why did we just do that?"**
- ❌ **"This is easy."** Intimidates. Use *"I know you can learn this, it just takes practice."*
- ❌ **Accepting "I don't have any idea."** Push for partial knowledge.
- ❌ **Erasing mistakes.** Destroys the diagnostic evidence of how they were thinking. Some
  tutors deliberately use **pen over pencil** for exactly this reason.
- ❌ **Over-explaining every question**, burning time that belongs to the student's practice.

## (c) Scripts worth stealing verbatim

**Opening**
- *"What are you working on today?"*
- *"What have you tried so far?"*
- *"Where exactly does it stop making sense?"*

**Diagnosing**
- *"Walk me through what you did here."*
- *"Why did you do that step?"*

**Guiding instead of telling**
- *"What do you notice?"*
- *"What comes next?"*
- *"When you evaluate this, what do you do first?"*

**Checking understanding**
- *"Why did we just do that?"* — never *"does that make sense?"*

**Responding to "I don't get it"** — ask for specificity (*"What's the first thing you're
stuck on?"*), break it smaller, and offer a **new** example rather than repeating the same one.

**Encouraging**
- *"I know you can learn this, it's just going to take some practice."*

**Closing**
- *"Can you sum up for me what we figured out today?"*

## (d) Page tradecraft → this is the spec for our draw tools

- **The pencil stays with the student.**
- **Do not erase a mistake.** Leave it. **Circle it and write the fix *beside* it, not over
  it** — so the student can see the two side by side and discuss the difference.
- Errors are **data**. Erasing them deletes the lesson.

**This maps directly onto the AI's tool surface. The AI gets exactly these tools:**

| Tool | Allowed on |
|---|---|
| `circle(bbox)` / `underline(bbox)` / `arrow(from, to)` / `question_mark(bbox)` | ✅ the student's page |
| `write(latex, anchor)` / `draw(diagram)` / `new_page()` | ✅ **the AI's own page only** |
| `erase(...)` | ❌ **does not exist.** Deliberately. |

---

## Diagnosing the gap: student errors are *rule-governed*

> **Brown & Burton (1978), "buggy algorithms."** Most student math errors are not random —
> they are the **systematic misapplication of a coherent (wrong) rule.** Diagnose the *rule*,
> not the wrong digit.

This is the difference between a calculator and a tutor. *"You wrote 11x"* is a correction.
*"You added 6x and 5 because you think every expression has to collapse to one term"* is a
diagnosis — and it fixes the next twenty problems, not this one.

**Misconception catalogs we can load into the AI (real, and mostly free):**
- **MalruleLib** — a modern, *executable* library of math "misrules" for step-level error diagnosis. Directly usable as a lookup table. ([arXiv 2601.03217](https://arxiv.org/pdf/2601.03217))
- **27 cataloged middle-school algebra misconceptions**, aligned to Common Core/NAEP. (e.g. simplifying `6x + 5` → `11x`, from over-applying arithmetic's one-answer rule.) ([ERIC EJ1264037](https://files.eric.ed.gov/fulltext/EJ1264037.pdf))
- **Lamar University's Common Math Errors** — a plain-language negative-example bank. ([link](https://tutorial.math.lamar.edu/extras/commonerrors/algebraerrors.aspx))
- Brown & Burton's Repair Theory, for the underlying framework.

**This is cheap and nobody does it.** Loading a misconception catalog into the tutor's
context is maybe an hour of work and it's the difference between "that's wrong" and a real
diagnosis. It also feeds the memory graph directly: *don't store "got Q3 wrong," store
"applies the distribute-everything misrule."*
