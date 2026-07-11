# Competitive landscape

## First: HeyClicky is not what we thought

Your p4 thesis was *"HeyClicky is viral right now, but it's a poor use for the computer."*
That's right, but the reason is bigger than you wrote:

**HeyClicky has nothing to do with math, tutoring, or ink.** It's a Mac-native AI
companion by **Farza Majeed** (YC S26), built in 8 weeks, viral off a 104-second demo
(~3M views, May 2026). It lives next to your cursor, listens continuously, watches your
screen, answers out loud, and **points at UI elements** in Figma / DaVinci / After
Effects. Say "heyclicky agent" and it spawns a background agent to click through tasks.
Native Swift, open-sourced, free + $20/mo.

**Its architecture — the part actually worth stealing:** a **multi-model router**.

| Layer | HeyClicky's choice | Why |
|---|---|---|
| Realtime turn-taking + routing | GPT-Realtime 2.0 (speech-to-speech) | Cheap, fast, no STT hop |
| Heavy visual understanding | Claude 4 (screenshots) | Best at pixels |
| Agentic execution | GPT-4.5 + Codex as a Rust subprocess | Separate, slower, tool-heavy |
| Always-on listening | Local VAD | Free, no cloud cost |
| Cost control | Screenshots only on button-press, 150 agent actions/mo cap | Vision is what costs money |

**The lesson:** don't use one model for everything. A fast cheap model owns the
conversation; a strong vision model owns understanding the page; a separate call owns
the drawing. That is directly transferable to us.

**The lesson it can't teach us:** HeyClicky *points at* existing content. It never
*creates* content on a canvas. Our hard problem — AI writes new ink in the right place —
has no precedent there.

> The team may also have been half-thinking of **Canvas Math**, which is the real
> closest analog. See below.

---

## Direct competitors

Sorted by how close they get to us. **The column that matters is "AI writes ink."**

| Product | Platform | What it does | AI writes ink? | Voice? | Socratic? | Price |
|---|---|---|---|---|---|---|
| **Canvas Math** | iPad/Android/Win tablet + web | AI-native math canvas. Reads your handwriting on pause, **writes answers back in your own ink style**. Symbolic engine (not LLM-guessed arithmetic). "Learn Mode" narrates while working problems by hand. | ✅ **yes** | ❌ | partial | $14 / $32 / $62 mo |
| **Apple Math Notes / Freeform** | iPadOS (free, in OS) | Write an equation in Pencil → solved & graphed inline, in matching ink. On-device. | ✅ yes | ❌ | ❌ | **free** |
| **Goodnotes AI Math Assist** | iPad/Mac/Web | Reads handwritten equations inline, flags wrong steps like a spellchecker. "Teach Me" mode via Wolfram\|Alpha. | ~ annotates | ❌ | partial | subscription add-on |
| **Khanmigo** | Web / LMS | Best-in-class Socratic chat tutor. Voice STT/TTS. Generates visual breakdowns. Refuses to give answers. | ❌ chat only | ✅ | ✅ **best** | ~$4–9/mo, free via districts |
| **Photomath** | iOS/Android | Camera OCR (handwriting incl.) → step-by-step solve. 100k+ handwriting samples trained. | ❌ reads only | ❌ | ❌ | freemium |
| **Gauth (Gauthmath)** | iOS/Android | Camera solver + live **human** tutor fallback | ❌ | ❌ | ❌ | freemium |
| **Mathos / MathGPT Pro** | Web/mobile | Photo/voice/draw input → step solutions | ❌ | input only | ❌ | freemium |
| **Symbolab / Julius / Socratic** | Web/mobile | Solvers & explainers | ❌ | ❌ | ❌ | freemium |
| **Mathpix** | API/desktop | Handwriting → LaTeX OCR. **Infrastructure, not a competitor** — we may buy from them. | n/a | n/a | n/a | ~$0.002/img |
| **StudyFetch, Synthesis, Nerdy, Amira** | Web | Voice/chat tutors, no ink canvas. (Amira is voice reading-tutor — good architecture analog for real-time speech tutoring.) | ❌ | ✅ | varies | subscription |

### Read the table

- **Canvas Math has the ink. It has no voice.**
- **Khanmigo has the voice and the pedagogy. It has no ink.**
- **Apple has the ink, for free, in the OS. It has no teaching.**
- **Nobody has all three.** That's the hole we're going through.

### The two competitors that should scare us

1. **Canvas Math** — already shipping AI-writes-in-your-ink at $14/mo. If they add a voice
   layer, they are us. *Why haven't they won yet?* → open question.
2. **Apple** — Math Notes is free, on-device, and in the OS. Every iPad already has it. If
   Apple bolts a tutor voice onto it at a WWDC, we're vapor. Our defense is that Apple
   won't do pedagogy, memory, or assignments — they do features, not teaching. Thin defense.

---

## Adjacent architectures worth copying

How other products let an AI manipulate a canvas:

| Product | How the AI reads/writes the canvas |
|---|---|
| **tldraw "Make Real" / tldraw AI** | Canvas is a store of **JSON shape records**. AI gets **both** a screenshot (for spatial context) **and** the structured shape data. Hybrid. This is the pattern. |
| **Excalidraw + MCP** | Same editable shape-JSON model. Agents mutate diagrams, git-diffable. |
| **ChatGPT Canvas** | AI edits a document model with **targeted diffs** — rewrites only the selected span, not the whole doc. The most transferable idea: *edit specific strokes/regions, don't regenerate the page.* |
| **Figma AI** | Assembles from a **structured component library**, not raw pixels — so output stays editable and on-system. |
| **Fermat.ws** | Spatial canvas, AI outputs as nodes, realtime collab via CRDT. |

**The pattern across all of them:** *structured object model + a vision pass for context.*
Screenshot-only vision is fine for **reading** a page. It is far too lossy for **writing**
precise new ink positioned relative to existing work. We need both: vision to understand,
stroke bounding boxes to place.

---

## The white space (what nobody is doing)

1. **Bidirectional live ink** — AI reads your evolving handwriting *and* writes its own
   worked steps back, in position, while talking. Canvas Math has half. Khanmigo has the
   other half. Nobody has both.
2. **The canvas as a structured math-object graph** — so the AI can say "your step 3" and
   *circle it precisely*, not OCR-and-forget.
3. **PDF homework → live co-working canvas** — competitors either solve a static photo or
   start from a blank page. Nobody turns your actual worksheet into a surface the AI works
   on with you.
4. **Multi-model split for tutoring** — cheap realtime voice for turn-taking, strong vision
   for the ink, separate call for the drawing. (HeyClicky's pattern; no edtech does this.)
5. **Silence-aware pacing** — knowing when to *shut up and let the student write*. Reading
   the pause in the strokes. Genuinely unsolved anywhere in this sample, and it's the thing
   that separates a good tutor from an annoying one.
