# Open questions

Living doc. Nothing here is rhetorical — each one should get a real answer before
we commit to building past the hackathon.

---

## The four that decide whether this is a company

1. **Is it 10x better, or incrementally better?**
   Paper is free and works. Photomath is free and instant. What is the 10x?
   - Candidate answer: *it is the only thing that works with you on the page, by hand, out loud.* Is that 10x, or is that a nicer skin on a chatbot?
   - Philip's version of this question (p2): "alternative from paper to oral — **is it 10x better?**"
   - Falsifiable test: give a student the app and a student a chatbot. Does the app student learn measurably more?

2. **Can it actually be built?**
   Specifically the hard part: an AI that reads messy handwritten math in real time *and* writes legible, natural-looking math back in the right place on the page, fast enough that talking to it feels like talking to a person.
   - Which piece is most likely to be fake in the demo but impossible in production?
   - What's the accuracy floor for OCR on real student handwriting before the tutor starts confidently correcting things the student never wrote?

3. **Will users change behavior?**
   The student already has a phone, a pencil, and ChatGPT. We are asking them to buy/own an iPad, keep it open, and *talk out loud* while doing homework.
   - Do students actually talk out loud while studying? In a library? In a dorm? Is voice a feature or a tax?
   - Is the real user the student, the parent paying, or the teacher assigning?

4. **Is it worth the switch?**
   Switching cost is the tutor they already pay for, or the free chatbot they already use.
   - Against a **$60/hr human tutor**: we're cheaper, but are we good enough?
   - Against **free ChatGPT**: we're better on the page, but are we worth paying for?
   - What is the moment the student says "I'm not going back"?

## The two that decide whether it's a *good* company

5. **Does it scale efficiently? Do unit economics improve with growth?**
   Right now every minute of tutoring costs us real money — realtime voice is ~$0.04–0.10/min
   and every vision call on the canvas is a metered API hit. A human tutor's cost is linear
   in students; **so is ours.** That's the problem.
   - What gets *cheaper* per student as we grow? Anything? Or are we just reselling OpenAI
     with a margin?
   - Levers that actually exist: cheaper/smaller models over time, caching, snapshotting the
     canvas only on demand instead of on a loop, moving OCR on-device, a smaller model for
     turn-taking and an expensive one only when the student is actually stuck.
   - At $15/mo, how many hours of tutoring can a student use before we lose money on them?
     **Compute this before we price anything.** Heavy users are the ones who love it most —
     they're also the ones who bankrupt us.

6. **Is it defensible? Can competitors copy it? Does it create stickiness — do customers stay?**
   - **Copyable in a weekend:** the canvas, the voice, the ink rendering. All of it. A funded
     team could clone this demo in two weeks. Assume they will.
   - **Not copyable:** the record of how *this student* thinks — every step they've written,
     every mistake they've made, every concept they've had to relearn. That data only exists
     because we watched them work by hand. Nobody else sees the work, only the answer.
   - **Stickiness test:** what makes a student open it on day 30, not day 1? Right now,
     nothing. A tutor you have to re-explain yourself to every session is not a tutor.
     → *The memory graph (p11) is not a feature. It may be the entire moat.*
   - Do we get stickier as models get better, or does a better model erase our advantage?
     **Build the thing that gets stronger when GPT-6 ships, not the thing it replaces.**
     (Philip, p2: *"AI is growing, so the bar to catch you is growing."*)

## The one that decides whether anyone ever sees it

