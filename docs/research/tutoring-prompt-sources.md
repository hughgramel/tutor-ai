# Sources behind `worker/src/instructions.ts`

The bulk of the literature review already lives in `00-SUMMARY.md` /
`01-learning-science.md` / `02-tutor-craft.md` / `03-ai-tutors-prior-art.md`
(Bastani et al. 2025 crutch effect, Kestin et al. 2025 one-step scaffolds,
Rowe wait-time, Kapur productive failure, Sweller & Cooper / Renkl / Kalyuga
worked-examples + fading, Mayer / Chandler & Sweller modality-split
attention-redundancy, Hattie & Timperley / Kluger & DeNisi feedback, Brown &
Burton buggy algorithms, Khan Academy's own retrospective). Those are the
backbone of the tutoring loop and the "no praise / no answer / own page"
rules — see that folder for full citations.

This file is the targeted follow-up research done specifically to write the
prompt: filling gaps the summary didn't cover (the hint ladder mechanics,
and algebra-specific misconceptions for the three demo problems in
`ios/InkTutor/Problems.swift`).

- **Lepper & Woolverton, INSPIRE model** ([UBC CWSEI PDF](https://www.eoas.ubc.ca/research/cwsei/resources/INSPIRE-Guidelines.pdf), [Semantic Scholar](https://www.semanticscholar.org/paper/Motivational-techniques-of-expert-human-tutors%3A-for-Lepper-Woolverton/f7741af65bad659574280a61e540c4d19093b445)) — expert tutors give feedback *indirectly regardless of valence*: probing questions of increasing directness instead of a flat "right/wrong," so students reveal their own error rather than being told it. → shaped the hint-ladder line in LET THEM STRUGGLE and the "never confirm/deny, ask them to walk through it" framing.
- **Chi et al. 1994 / Chi (tutoring dialogue moves)** ([ResearchGate](https://www.researchgate.net/publication/225474550_Tutor_learning_The_role_of_explaining_and_responding_to_questions)) — tutors *suppressed* from explaining and limited to prompts produced equal learning to tutors who explained freely; scaffolding prompts outperformed direct explanation as a tutor move. → confirms ELICIT ("why did that work") should be a prompt, not a lecture, even when the tutor could just explain faster.
- **Socratic hint ladders in ITS** ([arXiv 2508.06583, "Discerning minds or generic tutors?"](https://arxiv.org/pdf/2508.06583)) — naive "be Socratic" prompting produces infinite-regress questioning with no termination; real Socratic tutoring needs phase-locked structure (diagnose → target the specific error → scaffold → check → close) and an escalating hint sequence, not open-ended questions forever. → this is why the loop is numbered and ordered, not "ask questions until they get it," and why the ladder is capped (question → small hint → stronger hint → worked example, never skipped).
- **Factoring-quadratics error literature** ([students' common errors in quadratic equations, e-journal.stkipsiliwangi.ac.id](https://www.e-journal.stkipsiliwangi.ac.id/index.php/infinity/article/download/3843/1909); [Purplemath, factoring ax²+bx+c](https://www.purplemath.com/modules/factquad3.htm)) — the dominant errors are sign-handling (right factor magnitudes, wrong sign assignment) and choosing factor pairs that satisfy the product but not the sum. → matches the traps already hand-annotated in `Problems.swift` (quad-1: reaching for a negative constant when both terms are positive; quad-2: right magnitudes, sign on the wrong factor; quad-3: sign flip when splitting the middle term for grouping) — folded into the prompt as a short named-misrule paragraph instead of a generic "check your work."
- **Algebra sign-error misconceptions** (search summary across [LibreTexts 4.8](https://math.libretexts.org/Courses/Northern_Illinois_University/Conceptual_Mathematics_in_Society/04:_Algebra/4.08:_Common_Mistakes_in_Algebra), [MalruleLib arXiv 2601.03217](https://arxiv.org/pdf/2601.03217)) — dropping the sign when distributing a negative, and dividing only one term instead of the whole side, are *rule-governed* not careless. → reinforces "name the specific misrule you see" over "that's wrong," already the house style from `02-tutor-craft.md`.

Net effect on `instructions.ts`: the loop structure and absolute rules came
from the existing summary; this pass added the hint-ladder mechanic inside
step 2, sharpened ELICIT to explicitly ask for prompts over explanation, and
added a short factoring-specific misconception paragraph naming the three
demo problems' actual traps instead of a generic "check the signs."
