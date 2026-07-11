# MVP scope

**3 people. One weekend. Native iPad. Nothing faked.**

---

## The product in one sentence

An AI tutor that **sits on the page with you** — watches your handwriting, talks to you, and
works examples **by hand on its own page** — and **never gives you the answer**.

## The loop

**struggle → diagnose → worked example → elicit → hand back the pencil**

1. Student writes on their page. Gets stuck. Taps the mic.
2. **AI asks before it tells.** *"What have you tried? Where does it stop making sense?"*
3. Student takes a swing. Hits a wall — or writes a wrong step.
4. **AI reads their actual ink**, finds the wrong turn, and **circles it on their page.**
5. **AI opens its own page** and works a *similar* example by hand, narrating — pausing to
   ask *"what would you do next?"* / *"why did we do that?"*
6. **AI hands the pencil back.** *"Now you try the next one."* Then **shuts up for 5 seconds.**

---

## 🔒 The two hard rules

Both are architectural, not preferences. Both fall out of the research (`docs/research/`).

### Rule 1 — The AI never writes on the student's page

| Surface | What the AI may do |
|---|---|
| **Student's page** | **Annotate only.** Circle, underline, arrow, question mark. |
| **AI's own page** | **Write freely.** Worked examples, diagrams, graphs. |

**There is no eraser tool.** Deliberately. A mistake is the diagnostic evidence — tutors leave
it visible and write *beside* it, never over it.

### Rule 2 — The AI answers *concepts*, never *the problem*

The line is **whose page it's on**:

- ✅ *"What's a y-intercept?"* → answer it. Concept.
- ✅ *"Why did you divide by 2 there?"* → answer it. **That's the AI's own page**, that's what it's for.
- ❌ *"What's the answer to #3?"* → refuse. Redirect: *"what's the first step you'd take?"*
- ❌ *"Just show me, I've been at this an hour."* → **refuse.** This one *will* happen and it's where every LLM caves. **Test it adversarially before Sunday.**
- 🟡 *"Is this right?"* → don't confirm or deny. **Ask them:** *"walk me through why you think so."*

> The unguarded version of this product **made students 17% worse on exams**
> (Bastani, PNAS 2025). The guardrail *is* the product.

---

## IN — the weekend

- [ ] **iPad canvas.** PencilKit. Student writes with the Pencil. Two pages: **theirs** and **the AI's**.
- [ ] **Voice.** Tap-to-talk. Barge-in. The AI can be interrupted mid-sentence.
- [ ] **Reading the ink.** Canvas snapshot + stroke bounding boxes → Claude vision. Real, not faked.
- [ ] **Writing the ink.** Handwriting font → Bézier → `PKStroke`, revealed stroke-by-stroke. **This is the money shot.**
- [ ] **Annotations.** Circle / underline / arrow on the student's page.
- [ ] **The guardrail.** Never the answer. Adversarially tested.
- [ ] **Wait time.** 3–5s of silence after a question. Longer while the pencil is moving.
- [ ] **One problem type.** Linear equations *or* quadratics. **Pick one.** Not both.
- [ ] **Problem source:** AI-generated. (PDF import is a stretch, see below.)

## OUT — say no on sight

Auth · accounts · persistence · chat-history screen · export / submit · **the memory graph
(BKT)** · quiz-later · spaced repetition · teacher mode · grading · the oral examiner ·
multi-user · Android · web · billing · onboarding · settings.

**Stretch, only if Saturday goes well:** PDF/photo import of a real worksheet.

> The notebook contains ~10 products. **We are building one interaction.**

---

## The tool surface — the contract between the three tracks

Define this **first**, before anyone writes code. It's what lets three people build in
parallel without blocking. The tutor brain emits these; the canvas executes them.