7. **Can we acquire customers profitably? Is the motion unique to our market? Can it scale without scaling costs?**

   **Profitably** — CAC vs. LTV, and be honest that our LTV is *thin*: a student pays maybe
   $15/mo and churns the week finals end. Consumer edtech has brutal seasonality and brutal
   churn. If CAC is $40 and a student stays 3 months at $15 with a 40% gross margin, we make
   $18 and paid $40. **Do this arithmetic before spending a dollar on ads.**

   **Unique to our market** — what channel exists for *us* that doesn't exist for a generic
   SaaS? Candidates, ranked by how much they're actually ours:
   - **The artifact is the ad.** A student's finished page — their messy work, the AI's
     handwriting next to it, the circled mistake — is a shareable object no competitor can
     produce. Photomath can't screenshot that. Khanmigo can't. *The product output is the
     marketing asset.* This is the only channel that is structurally ours.
   - **Teachers as the distribution wedge.** One teacher assigns it to 30 students. That is
     30 users for one conversation. Nobody in consumer edtech gets this for free — but it's
     a different product (assignments, rosters), which is why the notes' teacher/grading
     thread keeps resurfacing. It may not be a distraction. It may be the channel.
   - **The tutor as the seller, not the enemy.** p9 literally says: *"find a tutor and ask
     them if a prototype would help them."* A tutor who uses it with 20 students is a
     distributor. We assumed tutors are who we're replacing. What if they're who we sell to?
   - Everything else (TikTok, ads, SEO, "AI tutor" keywords) is a knife fight against
     funded incumbents. Not ours.

   **Scale without scaling costs** — does each new user make acquisition cheaper, or just add
   cost? Right now: **just adds cost.** There is no loop. Name the loop or admit there isn't one:
   - Does a student's shared page bring another student? (Maybe — if sharing is one tap.)
   - Does a teacher's class bring another teacher? (This is the real loop, if it exists.)
   - Does more usage make the tutor better for the *next* user, or only for that user?
     *(If the memory graph is per-student, it deepens retention but creates no acquisition
     loop. Those are different things and we keep conflating them.)*

   **The uncomfortable one:** the weekend plan is "post a stunning demo on X and maybe get
   customers." That is a **launch**, not a motion. It fires once, it reaches founders and AI
   people — *not John, not John's mom, not John's teacher* — and it is not repeatable. It's
   worth doing (it's how HeyClicky got its 3M views and a YC slot), but we should call it
   what it is: **a credibility spike, not a customer channel.** The real motion is still
   unnamed, and naming it is more valuable than the demo.

---

## AVOID — the ways this dies

Check these every time we add something. If the answer is "yes," stop.

- **Is this too complex?** We are three people with a weekend. Every extra subsystem is a
  thing that breaks live on stage. The notes already contain: a canvas, voice, handwriting
  OCR, AI ink rendering, PDF import, chat history, a memory graph, quiz generation, grading,
  and an oral examiner. **That's ten products.** Which one is the demo?
- **Is this a race to the bottom?** AI tutoring apps are commoditizing fast — every one of
  them wraps the same three APIs and undercuts on price. If our answer to a competitor is
  "we're $5 cheaper," we've already lost. What do we have that survives a price war?
- **Are we ignoring unit economics and saying "we'll figure it out later"?** Voice + vision
  is one of the *most* expensive per-user AI products you can build. This is not a
  figure-it-out-later business. If we can't name the path to a positive gross margin, we
  are building an expensive toy.
- **Are we building for the demo or for the student?** These diverge fast. The thing that
  looks best in a 60-second video (AI dramatically hand-writing a full solution) may be the
  *worst* pedagogy (student watches, learns nothing). **Know which one we're optimizing, and
  be honest about it in the X post.**
- **Are we solving our own problem instead of John's?** We think the canvas is cool. Does
  John? He might just want the answer at 11pm.
- **Are we spraying and praying on channels?** Trying TikTok *and* ads *and* SEO *and*
  Reddit *and* X is how a three-person team does five things badly and learns nothing from
  any of them. **Pick one channel, run it hard enough to get a real signal, kill it or
  double it.** Five half-run channels produce zero data.
- **Are we running a generic playbook?** "Launch on Product Hunt, post on X, do content
  marketing, buy some ads" is what every AI wrapper does — because it's what you do when you
  don't know your customer. If our GTM plan would work equally well for a CRM, it isn't a
  plan, it's a template.
- **Are we doing hope marketing?** *"We'll post the demo and see what happens"* is hope. A
  motion has a stated audience, a stated channel, a stated hypothesis, and a number that
  tells you if it worked. **"Get some customers" is not a number.** Before we post: who
  exactly do we want to reply, and how many of them, and what do we do when they do?

---

## Product

- Is the wedge **homework help** (student, reactive, "I'm stuck") or **practice** (student, proactive, "quiz me") or **assignment delivery** (teacher, B2B)?
- Ali's idea adds memory: *saves your mistakes, quizzes you later.* Is spaced-repetition-on-your-own-errors the actual product, and the canvas just the capture surface?
- What happens when the AI is **wrong** on a math step? A tutor that confidently teaches a wrong method is worse than no tutor. What's the guardrail?
- Socratic vs. just-tell-me: students under deadline want the answer. Does the Socratic mode survive contact with a student at 11pm the night before it's due?
- Do we hard-refuse to just give the answer? If yes, does that kill retention? (This is a real product decision, not a values one.)

## Market

- Notes list **two different companies** (see `01-problem.md`): the oral examiner (B2B, College Board) and the pencil tutor (B2C, John). Are we sure we're picking the tutor? What did the examiner idea have that the tutor doesn't? (Answer: a buyer with money.)
- **Canvas Math** (canvasmath.com) already does AI-writes-in-your-ink at $14–62/mo, no voice. Why haven't they won? Are they bad, or is the market small?
- Apple ships **Math Notes** for free in the OS. What stops Apple from adding a tutor voice to it next WWDC and vaporizing us?
- Who pays: student, parent, school, district? Each is a different company.

## Defensibility (Philip's last question, p2)

- "What is defensible in this business?" — right now, nothing. Model is rented, canvas is a library, voice is an API.
- Candidate moats, ranked by how much we believe them:
  1. **The error/memory graph** — a longitudinal record of *how this specific student thinks and where they break*. Gets better the longer they use it. Nobody else has it because nobody else sees the work, only the answer.
  2. Pedagogy quality / evals — a tutor that provably teaches. Slow to build, hard to copy, but not a moat, just a lead.
  3. Distribution into schools. Not a hackathon thing.
  4. Ink feel / craft. A lead, not a moat.
- Philip's warning: *"AI is growing, so [the bar] to catch you is growing."* Which of our moats is *strengthened* by better models, and which is *erased* by them? Build the one that's strengthened.

## Validation (what would make Philip believe us)

- What's our version of "correlate with the SAT"? What is the measurement that proves a student learned, not just finished?
- Cheapest real test this week: **find one real student, one real worksheet, watch them use it.** Not a survey. Watch.
- Pre/post test on one concept, n=5, us vs. ChatGPT. Crude, but it's evidence and nobody else in the room will have any.

## Scope / hackathon

- If exactly one thing has to work on stage, is it: (a) AI writes handwriting on the canvas, (b) AI understands what the student wrote, or (c) the voice feels like a person? Rank them — we will not get all three perfect.
- What are we willing to fake on Sunday, and are we honest about it in the X post?
