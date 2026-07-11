# Learning science: what makes tutoring work

Source: research agent, July 2026. Named effects, real citations, and what each one means
for **our** design. Honest about where the evidence is weak.

---

## The headline: cognitive load theory says our product shape is correct

This is the most important section. Three effects, and together they are a scientific
argument for **voice + ink on the page** over **a chat sidebar** — and against the obvious
naive implementation.

### 1. The modality effect → **use voice, not on-screen text**
> Mayer & Moreno. Spoken narration + a visual beats on-screen text + the same visual.
> **17 out of 17 tests favored narration** on transfer tests.

**Why:** on-screen text competes with the diagram for the *visual* channel and overloads it.
Speech offloads the words to the *auditory* channel, freeing visual capacity for the math.

**For us:** the voice isn't a gimmick or an accessibility feature. **It's the mechanism.**
The AI should *speak* the explanation while the ink carries *only* the math.

### 2. The split-attention effect → **a chat sidebar is actively harmful**
> Chandler & Sweller, 1991. When explanatory text sits apart from the diagram it refers to,
> the learner must bridge the gap in working memory. This measurably hurts learning.

**For us:** every competitor puts the explanation in a **side panel** and the math on the
canvas. **That is textbook split-attention.** Writing directly on the page, next to the mark
being discussed, isn't UX polish — it's the thing that makes it work. *This is our thesis,
and it has a citation.*

### 3. The redundancy effect → **the AI must not narrate what it writes**
> Mayer. Speaking the same words you display simultaneously *hurts* — the brain burns working
> memory reconciling two identical streams.

**For us — this is a real design constraint and it's easy to get wrong:**
- ❌ AI writes "divide both sides by 2" **and** says "divide both sides by 2." Redundant. Worse than either alone.
- ✅ AI **writes** `2x = 10` → `x = 5` (the math) and **says** *"so we divide both sides by 2 — we're trying to get x alone"* (the reasoning).

**Ink carries the math. Voice carries the why. Never the same content twice.**

### Mayer's other principles, applied
- **Temporal contiguity** — speak about a step *while* writing it. Narrate-then-draw (or draw-then-narrate) is measurably worse than simultaneous. **The sync is the product.**
- **Signaling** — circle/underline the term as you say it. Attention cueing boosts learning.
- **Segmenting** — break the derivation into learner-paced chunks with pauses at step boundaries. Not one continuous monologue.
- **Pre-training** — name a new symbol ("the discriminant") *before* using it fluently.

---

## Wait time — when the AI must shut up

> Rowe, 1972/1986. Typical teachers wait **under 1 second** after asking a question. Coached
> to **3–5 seconds** (threshold effect around **2.7s**), student responses get **300–700%
> longer**, contain more reasoning, and "slower" students improve most.
> Rowe also found **immediate praise or correction *suppresses* response quality.**

**For us — this is the single most actionable finding, and it's the thing a voice AI will
get wrong by default:**
- After asking a question, **hold silence ≥ 3–5 seconds.** Longer if the pencil is moving.
- **Pencil-down + a pause means "thinking," not "done."** Do not fill the silence.
- Do **not** jump in the instant ink appears. The default LLM behavior — responding
  immediately, enthusiastically — is *pedagogically destructive*.

This is also the "silence-aware pacing" white space we found in the competitor research
(`02-competitors.md`). Nobody has solved it. It has a 50-year-old literature.

---

## Worked examples and fading — the "now you try one" beat, formalized

- **Worked-example effect** (Sweller & Cooper, 1985): for *novices*, studying a worked
  example beats unguided problem-solving.
- **Backward fading** (Renkl, Atkinson et al., 2003): full example → example missing the last
  step → missing the last two → full problem. Beats an abrupt handoff.
  **Adaptive fading (paced to the individual) beats fixed fading.**
- **Expertise reversal** (Kalyuga et al., 2003): as the student improves, worked examples
  become **redundant and then harmful.** The same support that helps a novice slows down
  someone who already has the schema.

**For us:** the tutor must track per-skill mastery and pick a fade level. Full example on a
new topic; skip straight to "you try" once the student shows 2–3 correct independent steps.
**Never lead with a full worked example on something they've already got.**

> This is exactly Ali's idea (p4) — *save what they got wrong, quiz them later* — and it's
> the "memory graph" (p11). It has a name and 20 years of evidence.

---

## Productive failure — let them fail *first*

> Kapur; Sinha & Kapur 2021 meta-analysis (53 studies). Problem-solving **before**
> instruction reliably beats instruction-then-practice.

The mechanism: a failed attempt **surfaces the gap** that the explanation then fills. It
only works if consolidation *follows* the struggle — struggle alone does nothing.

**For us:** on a new problem type, let them attempt it first — light Socratic prompts, no
answers — for a bounded window (~2–4 min, or 2 failed attempts). **Then** deliver the worked
example, aimed at the specific wrong turn they just made.

**This directly contradicts the demo instinct.** The instinct is "student asks → AI
immediately writes a beautiful solution." The evidence says that's the *worst* ordering.

---

## Self-explanation — make them say why

> Chi et al., 1994. Students prompted to explain *to themselves* while studying vastly
> outperform re-readers on recall and transfer.

**For us:** after each step — the AI's or the student's — ask a targeted *"why did that
work?"* or *"what if the sign were negative?"* **before** moving on. Don't volunteer the
rationale you could extract from them.

---

## Feedback — a third of it makes things *worse*

> Hattie & Timperley (2007): good feedback answers **feed up** (where am I going), **feed
> back** (how am I doing), **feed forward** (what next) — aimed at the *task*, not the *self*.
> Kluger & DeNisi (1996), 131 studies: average d=0.38, but **~1/3 of feedback interventions
> REDUCED performance** — especially praise and ego-focused feedback.

**For us — the anti-pattern is the LLM default personality:**
- ❌ *"Great job! You're doing amazing!"* → ego-focused, evidence says it can hurt.
- ✅ *"That step works because you kept the equation balanced. Now check the sign on the second term."* → task/process-focused.

**Ban generic praise in the system prompt.** It's not just annoying; it measurably harms.

---

## Retrieval, spacing, interleaving

- Retrieval beats re-study. The "now you try one" beat is the *learning*, not the *check*.
- **Interleaving** mixed problem types beats blocked drilling by roughly **30%**.
- Bring a past mistake back **after intervening material**, not immediately — expanding intervals.

---

## Honest note on Bloom's 2 sigma

Bloom (1984) claimed 1:1 tutoring beats classroom instruction by **2 standard deviations.**
**This does not hold up.** VanLehn's 2011 meta-analysis showed the original comparison
confounded mastery threshold (90% tutoring vs. 80% classroom) with delivery mode. Real
numbers:

- Human tutors ≈ **0.79σ**
- Step-based intelligent tutoring systems ≈ **0.75σ** ← *note how close this is*
- Answer-based systems: lower

**Two things follow.** First: **don't pitch 2 sigma.** It's the edtech equivalent of a
hockey-stick chart and anyone informed will call it. Pitch *"consistently good tutoring,
available at 11pm, for the price of a sandwich."*

Second, and more interesting: **step-based ITS nearly matches human tutors.** The gains come
from working *at the step level* — diagnosing the specific move the student got wrong —
not from being human. That is precisely what watching someone work by hand gives us.

---

## What expert tutors actually do (the loop to encode)

> Lepper & Woolverton; VanLehn; Chi.

**diagnose → scaffold at the edge of ability → elicit → confirm.**

Not "explain well." Explaining well is what a textbook does.