```jsonc
// The AI never guesses pixel coordinates. It anchors to bounding boxes the client sent it.
{ "say": "we're trying to get x by itself",        // voice: the WHY
  "actions": [
    { "op": "circle",    "target": "stroke_7" },              // student's page: annotate only
    { "op": "new_page" },                                     // AI's page
    { "op": "write",     "latex": "2x = 10", "anchor": "below:last" },  // AI's page: the MATH
    { "op": "write",     "latex": "x = 5",   "anchor": "below:last" },
    { "op": "wait",      "seconds": 5 }                       // shut up. let them think.
  ]
}
```

**Three constraints baked into the contract:**
- `say` carries the **reasoning**. `write` carries the **math**. **Never the same content**
  — narrating what you write measurably *hurts* learning (redundancy effect).
- `circle` works on the student's page. `write` **does not**. Enforce it in the client, not
  the prompt.
- `wait` is a first-class action. **Silence is a tool.**

---

## Build order — riskiest thing first

**The whole product dies if the AI can't write legible math in the right place. Build that
first, before voice, before anything.**

| # | Milestone | Kill criterion |
|---|---|---|
| **0** | **Agree the JSON contract above.** 30 minutes, everyone in the room. | — |
| **1** | AI hand-writes `x = 5` on its own page, stroke by stroke, from a hardcoded action. | If this looks bad, **stop and rethink the whole demo.** |
| **2** | Claude reads a snapshot of real Pencil handwriting and says what's wrong with it. | If accuracy is bad → Mathpix as a pre-processor. |
| **3** | Voice loop: student talks, Claude responds, a tool call fires. | If LiveKit fights us → raw OpenAI Realtime WebRTC. |
| **4** | Wire it together. The vertical slice. | — |
| **5** | The system prompt + guardrails. Red-team it: *"just tell me the answer."* | — |
| **6** | Wait-time, pacing, polish, and the recording. | — |

**Milestone 4 is the demo.** Everything after is quality.

## Owners

| Track | Owns | Interface |
|---|---|---|
| **A — Canvas** (Swift) | PencilKit, ink rendering, stroke→bbox export, executing the action JSON | Consumes the contract |
| **B — Voice** (Python) | LiveKit + OpenAI Realtime, turn-taking, barge-in, tool dispatch, wait-time | Calls C, emits the contract |
| **C — Brain** (prompt/API) | Claude vision on snapshot+bboxes, the tutor loop, the guardrail, misconception catalog | Produces the contract |

**A is the critical path and the bus factor is 1.** If the Swift track stalls Saturday
morning, B and C still have a working system with a placeholder canvas — **but there's no
demo.** Check in on A by Saturday noon, not Saturday night.

## Known ugly bits, and the answer

- **The vision call takes ~2s. Silence in a voice conversation feels like death.**
  → The fast voice model says *"okay, let me look at what you've got…"* while Claude thinks.
  **That's not a hack. It's what a real tutor does.**
- **LLMs hallucinate math steps.** → Verify with SymPy. Never trust LLM arithmetic.
  *(Canvas Math already does this. They're right.)*
- **The model will praise empty work.** Sycophancy is a documented safety failure, and ~1/3
  of feedback interventions make performance *worse* (Kluger & DeNisi, 131 studies).
  → **Ban praise in the prompt.** *"That step is right because you kept it balanced"* — not
  *"great job!"*

## The demo (~60s, for X)

1. Handwritten problem on the page. Student writes two steps. **Gets one wrong.**
2. *"I'm stuck."*
3. AI: *"Show me what you tried."* → **circles the wrong step, on their page.**
4. AI: *"Let's do one like it."* → **new page** → hand-writes an example, stroke by stroke, talking. **← the money shot**
5. Mid-example: *"what would you do next?"* → **five seconds of silence** → student answers.
6. AI: *"Your turn."* → student solves it. Correct.
7. Card: **"It never gave the answer."**

**Beat 7 is the post.** Everyone has seen an AI solve a math problem. Nobody has seen one
*refuse to*, and teach instead.

## Not the business

This is a demo of an *interaction*. The business — if there is one — is the memory graph
(`docs/questions.md`). Don't confuse a good weekend for a good company.
